"""Offline checks for the DeepSeek adapter. No network, no key, no user data.

Run: Resources/AgentPython/bin/python3 Tests/deepseek_model_test.py
Live acceptance against the real API lives in Tests/deepseek_live_eval.py.
"""
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent/'Resources/AgentTools'))

import deepseek_model as d

checks = []


def check(name):
    def wrap(function):
        checks.append((name, function))
        return function
    return wrap


@check('tool call and result stay paired and ordered')
def _():
    items = [{'type': 'message', 'role': 'user', 'content': '列出文件'},
             {'type': 'function_call', 'call_id': 'c1', 'name': 'list_files', 'arguments': '{}'},
             {'type': 'function_call_output', 'call_id': 'c1', 'output': '{"files":["a.md"]}'},
             {'type': 'message', 'role': 'assistant', 'content': '有 a.md'}]
    out = d.to_openai(items, 'deepseek-flash')
    assert out[1]['tool_calls'][0]['id'] == 'c1'
    assert out[2] == {'role': 'tool', 'tool_call_id': 'c1', 'content': '{"files":["a.md"]}'}


@check('an orphaned tool result is dropped, never sent unpaired')
def _():
    assert d.to_openai([{'type': 'function_call_output', 'call_id': 'ghost', 'output': 'x'}], 'deepseek-flash') == []


@check('several calls in one round share one assistant message')
def _():
    items = [{'type': 'function_call', 'call_id': 'a', 'name': 't', 'arguments': '{}'},
             {'type': 'function_call', 'call_id': 'b', 'name': 't', 'arguments': '{}'},
             {'type': 'function_call_output', 'call_id': 'a', 'output': '1'},
             {'type': 'function_call_output', 'call_id': 'b', 'output': '2'}]
    out = d.to_openai(items, 'deepseek-flash')
    assert len(out[0]['tool_calls']) == 2
    assert [item['role'] for item in out[1:]] == ['tool', 'tool']


@check('images reach a vision model and are stripped with a warning otherwise')
def _():
    item = [{'type': 'message', 'role': 'user',
             'content': [{'type': 'input_text', 'text': '看图'},
                         {'type': 'input_image', 'image_url': 'data:image/png;base64,AAAA'}]}]
    vision = d.to_openai(item, 'deepseek-flash')
    assert vision[0]['content'] == [{'type': 'text', 'text': '看图'},
                                    {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,AAAA'}}]
    blind = d.to_openai(item, 'deepseek-v4-pro')
    assert blind[0]['role'] == 'system' and 'cannot read images' in blind[0]['content']
    assert blind[1]['content'] == '看图', 'text must survive intact when the image is dropped'


@check('a non-data image URL is never forwarded')
def _():
    item = [{'type': 'message', 'role': 'user',
             'content': [{'type': 'input_image', 'image_url': 'https://example.com/a.png'}]}]
    assert d.to_openai(item, 'deepseek-flash')[0]['content'] == ''


@check('streamed tool-call fragments merge into valid JSON arguments')
def _():
    pending = {}
    for delta in ([{'index': 0, 'id': 'call_9', 'type': 'function', 'function': {'name': 'write_text', 'arguments': ''}}],
                  [{'index': 0, 'function': {'arguments': '{"path":"a'}}],
                  [{'index': 0, 'function': {'arguments': '.md"}'}}]):
        d.DeepSeekModel.merge_tool_calls(pending, delta)
    assert pending[0] == {'id': 'call_9', 'name': 'write_text', 'arguments': '{"path":"a.md"}'}
    json.loads(pending[0]['arguments'])


@check('parallel streamed calls stay separated by index')
def _():
    pending = {}
    d.DeepSeekModel.merge_tool_calls(pending, [
        {'index': 0, 'id': 'x', 'function': {'name': 'read_file', 'arguments': '{"path":"1"}'}},
        {'index': 1, 'id': 'y', 'function': {'name': 'read_file', 'arguments': '{"path":"2"}'}}])
    assert [pending[i]['id'] for i in sorted(pending)] == ['x', 'y']


@check('failures are actionable and never echo the credential')
def _():
    assert 'API key' in d.DeepSeekModel.describe(401, '')
    assert 'balance' in d.DeepSeekModel.describe(402, '')
    assert 'rate limiting' in d.DeepSeekModel.describe(429, '')
    assert d.DeepSeekModel.describe(500, '{"error":{"message":"boom"}}') == 'boom'
    assert d.DeepSeekModel.describe(503, 'not json').startswith('DeepSeek could not complete')


@check('developer role is normalised to system')
def _():
    assert d.to_openai([{'type': 'message', 'role': 'developer', 'content': 'x'}], 'deepseek-flash')[0]['role'] == 'system'


@check('an absent key fails fast instead of sending an unauthenticated request')
def _():
    import os
    saved = os.environ.pop('CHILLOR_API_KEY', None)
    try:
        try:
            d.DeepSeekModel(lambda _event: None)
        except ValueError as error:
            assert 'API key' in str(error)
        else:
            raise AssertionError('a missing key must raise')
    finally:
        if saved is not None:
            os.environ['CHILLOR_API_KEY'] = saved


@check('an implausible context/output budget is rejected')
def _():
    import os
    os.environ['CHILLOR_API_KEY'] = 'test-only-not-a-real-key'
    os.environ['CHILLOR_NUM_CTX'] = '4096'
    try:
        try:
            d.DeepSeekModel(lambda _event: None)
        except ValueError:
            pass
        else:
            raise AssertionError('too small a context must raise')
    finally:
        os.environ.pop('CHILLOR_NUM_CTX', None)
        os.environ.pop('CHILLOR_API_KEY', None)


if __name__ == '__main__':
    failures = 0
    for name, function in checks:
        try:
            function()
            print('ok   '+name)
        except Exception as error:
            failures += 1
            print('FAIL '+name+': '+repr(error))
    print(('%d/%d checks passed' % (len(checks)-failures, len(checks))))
    sys.exit(1 if failures else 0)
