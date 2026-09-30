"""Actual Qwen/Ollama acceptance in temporary stores; never edits the user's chat."""
import argparse
import asyncio
import json
import os
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--baseline', action='store_true')
parser.add_argument('--bench', action='store_true')
args = parser.parse_args()
sys.path.insert(0, str(ROOT/('work/context-memory-before' if args.baseline else 'Resources/AgentTools')))
import agent_loop
from agent_loop import run_agent


async def main():
    out = ROOT/'work'/('context-memory-'+('before' if args.baseline else 'after')+'-'+time.strftime('%Y%m%d-%H%M%S'))
    out.mkdir(parents=True)
    sources = []
    counter = 0
    os.environ['CHILLOR_MEMORY_PATH'] = str(out/'personal.sqlite')
    os.environ['CHILLOR_MAX_TOKENS'] = '1024'
    records = []

    async def turn(task, text, history=None):
        nonlocal counter
        counter += 1
        current = {'role':'user','id':f'u{counter}','content':text,'taskID':task}
        sources.append(current)
        events = [];started = time.monotonic();first = None
        def capture(event):
            nonlocal first
            events.append(event)
            if first is None and event.get('type') == 'message' and any(p.get('type')=='text' and p.get('text') for p in event.get('message',{}).get('content',[])):
                first = time.monotonic()-started
        agent_loop.emit = capture
        result = await run_agent({'taskID':task,'taskCategory':'conversation', 'memorySources':sources,
            'conversation': (history or [])+[current]},
            'Reply concisely in Chinese. This is an offline conversation; no web research is needed.',
            lambda *a:None, [], out/task, use_mcp=False)
        record = {'request':text,'answer':str(result.final_output), 'first_s':round(first,3) if first else None,
                  'total_s':round(time.monotonic()-started,3),
                  'model_calls':len([e for e in events if e.get('type')=='performance']),
                  'input_tokens':[e.get('input_tokens') for e in events if e.get('type')=='performance'],
                  'context':[e for e in events if e.get('type')=='context_selected'],
                  'memory_ops':[e for e in events if e.get('type')=='memory_operation']}
        records.append(record)
        (out/'results.json').write_text(json.dumps(records,ensure_ascii=False,indent=2))
        print(json.dumps(record,ensure_ascii=False),flush=True)
        return str(result.final_output)

    if args.bench:
        for i in range(4):
            await turn(f'bench-{i}', '请用一句话解释为什么会有彩虹。')
    else:
        await turn('preferences', '以后用中文回答，回复简短。')
        await turn('identity', '请记住：我的代号是松鹤。')
        await turn('unrelated', '请用一句话解释月亮为什么会有圆缺。')
        recalled = await turn('recall-a', '我的代号是什么？只回答代号。')
        assert '松鹤' in recalled, recalled
        await turn('correction', '更正：我的代号改为青禾，请更新记忆。')
        recalled = await turn('recall-b', '我的代号是什么？只回答代号。')
        assert '青禾' in recalled and '松鹤' not in recalled, recalled
        await turn('forget', '请忘记我的代号。')
        recalled = await turn('recall-c', '我的代号是什么？不知道就说不知道。')
        assert '松鹤' not in recalled and '青禾' not in recalled, recalled
        history = [{'role':'user','id':'goal','content':'当前任务：蓝鹭采购方案，预算84270元，负责人周遥，交付proposal.md，仅本地草稿，不发布。'}]
        for i in range(35):
            history += [{'role':'assistant','content':'收到。'+('背景材料 '*160)},
                        {'role':'user','id':f'h{i}','content':('更正：预算改为94860元。' if i==3 else '')+f'资料{i}：'+('背景说明 '*100)}]
        sources.extend(m for m in history if m['role']=='user')
        answer = await turn('long-task','当前任务、最终预算、负责人、交付文件和发布限制是什么？只回答一小段，不保存新的长期记忆。',history)
        for term in ('蓝鹭','94860','周遥','proposal.md'):
            assert term in answer.replace(',',''), answer
        assert any(term in answer for term in ('不发布','不得发布','仅本地')), answer
        from personal_memory import PersonalMemory
        db = PersonalMemory(out/'personal.sqlite');db.db.close()
        print('PASS: cross-task/restart memory, correction, forgetting and 35-turn task context.',flush=True)
    print('Evidence: '+str(out),flush=True)


asyncio.run(main())
