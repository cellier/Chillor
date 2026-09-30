"""Large-artifact handling: chunked writes, in-place edits, context compaction.

Run: Resources/AgentPython/bin/python3 Tests/large_artifact_test.py
Covers the failure "the latest request/tool exchange exceeds local context capacity":
a whole file arriving as one tool argument and staying in the transcript forever.
Uses temporary workspaces only; no user data, no network.
"""
import os, pathlib
os.chdir(pathlib.Path(__file__).resolve().parent.parent)

import json, os, pathlib, shutil, sys, tempfile, types

WORK = pathlib.Path(tempfile.mkdtemp(prefix='toolfix-'))
os.environ['CHILLOR_WORKSPACE'] = str(WORK)
os.environ['PYTHONDONTWRITEBYTECODE'] = '1'
sys.path.insert(0, 'Resources/AgentTools')

# server.py ends in a bare MCP stdin loop, so load only the part above it.
source = pathlib.Path('Resources/AgentTools/server.py').read_text(encoding='utf-8')
cut = source.index("if '--preview'")
server = types.ModuleType('server_under_test'); server.__dict__['__name__'] = 'server_under_test'
exec(compile(source[:cut], 'server.py', 'exec'), server.__dict__)
execute, TOOLS = server.execute, server.TOOLS

ok = fail = 0
def check(name, fn):
    global ok, fail
    try:
        fn(); print('ok   '+name); ok += 1
    except Exception as e:
        print('FAIL '+name+': '+repr(e)); fail += 1

# ---- 1. chunked writing -------------------------------------------------------
def chunked_write():
    execute('write_text', {'path':'site/index.html','text':'<html><body>','mode':'replace'})
    for i in range(3):
        execute('write_text', {'path':'site/index.html','text':'<p>part %d</p>' % i,'mode':'append'})
    r = execute('write_text', {'path':'site/index.html','text':'</body></html>','mode':'append'})
    body = (WORK/'site/index.html').read_text()
    assert body == '<html><body><p>part 0</p><p>part 1</p><p>part 2</p></body></html>', body
    assert r['mode'] == 'append' and r['characters'] == len(body)
    assert 'sha256' in r and 'text' not in r, 'result must not echo the file back'
check('write_text append builds a file across several calls', chunked_write)

def replace_resets():
    execute('write_text', {'path':'site/a.md','text':'one','mode':'append'})
    execute('write_text', {'path':'site/a.md','text':'two'})
    assert (WORK/'site/a.md').read_text() == 'two'
check('default mode still replaces', replace_resets)

# ---- 2. edit_file -------------------------------------------------------------
def edit_unique():
    r = execute('edit_file', {'path':'site/index.html','find':'<p>part 1</p>','replace':'<h1>Hello</h1>'})
    assert r['replacements'] == 1
    assert '<h1>Hello</h1>' in (WORK/'site/index.html').read_text()
check('edit_file replaces a unique match', edit_unique)

def edit_ambiguous():
    execute('write_text', {'path':'site/b.md','text':'x\nx\n'})
    try:
        execute('edit_file', {'path':'site/b.md','find':'x','replace':'y'})
    except ValueError as e:
        assert '2 matches' in str(e), str(e)
        assert (WORK/'site/b.md').read_text() == 'x\nx\n', 'file must be untouched'
        return
    raise AssertionError('an ambiguous edit must be refused')
check('an ambiguous edit is refused and changes nothing', edit_ambiguous)

def edit_all():
    r = execute('edit_file', {'path':'site/b.md','find':'x','replace':'y','replace_all':True})
    assert r['replacements'] == 2 and (WORK/'site/b.md').read_text() == 'y\ny\n'
check('replace_all edits every occurrence', edit_all)

def edit_missing():
    try:
        execute('edit_file', {'path':'site/b.md','find':'nope','replace':'z'})
    except ValueError as e:
        assert 'No match' in str(e); return
    raise AssertionError('a non-matching edit must be refused')
check('a non-matching edit is refused', edit_missing)

def edit_versions():
    assert list((WORK/'.versions').glob('*')), 'edits must leave a backup'
check('edits keep .versions backups', edit_versions)

def edit_escape():
    for bad in ('../../etc/passwd', '/etc/passwd', '.versions/x.md'):
        try:
            execute('edit_file', {'path':bad,'find':'a','replace':'b'})
        except ValueError:
            continue
        raise AssertionError('path escape accepted: '+bad)
check('edit_file still rejects path escapes', edit_escape)

def edit_binary():
    try:
        execute('edit_file', {'path':'site/x.pptx','find':'a','replace':'b'})
    except ValueError as e:
        assert 'Unsupported text file type' in str(e); return
    raise AssertionError('Office files must not go through edit_file')
check('edit_file refuses Office formats', edit_binary)

# ---- declarations -------------------------------------------------------------
def declared():
    names = {t['name'] for t in TOOLS}
    assert {'edit_file','fetch_image'} <= names, names
    wt = next(t for t in TOOLS if t['name']=='write_text')
    assert wt['inputSchema']['properties']['mode']['enum'] == ['replace','append']
check('new tools are declared with schemas', declared)

