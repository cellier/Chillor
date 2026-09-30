"""Policy checks for the loopback proxy. Deterministic: no internet required.

The tunnel is exercised over local socket pairs rather than a real host, so the
accounting and budget logic is tested without depending on any network. End to
end (pip actually installing through it) is covered by the live evaluation.

Run: Resources/AgentPython/bin/python3 Tests/proxy_test.py
"""
import json, pathlib, socket, sys, tempfile, threading, time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent/'Resources/AgentTools'))
from proxy import Proxy, Budget

ok = fail = 0
def check(name, fn):
    global ok, fail
    try:
        fn(); print('ok   '+name); ok += 1
    except Exception as error:
        print('FAIL '+name+': '+repr(error)[:200]); fail += 1


PYPI = ['pypi.org', 'files.pythonhosted.org']

# ---- allowlist policy (pure) -------------------------------------------------
def exact_match_only():
    p = Proxy(PYPI)
    for host in ('evil-pypi.org', 'pypi.org.attacker.net', 'sub.pypi.org', 'PYPI.org.evil'):
        assert p.allowed(host, 443) is None, host
check('host matching is exact: no prefix, suffix or subdomain slips through', exact_match_only)

def case_insensitive_for_the_real_host():
    p = Proxy(['PyPI.org'])
    assert p.hosts == {'pypi.org'}
check('the allowlist is normalised to lower case', case_insensitive_for_the_real_host)

def only_443():
    p = Proxy(PYPI)
    for port in (80, 8080, 8443, 22, 0):
        assert p.allowed('pypi.org', port) is None, port
check('only port 443 is tunnelled', only_443)

def private_targets_refused():
    for host in ('localhost', 'metadata.google.internal', 'router.local'):
        assert Proxy([host]).allowed(host, 443) is None, host
check('an allowlisted name that resolves privately is still refused', private_targets_refused)

def empty_allowlist_allows_nothing():
    p = Proxy([])
    assert p.hosts == set() and p.allowed('pypi.org', 443) is None
check('an empty allowlist permits nothing', empty_allowlist_allows_nothing)

# ---- budget (pure) -----------------------------------------------------------
def budget_counts_and_trips():
    b = Budget(1000)
    assert b.spend(sent=600) is True and b.up == 600
    assert b.spend(sent=500) is False, 'crossing the limit must report failure'
    assert b.exceeded is True
    assert b.spend(sent=1) is False, 'once exceeded it stays exceeded'
check('the upload budget counts and trips exactly at the limit', budget_counts_and_trips)

def downloads_do_not_consume_the_budget():
    b = Budget(1000)
    b.spend(received=10_000_000)
    assert b.exceeded is False and b.down == 10_000_000
check('downloads are measured but do not spend the upload budget', downloads_do_not_consume_the_budget)

# ---- protocol over a real socket --------------------------------------------
def serve(proxy, request):
    port = proxy.start()
    try:
        s = socket.create_connection(('127.0.0.1', port), timeout=10)
        s.sendall(request)
        reply = s.recv(200)
        s.close()
        time.sleep(0.15)
        return reply
    finally:
        proxy.stop()

def non_connect_refused():
    reply = serve(Proxy(PYPI), b'GET http://pypi.org/ HTTP/1.1\r\nHost: pypi.org\r\n\r\n')
    assert b'405' in reply, reply
check('a plain proxied GET is refused; only CONNECT is served', non_connect_refused)

def blocked_host_refused():
    p = Proxy(PYPI)
    reply = serve(p, b'CONNECT example.com:443 HTTP/1.1\r\n\r\n')
    assert b'403' in reply, reply
    assert any('not on the allowlist' in r['outcome'] for r in p.records), p.records
check('CONNECT to a host outside the allowlist gets 403 and is logged', blocked_host_refused)

def spent_budget_refuses_new_tunnels():
    p = Proxy(PYPI, upload_limit=10)
    p.budget.spend(sent=999)
    reply = serve(p, b'CONNECT pypi.org:443 HTTP/1.1\r\n\r\n')
    assert b'507' in reply, reply
check('once the upload budget is spent, new tunnels are refused', spent_budget_refuses_new_tunnels)

def malformed_is_recorded():
    p = Proxy(PYPI)
    port = p.start()
    try:
        s = socket.create_connection(('127.0.0.1', port), timeout=10); s.close()
        time.sleep(0.2)
    finally:
        p.stop()
    assert any('malformed' in r['outcome'] for r in p.records), p.records
check('a client that connects and vanishes still leaves a record', malformed_is_recorded)

# ---- tunnel accounting over local socket pairs ------------------------------
def tunnel_accounts_both_directions():
    p = Proxy(PYPI, upload_limit=1_000_000)
    client, inner = socket.socketpair()
    upstream, peer = socket.socketpair()

    def peer_side():
        data = peer.recv(65536)
        peer.sendall(b'Y'*5000)
        time.sleep(0.1)
        peer.close()
    threading.Thread(target=peer_side, daemon=True).start()
    client.sendall(b'X'*3000)
    up, down = p._tunnel(inner, upstream)
    assert up == 3000, up
    assert down == 5000, down
    assert p.budget.up == 3000 and p.budget.down == 5000
    for s in (client, inner, upstream): s.close()
check('the tunnel counts bytes in both directions', tunnel_accounts_both_directions)

def tunnel_drops_when_budget_exhausted():
    p = Proxy(PYPI, upload_limit=2000)
    client, inner = socket.socketpair()
    upstream, peer = socket.socketpair()
    threading.Thread(target=lambda: peer.recv(65536), daemon=True).start()
    client.sendall(b'X'*5000)
    up, down = p._tunnel(inner, upstream)
    assert p.budget.exceeded is True, p.budget.up
    assert up <= 5000 and up > 0
    for s in (client, inner, upstream): s.close()
check('the tunnel is dropped as soon as the upload budget is exceeded', tunnel_drops_when_budget_exhausted)

# ---- logging -----------------------------------------------------------------
def everything_is_logged():
    path = pathlib.Path(tempfile.mkdtemp())/'net.jsonl'
    p = Proxy(PYPI, log_path=str(path))
    serve(p, b'CONNECT example.com:443 HTTP/1.1\r\n\r\n')
    lines = [json.loads(l) for l in path.read_text().splitlines()]
    assert lines and lines[0]['host'] == 'example.com'
    for key in ('bytes_up', 'bytes_down', 'seconds', 'outcome', 'at'):
        assert key in lines[0], key
check('refusals are written to the log with byte counts', everything_is_logged)

def summary_reports_the_policy():
    p = Proxy(PYPI, upload_limit=1_000_000)
    s = p.summary()
    assert s['hosts_allowed'] == sorted(PYPI)
    assert s['upload_limit'] == 1_000_000 and s['upload_budget_exceeded'] is False
check('the summary states the policy that was in force', summary_reports_the_policy)

print('\n%d/%d proxy checks passed' % (ok, ok+fail))
sys.exit(1 if fail else 0)
