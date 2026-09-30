"""Targeted real-model regression: recovery and fresh compaction after latency changes."""
import json, os, subprocess, sys, time, uuid
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
out = ROOT/'work'/('speed-live-'+time.strftime('%Y%m%d-%H%M%S'))
workspace = out/'workspace'
(workspace/'inputs').mkdir(parents=True)
(workspace/'inputs/brief.txt').write_text('项目海盐；负责人林川；预算73000元。')

def run(name, history):
    request = out/(name+'-request.json')
    request.write_text(json.dumps({'conversation': history}, ensure_ascii=False))
    env = dict(os.environ, CHILLOR_WORKSPACE=str(workspace), CHILLOR_STATE_DIR=str(out/(name+'-state')),
               CHILLOR_THINK='false', CHILLOR_NUM_CTX='16384', CHILLOR_MODEL='qwen3.8:27b', PYTHONDONTWRITEBYTECODE='1')
    started = time.monotonic()
    with (out/(name+'.jsonl')).open('w') as target:
        result = subprocess.run([sys.executable, '-B', str(ROOT/'Resources/AgentTools/server.py'), '--agent', str(request),
            '--system', 'Complete the task. Use tools when needed. Reply concisely in Chinese.'],
            env=env, stdout=target, stderr=subprocess.STDOUT, timeout=420)
    events=[]
    for line in (out/(name+'.jsonl')).read_text().splitlines():
        try: events.append(json.loads(line))
        except ValueError: pass
    text = ''.join(p.get('text','') for e in events if e.get('message',{}).get('role')=='assistant'
                   for p in e['message'].get('content',[]) if p.get('type')=='text')
    assert result.returncode==0 and any(e.get('type')=='complete' for e in events), (name, text)
    print(json.dumps({'name': name, 'seconds': round(time.monotonic()-started,2), 'answer': text,
                      'tools': [e['name'] for e in events if e.get('type')=='tool_performance']},ensure_ascii=False),flush=True)
    return text, events

def message(text): return {'role':'user','id':str(uuid.uuid4()),'content':text}
text, events = run('recovery', [message('先读取 inputs/brieff.txt，若路径不存在，自行查找正确的 brief 文件。将负责人和预算写入 recovered.md，再读回核对。')])
assert '73000' in (workspace/'recovered.md').read_text()
assert any(e.get('is_error') for e in events if e.get('type')=='tool_performance')
assert sum(e.get('name')=='read_file' for e in events)>=3
history=[message('当前任务：蓝鹭采购方案，预算84270元，负责人周遥，交付proposal.md，仅本地草稿，不发布。')]
for i in range(12):
    history.append({'role':'assistant','content':'收到，继续保留任务约束。'})
    correction='更正：预算现在改为94860元；请以新预算为准。' if i==1 else ''
    history.append(message(correction+'参考材料第%d批：'%i+'客户需要说明问题背景、使用场景、验收流程及交付边界。'*24))
history.append(message('我们正在做什么？请回答最终预算、负责人、交付文件名和发布限制。只答一小段，不创建文件。'))
text,events=run('long-memory',history)
assert all(term in text.replace(',','') for term in ['蓝鹭','94860','周遥','proposal.md']),text
assert any(term in text for term in ['不发布','不得发布','仅','本地']),text
assert any(e.get('type')=='context_compaction' for e in events)
print('PASS: real Qwen recovers from missing file, writes/verifies, retains corrected facts after fresh compaction; '+str(out),flush=True)