def web_scope():
    os.environ['CHILLOR_TOOL_SCOPE'] = 'web'
    try:
        for name in ('edit_file','fetch_image','write_text'):
            try:
                execute(name, {'path':'x.md','text':'y','find':'a','replace':'b','url':'https://e.com/a.png'})
            except ValueError as e:
                assert 'read-only tools' in str(e), name+': '+str(e)
            else:
                raise AssertionError(name+' must be blocked in the read-only research scope')
    finally:
        os.environ['CHILLOR_TOOL_SCOPE'] = 'all'
check('research scope stays read-only', web_scope)

shutil.rmtree(WORK, ignore_errors=True)
TOOL_OK, TOOL_FAIL = ok, fail


import asyncio, json, pathlib, sys, tempfile

sys.path.insert(0, 'Resources/AgentTools')
from agent_context import LocalState, dumps, tokens
from context_builder import ContextBuilder


class Model:
    num_ctx = 16384
    num_predict = 4096


def build(items, system='sys'):
    state = LocalState(tempfile.mkdtemp(prefix='ctx-'), lambda _e: None)
    state.task_title = ''
    state.begin_request({'id': 'u1', 'role': 'user', 'content': 'go'})
    result = asyncio.run(ContextBuilder(state).fit(items, system, [], Model()))
    state.db.close()
    return result


def pairs_intact(view):
    calls = {i['call_id'] for i in view if i.get('type') == 'function_call'}
    outs = {i['call_id'] for i in view if i.get('type') == 'function_call_output'}
    assert outs <= calls, 'a tool result must never outlive its call'
    return True


ok = fail = 0


HUGE = '<div>'+('x'*40000)+'</div>'

def archives_old_arguments():
    items = [{'type':'message','role':'user','content':'build a page'}]
    for n in range(4):
        items += [{'type':'function_call','call_id':'c%d'%n,'name':'write_text',
                   'arguments':json.dumps({'path':'a.html','text':HUGE})},
                  {'type':'function_call_output','call_id':'c%d'%n,'output':'{"path":"a.html","sha256":"ab"}'}]
    view = build(items)
    archived = [i for i in view if i.get('type')=='function_call' and 'archived_arguments' in str(i.get('arguments'))]
    assert archived, 'large settled arguments must be archived'
    assert all('evidence_id' in str(i['arguments']) for i in archived), 'archive must leave a retrievable pointer'
    for item in archived:
        json.loads(item['arguments'])  # replay requires valid JSON
    pairs_intact(view)
check('oversized tool arguments are archived with a valid-JSON pointer', archives_old_arguments)

def single_huge_call_no_longer_fails():
    # Exactly the shape that produced "exceeds local context capacity".
    items = [{'type':'message','role':'user','content':'做一个 html 版本吧'},
             {'type':'function_call','call_id':'c1','name':'write_text',
              'arguments':json.dumps({'path':'index.html','text':HUGE})},
             {'type':'function_call_output','call_id':'c1','output':'{"path":"index.html","sha256":"ab"}'}]
    budget = Model.num_ctx-Model.num_predict-tokens('sys')-tokens([])-1024
    assert tokens(items) > budget, 'the fixture must exceed the budget before compaction'
    view = build(items)
    assert tokens(view) <= budget, 'compaction must bring it under budget'
    pairs_intact(view)
check('a single oversized write no longer fails the turn', single_huge_call_no_longer_fails)

def latest_request_survives():
    items = [{'type':'message','role':'user','content':'原始目标：预算 84270，负责人周遥'},
             {'type':'function_call','call_id':'c1','name':'write_text',
              'arguments':json.dumps({'path':'a.html','text':HUGE})},
             {'type':'function_call_output','call_id':'c1','output':HUGE},
             {'type':'message','role':'user','content':'把标题改成 Hello'}]
    view = build(items)
    assert any(i.get('role')=='user' and '把标题改成 Hello' in str(i.get('content')) for i in view), \
        'the latest request must never be dropped'
    pairs_intact(view)
check('the latest user request always survives compaction', latest_request_survives)

def truly_impossible_is_actionable():
    class Tiny(Model):
        num_ctx, num_predict = 8192, 4096
    state = LocalState(tempfile.mkdtemp(prefix='ctx-'), lambda _e: None)
    state.task_title = ''
    state.begin_request({'id':'u1','role':'user','content':'go'})
    items = [{'type':'message','role':'user','content':'x'*200000}]
    try:
        asyncio.run(ContextBuilder(state).fit(items, 'sys', [], Tiny()))
    except RuntimeError as e:
        assert 'append' in str(e) and 'edit_file' in str(e), 'the error must say how to split the work: '+str(e)
        return
    finally:
        state.db.close()
    raise AssertionError('an un-splittable item must still raise')
check('an impossible step fails with actionable advice', truly_impossible_is_actionable)


TOTAL_OK, TOTAL_FAIL = TOOL_OK+ok, TOOL_FAIL+fail
print('\n%d/%d checks passed' % (TOTAL_OK, TOTAL_OK+TOTAL_FAIL))
sys.exit(1 if TOTAL_FAIL else 0)
