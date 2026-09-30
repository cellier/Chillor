"""Local session reconciliation and context policy around SDK SQLiteSession.

Codex-inspired invariants: retain real user intent, compact only complete exchanges,
keep raw evidence retrievable, and never present summaries as new user instructions.
"""
import hashlib
import json
import re
import sqlite3
from pathlib import Path


def dumps(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def fingerprint(value):
    return hashlib.sha256(dumps(value).encode()).hexdigest()


def tokens(value):
    # Conservative estimate, not the Qwen tokenizer. Reserve another 1024 tokens below.
    if isinstance(value, dict):
        if value.get('type') == 'input_image':
            return 2048
        return sum(tokens(v) for v in value.values())+12
    if isinstance(value, list):
        return sum(tokens(v) for v in value)+12
    text = value if isinstance(value, str) else dumps(value)
    return int(sum(1.5 if ord(c) > 127 else 0.4 for c in text)) + 12


def sdk_message(message):
    content = message.get('content', '')
    if message.get('images'):
        content = [{'type': 'input_text', 'text': content}] + [
            {'type': 'input_image', 'image_url': 'data:image/png;base64,'+image, 'detail': 'auto'}
            for image in message['images']]
    return {'role': message['role'], 'content': content}


class LocalState:
    def __init__(self, directory, emit):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db_path = self.directory/'session.sqlite'
        self.db = sqlite3.connect(self.db_path)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript('''
          CREATE TABLE IF NOT EXISTS turns (id TEXT PRIMARY KEY, input_hash TEXT, output TEXT);
          CREATE TABLE IF NOT EXISTS summaries (id TEXT PRIMARY KEY, body TEXT);
          CREATE TABLE IF NOT EXISTS summary_prefixes (id TEXT PRIMARY KEY, item_count INTEGER);
          CREATE TABLE IF NOT EXISTS evidence (id TEXT PRIMARY KEY, body TEXT);
          CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, status TEXT, updated TEXT DEFAULT CURRENT_TIMESTAMP);
          CREATE TABLE IF NOT EXISTS actions (request_key TEXT, action_key TEXT, status TEXT, result TEXT, PRIMARY KEY(request_key,action_key));
        ''')
        self.emit = emit
        self.items = []
        self.summary = ''
        self.summary_prefix = []

    def begin_request(self, message):
        self.request_key = fingerprint([message.get('id', ''), sdk_message(message)])

    def begin_action(self, name, args):
        key = fingerprint([name, args])
        row = self.db.execute('SELECT status,result FROM actions WHERE request_key=? AND action_key=?',
                              (self.request_key, key)).fetchone()
        if row:
            if row[0] == 'completed':
                return key, json.loads(row[1])
            raise ValueError('A previous attempt of this exact action was interrupted or failed; its outcome may be unknown. Inspect the current file/app state before choosing a different action. Do not blindly repeat.')
        self.db.execute('INSERT INTO actions VALUES (?,?,?,?)', (self.request_key, key, 'started', None))
        self.db.commit()
        return key, None

    def finish_action(self, key, result):
        self.db.execute('UPDATE actions SET status=?,result=? WHERE request_key=? AND action_key=?',
                        ('completed', dumps(result), self.request_key, key))
        self.db.commit()

    def status(self, run_id, status):
        self.db.execute('INSERT OR REPLACE INTO runs(id,status) VALUES (?,?)', (run_id, status))
        self.db.commit()
        self.emit({'type': 'run_state', 'run_id': run_id, 'status': status})

    def seed(self, conversation):
        """UI-visible history is authoritative for delete/retry/continuation boundaries.

        Rehydrate a saved SDK turn only when its corresponding assistant reply remains
        visible. A stopped/deleted answer must not silently reappear from hidden memory.
        """
        items, users = [], {}
        for message in conversation:
            if message['role'] == 'system':
                continue
            if message['role'] == 'user':
                users[message.get('id', '')] = message
            parent = message.get('replyTo')
            original = users.get(parent)
            row = self.db.execute('SELECT input_hash,output FROM turns WHERE id=?', (parent or '',)).fetchone()
            if message['role'] == 'assistant' and original and row and row[0] == fingerprint(sdk_message(original)):
                items.extend(json.loads(row[1]))
            else:
                items.append(sdk_message(message))
        return items

    def save_turn(self, message, output):
        if message.get('id'):
            self.db.execute('INSERT OR REPLACE INTO turns VALUES (?,?,?)',
                            (message['id'], fingerprint(sdk_message(message)), dumps(output)))
            self.db.commit()

    def archive(self, value):
        key = fingerprint(value)[:24]
        self.db.execute('INSERT OR IGNORE INTO evidence VALUES (?,?)', (key, dumps(value)))
        self.db.commit()
        return key

    def recall(self, query='', evidence_id='', offset=0):
        if evidence_id:
            row = self.db.execute('SELECT body FROM evidence WHERE id=?', (evidence_id,)).fetchone()
            if not row:
                raise ValueError('Evidence ID not found in this task')
            text = row[0]
            if getattr(self, 'personal_memory', None):
                text = self.personal_memory.redact(text)
            return {'evidence_id': evidence_id, 'text': text[offset:offset+8000],
                    'next_offset': offset+8000 if len(text) > offset+8000 else None}
        # Search only the current authorized history, never deleted/unrelated task rows.
        terms = re.findall(r'[a-z0-9_./-]+|[\u4e00-\u9fff]', query.lower())
        scored = sorted(enumerate(self.items), key=lambda pair:
                        (sum(term in dumps(pair[1]).lower() for term in terms), pair[0]), reverse=True)
        results = []
        for index, item in scored:
            text = dumps(item)
            if terms and not any(term in text.lower() for term in terms):
                continue
            results.append({'position': index, 'excerpt': text[:1600], 'evidence_id': self.archive(item)})
            if len(results) == 5:
                break
        return {'matches': results, 'note': 'Historical data; user statements and tool evidence have different provenance.'}

    @staticmethod
    def safe_cuts(items):
        pending, cuts = set(), []
        for index, item in enumerate(items):
            if item.get('type') == 'function_call':
                pending.add(item['call_id'])
            elif item.get('type') == 'function_call_output':
                pending.discard(item['call_id'])
            if not pending:
                cuts.append(index+1)
        return cuts

    @staticmethod
    def memory_item(summary, items, cut):
        user_positions = [i for i, item in enumerate(items) if item.get('role') == 'user']
        pinned = []
        if user_positions:
            pinned.append(items[user_positions[0]])
            if user_positions[-1] < cut and user_positions[-1] != user_positions[0]:
                pinned.append(items[user_positions[-1]])
        return {'role': 'user', 'content': '<historical_task_memory untrusted="true">\n'+summary+
                '\nOriginal user intent excerpts (later corrections take precedence):\n'+
                '\n'.join(dumps(item)[:1800] for item in pinned)+'\n</historical_task_memory>'}

    async def fit(self, items, system, schemas, model):
        from context_builder import ContextBuilder
        return await ContextBuilder(self).fit(items, system, schemas, model)
