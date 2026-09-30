"""Real DeepSeek acceptance through the actual Agents SDK loop.

Run: CHILLOR_API_KEY=... Resources/AgentPython/bin/python3 Tests/deepseek_live_eval.py
Uses an isolated workspace under work/deepseek-eval. Never touches user chat,
personal memory or the production task database. Costs real API tokens.
"""
import asyncio
import json
import os
import pathlib
import shutil
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT/'Resources/AgentTools'))

WORK = ROOT/'work/deepseek-eval'
if WORK.exists():
    shutil.rmtree(WORK)
(WORK/'workspace/inputs').mkdir(parents=True)
(WORK/'workspace/inputs/launch-brief.txt').write_text(
    '蓝鹭项目\n负责人：周遥\n预算：84270 元\n交付物：proposal.md\n', encoding='utf-8')

os.environ.update({
    'CHILLOR_PROVIDER': 'deepseek',
    'CHILLOR_MODEL': os.environ.get('CHILLOR_MODEL', 'deepseek-flash'),
    'CHILLOR_WORKSPACE': str(WORK/'workspace'),
    'CHILLOR_STATE_DIR': str(WORK/'state'),
    'CHILLOR_MEMORY_PATH': str(WORK/'personal.sqlite'),
    'CHILLOR_NUM_CTX': '65536',
    'CHILLOR_MAX_TOKENS': '8192',
    'CHILLOR_TOOL_SCOPE': 'all',
    'CHILLOR_DESKTOP_BRIDGE': '0',
    'PYTHONDONTWRITEBYTECODE': '1',
})
key = os.environ.get('CHILLOR_API_KEY', '')
if not key or not key.startswith('sk-') or len(key) < 20 or '...' in key:
    sys.exit('Set CHILLOR_API_KEY to the real DeepSeek key (got: '+(repr(key) if key else 'unset')+').')

import agent_loop


def unavailable(name, args):
    # Only desktop_control would reach this; the workspace tools come from MCP.
    raise ValueError('Tool '+name+' is not available in the live evaluation')

SYSTEM = ('Work on workspace copies; read inputs before editing. Return actual files, not code '
          'blocks. Do not claim visual verification. Reply in the user\'s language.')

CASES = [
    ('plain answer, no tools', '用一句话说明什么是彩虹。', lambda t, a: len(t) > 4 and not a),
    ('finds and reads a file it was not given the path to',
     '工作区里有一份 launch brief，找出来读一下，告诉我负责人是谁、预算多少。',
     lambda t, a: '周遥' in t and ('84270' in t.replace(',', '') or '84,270' in t)),
    ('recovers from a wrong path and still answers',
     '先读 inputs/launch-breif.txt（就是这个名字），把交付物名字告诉我。',
     lambda t, a: 'proposal.md' in t),
    ('creates a real file and reads it back',
     '把蓝鹭项目的负责人和预算写成 summary.md 保存到工作区，然后读回确认内容。',
     lambda t, a: (pathlib.Path(os.environ['CHILLOR_WORKSPACE'])/'summary.md').is_file()),
]


async def run_case(prompt):
    transcript, artifacts = [], []

    def emit(value):
        if value.get('type') == 'message':
            for part in value['message'].get('content', []):
                if part.get('type') == 'text':
                    transcript.append(part['text'])
                elif part.get('type') == 'toolRequest':
                    artifacts.append(part['toolCall']['value']['name'])

    original = agent_loop.emit
    agent_loop.emit = emit
    try:
        request = {'conversation': [{'role': 'user', 'content': prompt, 'id': 'u-'+str(time.time())}],
                   'taskID': 'live-eval', 'taskTitle': 'live eval', 'taskCategory': 'conversation',
                   'importedFiles': ['inputs/launch-brief.txt']}
        # use_mcp=True spawns server.py exactly as the app does: real MCP stdio
        # transport, real tool discovery, real DeepSeek adapter.
        await agent_loop.run_agent(request, SYSTEM, unavailable, [], str(WORK/'state'), use_mcp=True)
    finally:
        agent_loop.emit = original
    return ''.join(transcript), artifacts


async def main():
    failures = 0
    for name, prompt, predicate in CASES:
        started = time.monotonic()
        try:
            text, tools = await run_case(prompt)
            ok = predicate(text, tools)
        except Exception as error:
            text, tools, ok = repr(error), [], False
        failures += 0 if ok else 1
        print(('ok   ' if ok else 'FAIL ')+name+'  %.1fs  tools=%s' % (time.monotonic()-started, tools))
        print('     '+text.strip().replace('\n', ' ')[:160])
    print('\n%d/%d live cases passed · model=%s' % (len(CASES)-failures, len(CASES), os.environ['CHILLOR_MODEL']))
    print('evidence: '+str(WORK))
    sys.exit(1 if failures else 0)


asyncio.run(main())
