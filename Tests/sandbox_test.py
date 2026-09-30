"""Sandbox gating and harvest checks that do not require macOS.

The isolation itself can only be proven on a Mac:
    Resources/AgentPython/bin/python3 Resources/AgentTools/sandbox.py
That prints each escape attempt and exits non-zero unless every one is blocked.
This file checks the surrounding contract: the tool must not exist unless the
probe passed, and results must come back through the validated commit path.
"""
import json, os, pathlib, shutil, sys, tempfile, types

os.chdir(pathlib.Path(__file__).resolve().parent.parent)
sys.path.insert(0, 'Resources/AgentTools')
import sandbox

ok = fail = 0
def check(name, fn):
    global ok, fail
    try:
        fn(); print('ok   '+name); ok += 1
    except Exception as e:
        print('FAIL '+name+': '+repr(e)); fail += 1


def load_server(**env):
    work = pathlib.Path(tempfile.mkdtemp(prefix='sbx-'))/'AgentWork/workspaces/task1'
    work.mkdir(parents=True)
    os.environ['CHILLOR_WORKSPACE'] = str(work)
    for key, value in env.items():
        os.environ[key] = value
    source = pathlib.Path('Resources/AgentTools/server.py').read_text(encoding='utf-8')
    module = types.ModuleType('server_under_test')
    exec(compile(source[:source.index("if '--preview'")], 'server.py', 'exec'), module.__dict__)
    return module, work


# ---- the gate ----------------------------------------------------------------
def absent_without_proof():
    module, _ = load_server(CHILLOR_CODE_EXECUTION='0')
    assert 'run_python' not in {t['name'] for t in module.TOOLS}, 'must not be offered when switched off'
    try:
        module.execute('run_python', {'code': 'print(1)'})
    except ValueError as e:
        assert 'unavailable' in str(e); return
    raise AssertionError('calling it anyway must be refused')
check('run_python is absent and refused when switched off', absent_without_proof)

def absent_when_probe_fails():
    module, work = load_server(CHILLOR_CODE_EXECUTION='1')
    cache = work.parent.parent/'sandbox-probe.json'
    cache.write_text(json.dumps({'stamp': pathlib.Path(sys.executable).stat().st_mtime_ns,
                                 'executable': sys.executable, 'time': 9e9,
                                 'result': {'ok': False, 'reason': 'test: isolation unproven'}}))
    state = sandbox.available(sys.executable, cache)
    assert state['ok'] is False
    # The next server gets a new workspace/cache; inject the failed probe there
    # rather than accidentally testing a fresh successful macOS probe.
    from unittest.mock import patch
    with patch.object(sandbox, 'available', return_value=state):
        module2, _ = load_server(CHILLOR_CODE_EXECUTION='1')
    assert not module2.SANDBOX['ok']
    assert 'run_python' not in {t['name'] for t in module2.TOOLS}
    try:
        module2.execute('run_python', {'code': 'print(1)'})
    except ValueError as error:
        assert 'unavailable' in str(error)
    else:
        raise AssertionError('failed isolation probe must refuse execution')
check('a failed probe keeps the tool out of the catalog', absent_when_probe_fails)

def no_sandbox_binary_means_no():
    saved = sandbox.SANDBOX_EXEC
    sandbox.SANDBOX_EXEC = '/nonexistent/sandbox-exec'
    try:
        report = sandbox.probe(sys.executable)
        assert report['ok'] is False and 'not present' in report['reason']
    finally:
        sandbox.SANDBOX_EXEC = saved
check('a missing sandbox-exec reports unavailable rather than running unconfined', no_sandbox_binary_means_no)

def stale_cache_reprobes():
    cache = pathlib.Path(tempfile.mkdtemp())/'probe.json'
    cache.write_text(json.dumps({'stamp': 1, 'executable': sys.executable, 'time': 0,
                                 'result': {'ok': True, 'reason': ''}}))
    saved = sandbox.SANDBOX_EXEC
    sandbox.SANDBOX_EXEC = '/nonexistent/sandbox-exec'
    try:
        assert sandbox.available(sys.executable, cache)['ok'] is False, 'a stale cache must not grant access'
    finally:
        sandbox.SANDBOX_EXEC = saved
check('a stale or mismatched cache re-probes instead of assuming yes', stale_cache_reprobes)


