"""Loopback CONNECT proxy: the only way anything inside the sandbox reaches the network.

The sandbox itself keeps (deny network*) except for one loopback port, and DNS
stays denied in there, so sandboxed code cannot resolve a name or open a socket
to anything but this proxy. Every rule below is therefore enforced outside the
sandbox, where the code under execution cannot reach it:

  * host allowlist, exact match only - no wildcards, no suffix matching
  * resolved addresses must be public - an allowlisted name that resolves to a
    private or loopback address is refused, so DNS cannot be used to pivot inward
  * CONNECT to port 443 only
  * a byte budget for data sent OUT, shared across the whole run
  * every connection recorded: host, bytes each way, duration
"""
import ipaddress
import json
import select
import socket
import threading
import time


class Budget:
    """Shared upload allowance for one run. Exceeding it closes the tunnel."""

    def __init__(self, limit):
        self.limit = limit
        self.up = 0
        self.down = 0
        self.exceeded = False
        self._lock = threading.Lock()

    def spend(self, sent=0, received=0):
        with self._lock:
            self.up += sent
            self.down += received
            if self.up > self.limit:
                self.exceeded = True
            return not self.exceeded


class Proxy:
    def __init__(self, hosts, upload_limit=1_000_000, log_path=None):
        self.hosts = {h.strip().lower() for h in hosts if h.strip()}
        self.budget = Budget(upload_limit)
        self.log_path = log_path
        self.records = []
        self._server = None
        self._thread = None
        self._stop = threading.Event()
        self.port = None

    # -- policy ---------------------------------------------------------------
    def allowed(self, host, port):
        if port != 443 or host.lower() not in self.hosts:
            return None
        try:
            infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
        except socket.gaierror:
            return None
        addresses = [i[4][0] for i in infos]
        if not addresses or any(not ipaddress.ip_address(a).is_global for a in addresses):
            return None                      # allowlisted name pointing somewhere private
        return addresses[0]

    def record(self, host, up, down, seconds, outcome):
        entry = {'host': host, 'bytes_up': up, 'bytes_down': down,
                 'seconds': round(seconds, 2), 'outcome': outcome, 'at': time.time()}
        self.records.append(entry)
        if self.log_path:
            try:
                with open(self.log_path, 'a', encoding='utf-8') as log:
                    log.write(json.dumps(entry, ensure_ascii=False)+'\n')
            except OSError:
                pass

    # -- plumbing -------------------------------------------------------------
    def start(self):
        self._server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server.bind(('127.0.0.1', 0))
        self._server.listen(16)
        self.port = self._server.getsockname()[1]
        self._thread = threading.Thread(target=self._accept, daemon=True)
        self._thread.start()
        return self.port

    def stop(self):
        self._stop.set()
        try:
            self._server.close()
        except (OSError, AttributeError):
            pass

    def _accept(self):
        while not self._stop.is_set():
            try:
                client, _ = self._server.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(client,), daemon=True).start()

    def _serve(self, client):
        started = time.monotonic()
        host = '?'
        upstream = None
        try:
            client.settimeout(20)
            head = b''
            while b'\r\n\r\n' not in head:
                chunk = client.recv(4096)
                if not chunk or len(head) > 8192:
                    self.record('?', 0, 0, time.monotonic()-started, 'refused: malformed request')
                    return
                head += chunk
            request = head.split(b'\r\n', 1)[0].decode('latin-1')
            parts = request.split()
            if len(parts) < 2 or parts[0].upper() != 'CONNECT':
                client.sendall(b'HTTP/1.1 405 Method Not Allowed\r\n\r\n')
                self.record(request[:80], 0, 0, time.monotonic()-started, 'refused: only CONNECT')
                return
            target, _, raw_port = parts[1].rpartition(':')
            host = target or parts[1]
            try:
                port = int(raw_port)
            except ValueError:
                port = 0
            address = self.allowed(host, port)
            if address is None:
                client.sendall(b'HTTP/1.1 403 Forbidden\r\n\r\n')
                self.record(host, 0, 0, time.monotonic()-started, 'refused: not on the allowlist')
                return
            if self.budget.exceeded:
                client.sendall(b'HTTP/1.1 507 Insufficient Storage\r\n\r\n')
                self.record(host, 0, 0, time.monotonic()-started, 'refused: upload budget spent')
                return
            upstream = socket.create_connection((address, port), timeout=20)
            client.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
            # Anything the client pipelined after the header belongs to the tunnel.
            leftover = head.split(b'\r\n\r\n', 1)[1]
            if leftover:
                if not self.budget.spend(sent=len(leftover)):
                    self.record(host, len(leftover), 0, time.monotonic()-started,
                                'refused: upload budget spent')
                    return
                upstream.sendall(leftover)
            # Record the connection as it opens, so a long-lived tunnel is visible
            # before it closes rather than only in hindsight.
            self.record(host, len(leftover), 0, time.monotonic()-started, 'open')
            up, down = self._tunnel(client, upstream)
            self.record(host, up+len(leftover), down, time.monotonic()-started,
                        'upload budget exceeded' if self.budget.exceeded else 'closed')
        except Exception as error:
            self.record(host, 0, 0, time.monotonic()-started, 'error: '+type(error).__name__)
        finally:
            for sock in (client, upstream):
                try:
                    sock.close()
                except (OSError, AttributeError):
                    pass

    def _tunnel(self, client, upstream):
        up = down = 0
        client.settimeout(None)
        upstream.settimeout(None)
        while not self._stop.is_set():
            ready, _, _ = select.select([client, upstream], [], [], 30)
            if not ready:
                break
            for sock in ready:
                other = upstream if sock is client else client
                try:
                    data = sock.recv(65536)
                except OSError:
                    return up, down
                if not data:
                    return up, down
                if sock is client:
                    up += len(data)
                    if not self.budget.spend(sent=len(data)):
                        return up, down     # budget spent: drop the tunnel
                else:
                    down += len(data)
                    self.budget.spend(received=len(data))
                try:
                    other.sendall(data)
                except OSError:
                    return up, down
        return up, down

    def summary(self):
        return {'requests': len(self.records), 'bytes_up': self.budget.up,
                'bytes_down': self.budget.down, 'upload_limit': self.budget.limit,
                'upload_budget_exceeded': self.budget.exceeded,
                'hosts_allowed': sorted(self.hosts), 'connections': self.records[-20:]}
