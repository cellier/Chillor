"""Local, source-bound personal memory. No model calls, network or attachment ingestion.

SQLite is authoritative. A source is a user-authored chat message, never assistant
text or tool output. Revisions retain provenance; forgetting removes their values
and prevents historical messages from silently teaching them again.
"""
import json
import re
import sqlite3
import time
import unicodedata
from pathlib import Path


def terms(text):
    text = unicodedata.normalize('NFKC', text).lower()
    words = re.findall(r'[a-z0-9_]+', text)
    for run in re.findall(r'[\u3400-\u9fff]+', text):
        words.extend(run[i:i+2] for i in range(len(run)-1))
    return list(dict.fromkeys(words))[:100]


class PersonalMemory:
    def __init__(self, path, task_id='', current_id=''):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(self.path, timeout=3)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript('''
          CREATE TABLE IF NOT EXISTS memory_sources (
            id TEXT PRIMARY KEY, task_id TEXT, body TEXT NOT NULL,
            date TEXT, status TEXT NOT NULL DEFAULT 'active');
          CREATE TABLE IF NOT EXISTS memories (
            id INTEGER PRIMARY KEY, scope TEXT NOT NULL, key TEXT NOT NULL,
            value TEXT NOT NULL, quote TEXT NOT NULL, source_id TEXT NOT NULL,
            updated REAL NOT NULL, status TEXT NOT NULL, replaces INTEGER);
          CREATE UNIQUE INDEX IF NOT EXISTS memory_active_key ON memories(scope,key)
            WHERE status='active';
          CREATE VIRTUAL TABLE IF NOT EXISTS memory_search USING fts5(terms);
          CREATE TABLE IF NOT EXISTS forgotten_spans (source_id TEXT, start INTEGER, length INTEGER,
            PRIMARY KEY(source_id,start,length));
          CREATE TABLE IF NOT EXISTS memory_hidden_messages (id TEXT PRIMARY KEY);
          CREATE TRIGGER IF NOT EXISTS memory_remove_search AFTER UPDATE OF status ON memories
            WHEN new.status != 'active' BEGIN DELETE FROM memory_search WHERE rowid=new.id; END;
        ''')
        self.path.chmod(0o600)
        self.task_id, self.current_id = task_id, current_id
        self.blocked_text = []
        self.source_bodies = {}

    def sync(self, messages, authoritative=False):
        """Incremental source migration; absent/deleted sources cannot be recalled.

        An authoritative manifest comes from the app's current conversation, not
        from a task's truncated model context. Missing sources never reactivate.
        """
        sources = [m for m in messages if m.get('role') == 'user' and m.get('id')]
        visible = {m['id'] for m in sources}
        with self.db:
            if authoritative:
                removed = [r['id'] for r in self.db.execute(
                    "SELECT id FROM memory_sources WHERE status IN ('active','redacted')") if r['id'] not in visible]
                for source_id in removed:
                    self.invalidate_source(source_id, 'deleted')
            for source in sources:
                body = source.get('text', source.get('content', ''))
                if not isinstance(body, str):
                    continue
                self.source_bodies[source['id']] = body
                row = self.db.execute('SELECT * FROM memory_sources WHERE id=?', (source['id'],)).fetchone()
                if row and row['status'] != 'active':
                    self.blocked_text.append(body)
                    for span in self.db.execute('SELECT start,length FROM forgotten_spans WHERE source_id=?', (source['id'],)):
                        self.blocked_text.append(body[span[0]:span[0]+span[1]])
                    continue
                if row and row['body'] != body:
                    self.db.execute("UPDATE memories SET status='superseded' WHERE source_id=? AND status='active'", (source['id'],))
                if row and row['body'] == body and row['task_id'] == source.get('taskID', self.task_id):
                    continue
                self.db.execute('INSERT INTO memory_sources(id,task_id,body,date) VALUES (?,?,?,?) '
                    'ON CONFLICT(id) DO UPDATE SET body=excluded.body,task_id=excluded.task_id,date=excluded.date',
                    (source['id'], source.get('taskID', self.task_id), body, str(source.get('date', ''))))

    def invalidate_source(self, source_id, status='forgotten'):
        original = self.db.execute('SELECT body FROM memory_sources WHERE id=?', (source_id,)).fetchone()
        if original and original[0]:
            self.blocked_text.append(original[0])
            for row in self.db.execute('SELECT value,quote FROM memories WHERE source_id=?', (source_id,)):
                for fragment in row:
                    start = original[0].find(fragment) if fragment else -1
                    if start >= 0:
                        self.blocked_text.append(fragment)
                        self.db.execute('INSERT OR IGNORE INTO forgotten_spans VALUES (?,?,?)', (source_id, start, len(fragment)))
        self.db.execute('UPDATE memories SET status=?,value=\'\',quote=\'\' WHERE source_id=?', (status, source_id))
        self.db.execute('UPDATE memory_sources SET status=?,body=\'\' WHERE id=?', (status, source_id))

    def blocked_ids(self):
        return {r[0] for r in self.db.execute("SELECT id FROM memory_sources WHERE status!='active' UNION SELECT id FROM memory_hidden_messages")}

    def redact(self, text):
        # UI chat remains visible; model-facing copies must not revive forgotten sources.
        for body in self.blocked_text:
            if body:
                text = text.replace(body, '[Forgotten source omitted]')
        return text

    def redact_items(self, items):
        def clean(value):
            if isinstance(value, str):
                return self.redact(value)
            if isinstance(value, list):
                return [clean(v) for v in value]
            if isinstance(value, dict):
                return {k: clean(v) if k in ('content', 'text', 'output', 'quote', 'value', 'arguments') else v for k, v in value.items()}
            return value
        return [clean(item) for item in items]

    def filter_history(self, messages):
        blocked = self.blocked_ids()
        result = []
        for message in messages:
            if message.get('id') in blocked or message.get('replyTo') in blocked:
                continue
            entry = dict(message)
            if isinstance(entry.get('content'), str):
                entry['content'] = self.redact(entry['content'])
            result.append(entry)
        return result

    def remember(self, key, value, quote, scope='global', source_id=None):
        source_id = source_id or self.current_id
        if source_id != self.current_id:
            raise ValueError('Memory writes require the current user message, not historical or tool text.')
        row = self.db.execute("SELECT * FROM memory_sources WHERE id=? AND status='active'", (source_id,)).fetchone()
        if not row or not quote.strip() or quote not in row['body'] or value not in quote:
            raise ValueError('Value and exact quote must occur verbatim in the current user message.')
        key = unicodedata.normalize('NFKC', key).strip().lower()
        if not key or len(key) > 100 or not value.strip() or len(value) > 600 or len(quote) > 1000:
            raise ValueError('Use a short stable key, value and source quote.')
        if scope not in ('global', 'task:'+self.task_id) and not (scope.startswith('project:') and 0 < len(scope[8:]) <= 80 and scope[8:] in quote):
            raise ValueError('Scope must be global, the current task, or project:<name explicitly in the quote>.')
        # Never convert a quoted passage, pasted document or a question into a user fact.
        if any(marker in quote for marker in ('```', '<attachment', '\n>', '？', '?')):
            raise ValueError('Quoted documents and questions are not personal memory.')
        if re.search(r'(?i)(password|api[_ -]?key|access[_ -]?token|密码|密钥)\s*[:：=]', quote):
            raise ValueError('Credentials do not belong in personal memory.')
        previous = self.db.execute("SELECT * FROM memories WHERE scope=? AND key=? AND status='active'", (scope, key)).fetchone()
        if previous and previous['value'] == value and previous['source_id'] == source_id:
            return self.record(previous)
        with self.db:
            if previous:
                self.db.execute("UPDATE memories SET status='superseded' WHERE id=?", (previous['id'],))
            cursor = self.db.execute('INSERT INTO memories(scope,key,value,quote,source_id,updated,status,replaces) VALUES (?,?,?,?,?,?,?,?)',
                (scope, key, value, quote, source_id, time.time(), 'active', previous['id'] if previous else None))
            memory_id = cursor.lastrowid
            self.db.execute('INSERT INTO memory_search(rowid,terms) VALUES (?,?)',
                (memory_id, ' '.join(terms(scope+' '+key+' '+value+' '+quote))))
        return self.record(self.db.execute('SELECT * FROM memories WHERE id=?', (memory_id,)).fetchone())

    @staticmethod
    def record(row):
        return {k: row[k] for k in ('id', 'scope', 'key', 'value', 'quote', 'source_id', 'updated', 'replaces')}

    def search(self, query='', scope=None, limit=6):
        limit = max(1, min(20, int(limit)))
        keywords = terms(query)
        sql = "SELECT m.* FROM memories m JOIN memory_sources s ON s.id=m.source_id WHERE m.status='active' AND s.status IN ('active','redacted')"
        sql += " AND (m.scope NOT LIKE 'task:%' OR m.scope=?)"
        args = ['task:'+self.task_id]
        if scope:
            sql += ' AND m.scope=?';args.append(scope)
        if keywords:
            sql += ' AND m.id IN (SELECT rowid FROM memory_search WHERE memory_search MATCH ?)'
            args.append(' OR '.join('"'+word+'"' for word in keywords))
        sql += ' ORDER BY m.updated DESC,m.id DESC LIMIT ?';args.append(limit)
        return [self.record(row) for row in self.db.execute(sql, args)]

    def search_sources(self, query):
        """Explicit recall fallback for pre-upgrade user messages, not learned facts.

        No assistant answers or attachment bodies are indexed as user knowledge.
        Bounded keyword lookup avoids an up-front model migration of the archive.
        """
        keywords = [t for t in terms(query) if t not in {'我的','什么','记得','之前','以前','我们','聊天','请问','what','my','is','the','you','remember'}][:12]
        if not keywords:
            return []
        match = ' OR '.join("body LIKE ? ESCAPE '\\'" for _ in keywords)
        rows = self.db.execute("SELECT id,body,date FROM memory_sources WHERE status='active' AND id!=? AND ("+match+") ORDER BY rowid DESC LIMIT 6",
                               [self.current_id]+['%'+t.replace('_','\\_')+'%' for t in keywords])
        result = []
        for row in rows:
            body = row['body']
            position = next((body.lower().find(t) for t in keywords if t in body.lower()), 0)
            start = max(0, position-100)
            result.append({'source_id':row['id'], 'date':row['date'], 'excerpt':self.redact(body[start:start+700]),
                           'kind':'historical_user_statement_not_a_verified_fact'})
        return result

    def context(self, query):
        # Only universal style preferences are unconditional. Facts about other
        # projects/people require retrieval; task memories never cross task scope.
        preferences = [self.record(r) for r in self.db.execute(
            "SELECT * FROM memories WHERE status='active' AND scope='global' AND key IN ('response_language','response_length') ORDER BY updated DESC LIMIT 2")]
        records = preferences + self.search(query, limit=8)
        seen, selected, budget = set(), [], 2200
        for row in records:
            if row['scope'].startswith('task:') and row['scope'] != 'task:'+self.task_id:
                continue
            if row['id'] in seen:
                continue
            seen.add(row['id'])
            if len(json.dumps(row, ensure_ascii=False)) > budget:
                continue
            selected.append(row);budget -= len(json.dumps(row, ensure_ascii=False))
        return selected

    def forget(self, ids):
        if not ids or len(ids) > 20:
            raise ValueError('Search first and provide 1-20 exact memory IDs to forget.')
        forgotten = []
        with self.db:
            for memory_id in ids:
                row = self.db.execute('SELECT * FROM memories WHERE id=?', (memory_id,)).fetchone()
                if not row:
                    continue
                # Remove all revisions so forgetting a correction cannot revive an old value.
                revisions = self.db.execute('SELECT source_id,value FROM memories WHERE scope=? AND key=?', (row['scope'], row['key'])).fetchall()
                sources = {r['source_id'] for r in revisions}
                for source in sources:
                    original = self.db.execute('SELECT body FROM memory_sources WHERE id=?', (source,)).fetchone()
                    if source in self.source_bodies:
                        original = (self.source_bodies[source],)
                    fragments = [r['value'] for r in revisions if r['source_id'] == source and r['value']]
                    if original and original[0]:
                        self.blocked_text.append(original[0])
                        for fragment in fragments:
                            start = original[0].find(fragment)
                            if start >= 0:
                                self.db.execute('INSERT OR IGNORE INTO forgotten_spans VALUES (?,?,?)', (source, start, len(fragment)))
                    self.blocked_text.extend(fragments)
                    self.db.execute("UPDATE memories SET status='forgotten',value='',quote='' WHERE scope=? AND key=? AND source_id=?", (row['scope'], row['key'], source))
                    # A single message can supply several preferences. Forget the
                    # requested fact, retaining independently supported ones while
                    # removing the forgotten fragment from their quotes/search.
                    remaining = self.db.execute("SELECT * FROM memories WHERE source_id=? AND status='active'", (source,)).fetchall()
                    for other in remaining:
                        quote = other['quote']
                        for fragment in fragments:
                            quote = quote.replace(fragment, '[Forgotten detail]')
                        self.db.execute('UPDATE memories SET quote=? WHERE id=?', (quote, other['id']))
                        self.db.execute('DELETE FROM memory_search WHERE rowid=?', (other['id'],))
                        self.db.execute('INSERT INTO memory_search(rowid,terms) VALUES (?,?)',
                            (other['id'], ' '.join(terms(other['scope']+' '+other['key']+' '+other['value']+' '+quote))))
                    self.db.execute('UPDATE memory_sources SET status=?,body=\'\' WHERE id=?', ('redacted' if remaining else 'forgotten', source))
                forgotten.append(memory_id)
        return {'forgotten_ids': forgotten, 'note': 'Selected memory and all its revisions removed. Source chat stays visible but cannot relearn forgotten details; other saved facts from that message remain.'}

    def capture_explicit_preferences(self):
        """Cheap common cases; other durable facts use the source-bound SDK tool.

        Only inspect the current direct user message, never historical imports.
        No idle model competes with foreground inference.
        """
        source = self.db.execute("SELECT body FROM memory_sources WHERE id=? AND status='active'", (self.current_id,)).fetchone()
        if not source:
            return []
        text = source[0].strip()
        if len(text) > 350 or any(x in text for x in ('\n', '```', '“', '”', '"', '「', '」', '?', '？', '忘记', 'forget')):
            return []
        saved = []
        language = re.search(r'(?:以后|今后|从现在起|请记住)[^。；;]{0,30}?(?:用|使用)(中文|英文|英语|日语)(?:回答|回复|交流|和我)', text)
        if language:
            saved.append(self.remember('response_language', language[1], text))
        length = re.search(r'(?:以后|今后|从现在起|请记住)[^。；;]{0,30}?(?:回答|回复)[^。；;]{0,8}?(简短|简洁|详细)', text)
        if length:
            saved.append(self.remember('response_length', length[1], text))
        return saved