# ---- the profile -------------------------------------------------------------
def profile_denies():
    for style in ('carve', 'enumerate'):
        text = sandbox.profile('/tmp/run', '/opt/py/bin/python3', style)
        assert '(deny default)' in text, style
        assert '(deny network*)' in text, style
        # Exactly one write rule, and it names only the run directory.
        writes = [line for line in text.splitlines() if 'file-write' in line]
        assert writes == ['(allow file-write* (subpath "/tmp/run") (literal "/dev/null"))'], writes
        assert '(subpath "/opt/py")' in text, style
check('both profile styles deny by default and confine writes to the run directory', profile_denies)

def personal_areas_are_carved_out():
    text = sandbox.profile('/tmp/run', '/opt/py/bin/python3', 'carve')
    assert '(deny file-read*' in text
    for area in ('/Users', '/Volumes', '/private/var/root', '/Library/Keychains'):
        assert '(subpath "%s")' % area in text, area
    # The re-allow for the interpreter must come after the deny, or it is shadowed.
    # Measure inside the read section: the interpreter also appears in process-exec.
    deny_at = text.index('(deny file-read*')
    assert text.index('(allow file-read*', deny_at) > deny_at, 'no re-allow after the deny'
    assert '(subpath "/opt/py")' in text[text.index('(allow file-read*', deny_at):]
    enumerated = sandbox.profile('/tmp/run', '/opt/py/bin/python3', 'enumerate')
    assert '(subpath "/Users")' not in enumerated, 'the enumerate style must never list a personal area'
check('personal areas are excluded in both styles', personal_areas_are_carved_out)

def limits_are_irreversible():
    assert 'setrlimit(what, (value, value))' in sandbox.PRELUDE, 'soft and hard must be set together'
    assert sandbox.PRELUDE.index('setrlimit') < sandbox.PRELUDE.index('exec(compile'), \
        'limits must be set before user code runs'
check('resource limits are set irreversibly before user code runs', limits_are_irreversible)

def caps_are_bounded():
    assert sandbox.MAX_TIMEOUT <= 180 and sandbox.MAX_OUTPUT <= 50000
check('timeout and output are bounded', caps_are_bounded)


# ---- results come back through validation ------------------------------------
def harvest_uses_commit():
    module, work = load_server(CHILLOR_CODE_EXECUTION='1')
    module.SANDBOX = {'ok': True}
    import sandbox as real
    saved_run = real.run

    def fake_run(code, run_dir, executable, timeout=None, memory_mb=1024):
        d = pathlib.Path(run_dir)
        (d/'chart.png').write_bytes(b'\x89PNG\r\n\x1a\n' + b'0'*40)
        (d/'notes.md').write_text('hello', encoding='utf-8')
        return {'exit_code': 0, 'timed_out': False, 'stdout': 'done\n', 'stderr': '',
                'seconds': 0.1, 'produced': [{'name': 'chart.png', 'bytes': 48},
                                             {'name': 'notes.md', 'bytes': 5}]}
    real.run = fake_run
    try:
        result = module.execute('run_python', {'code': 'pass'})
    finally:
        real.run = saved_run
    names = {s.get('path') for s in result['saved_files']}
    assert names == {'chart.png', 'notes.md'}, result['saved_files']
    assert all('sha256' in s for s in result['saved_files']), 'harvest must go through commit()'
    assert (work/'notes.md').read_text() == 'hello'
    assert 'No network' in result['isolation']
check('produced files are re-validated and land in the task workspace', harvest_uses_commit)

def bad_input_path_refused():
    module, work = load_server(CHILLOR_CODE_EXECUTION='1')
    module.SANDBOX = {'ok': True}
    for bad in ('../../etc/passwd', '/etc/passwd', '.versions/x'):
        try:
            module.execute('run_python', {'code': 'pass', 'inputs': [bad]})
        except ValueError:
            continue
        raise AssertionError('input path escape accepted: '+bad)
check('input paths outside the workspace are refused', bad_input_path_refused)

def research_scope_excludes_it():
    module, _ = load_server(CHILLOR_CODE_EXECUTION='1', CHILLOR_TOOL_SCOPE='web')
    assert 'run_python' not in {t['name'] for t in module.TOOLS}
    os.environ['CHILLOR_TOOL_SCOPE'] = 'all'
check('the read-only research scope never gets code execution', research_scope_excludes_it)

print('\n%d/%d sandbox contract checks passed' % (ok, ok+fail))
print('NOTE: isolation itself is proven only by running sandbox.py on macOS.')
sys.exit(1 if fail else 0)
