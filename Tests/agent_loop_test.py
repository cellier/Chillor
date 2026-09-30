"""Integration checks against the real SDK Runner, with deterministic model responses."""
import asyncio
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'Resources/AgentTools'))
import agent_loop
from agent_loop import run_agent
from agent_context import LocalState, tokens
from ollama_model import OllamaModel, to_ollama

DEF = [
    {'name':'list_files','description':'Discover files','inputSchema':{'type':'object','properties':{}}},
    {'name':'read_file','description':'Read task file','inputSchema':{'type':'object','properties':{'path':{'type':'string'}},'required':['path']}},
    {'name':'write_text','description':'Write text file','inputSchema':{'type':'object','properties':{'path':{'type':'string'},'text':{'type':'string'}},'required':['path','text']}}
]
def call(name, args):return {'function':{'name':name,'arguments':args}}
def reply(text='', calls=None):return text, '', calls or [], {'eval_count':8,'prompt_eval_count':20}

class SDKChecks(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.directory=Path(self.tmp.name)
        self.events=[];self.payloads=[];self.executed=[]
        self.responses=[]
        async def chat(model, messages, tools=(), **kwargs):
            self.payloads.append({'messages':messages,'tools':tools})
            if not self.responses:raise AssertionError('Unexpected model request')
            return self.responses.pop(0)
        self.patcher=patch.object(OllamaModel,'chat',chat);self.patcher.start();self.addCleanup(self.patcher.stop)
        self.emitter=patch.object(agent_loop,'emit',self.events.append);self.emitter.start();self.addCleanup(self.emitter.stop)
    def execute(self,name,args):
        self.executed.append((name,args))
        if name=='read_file' and args['path']=='missing':raise FileNotFoundError('File not found: missing')
        return {'text':'海盐 73000','path':args.get('path','inputs/brief.txt')}
    async def run_turn(self, history):
        return await run_agent({'conversation':history},'test',self.execute,DEF,self.directory,use_mcp=False)
    async def test_introduction_runs_sdk_without_mcp_or_tools(self):
        self.responses = [reply('我是 Chillor。')]
        with patch.object(agent_loop, 'MCPServerStdio', side_effect=AssertionError('Unnecessary MCP startup')):
            result = await run_agent({'responseProfile': 'introduction', 'conversation': [
                {'role': 'system', 'content': 'Describe Chillor briefly.'},
                {'id': 'intro', 'role': 'user', 'content': '你是谁，你能做什么？'}]},
                'unrelated long policy', self.execute, DEF, self.directory)
        self.assertEqual(result.final_output, '我是 Chillor。')
        self.assertEqual(len(self.payloads), 1)
        self.assertFalse(self.payloads[0]['tools'])
        self.assertNotIn('unrelated long policy', str(self.payloads))
        self.assertFalse(self.executed)

    async def test_task_bundle_skips_tool_discovery(self):
        self.responses = [reply(calls=[call('write_text', {'path': 'page.html', 'text': 'Hello'})]), reply('Done')]
        result = await run_agent({'taskCategory': 'website', 'conversation': [
            {'id': 'web', 'role': 'user', 'content': 'Create page.html'}]},
            'test', self.execute, DEF, self.directory, use_mcp=False)
        self.assertEqual(result.final_output, 'Done')
        self.assertIn('write_text', [t['function']['name'] for t in self.payloads[0]['tools']])
        self.assertEqual(len(self.executed), 1)

    async def test_sdk_multistep_dynamic_tools_and_error_recovery(self):
        self.responses=[reply(calls=[call('read_file',{'path':'missing'})]),
                        reply(calls=[call('list_files',{})]),reply(calls=[call('read_file',{'path':'inputs/brief.txt'})]),
                        reply(calls=[call('search_tools',{'query':'write_text'})]),
                        reply(calls=[call('write_text',{'path':'out.md','text':'海盐 73000'})]),reply('Done')]
        result=await self.run_turn([{'id':'u1','role':'user','content':'Find and summarize the brief'}])
        self.assertEqual(result.final_output,'Done')
        self.assertEqual(len(self.executed),4)
        self.assertNotIn('write_text',[t['function']['name'] for t in self.payloads[0]['tools']])
        self.assertIn('write_text',[t['function']['name'] for t in self.payloads[4]['tools']])
        self.assertIn('File not found',json.dumps(self.payloads[1]['messages']))
        native=self.payloads[-1]['messages']
        calls={c['id'] for m in native for c in m.get('tool_calls',[])}
        self.assertEqual(calls,{m['tool_call_id'] for m in native if m['role']=='tool'})
    async def test_reopen_replays_complete_tools_without_duplicate_input(self):
        first={'id':'u1','role':'user','content':'Find budget'}
        self.responses=[reply(calls=[call('read_file',{'path':'brief.txt'})]),reply('Budget is 73000')]
        await self.run_turn([first])
        self.responses=[reply('73000')]
        await self.run_turn([first,{'id':'a1','replyTo':'u1','role':'assistant','content':'Budget is 73000'},
                             {'id':'u2','role':'user','content':'What amount did the file say?'}])
        messages=self.payloads[-1]['messages']
        self.assertEqual(sum(m.get('content')=='Find budget' for m in messages),1)
        self.assertTrue(any(m['role']=='tool' and '73000' in m['content'] for m in messages))
        self.assertEqual(sum(m.get('content')=='What amount did the file say?' for m in messages),1)
    async def test_retry_does_not_repeat_completed_mutation(self):
        first={'id':'u1','role':'user','content':'Write the file'}
        sequence=[reply(calls=[call('search_tools',{'query':'write_text'})]),
                  reply(calls=[call('write_text',{'path':'out.md','text':'73000'})]),reply('Done')]
        self.responses=list(sequence)
        await self.run_turn([first])
        self.responses=list(sequence)
        await self.run_turn([first])
        self.assertEqual(len([x for x in self.executed if x[0]=='write_text']),1)
        trace=(self.directory/'trace.jsonl').read_text()
        self.assertNotIn('73000',trace)
        self.assertNotIn('Write the file',trace)
    async def test_conversation_has_web_without_file_discovery_round(self):
        state=LocalState(self.directory,self.events.append);self.addCleanup(state.db.close)
        definitions=DEF+[{'name':name,'description':name,'inputSchema':{'type':'object','properties':{}}} for name in ['search_web','read_webpage']]
        catalog=agent_loop.ToolCatalog(definitions,None,state,'conversation')
        self.assertEqual(catalog.loaded,{'search_web','read_webpage'})
        await catalog.search(None,'{"query":"read_file"}')
        self.assertIn('read_file',catalog.loaded)
    async def test_large_catalog_keeps_schema_surface_bounded(self):
        state=LocalState(self.directory,self.events.append);self.addCleanup(state.db.close)
        definitions=DEF+[{'name':f'calendar_lookup_{i}','description':f'Calendar operation {i}',
                         'inputSchema':{'type':'object','properties':{}}} for i in range(100)]
        catalog=agent_loop.ToolCatalog(definitions,None,state)
        await catalog.search(None,'{"query":"calendar"}')
        enabled=[tool for tool in catalog.tools if not callable(tool.is_enabled) or tool.is_enabled(None,None)]
        self.assertLessEqual(len(enabled),10)
        self.assertTrue(any(tool.name.startswith('calendar_lookup') for tool in enabled))
    async def test_deleted_answer_does_not_rehydrate_tools(self):
        first={'id':'u1','role':'user','content':'Find budget'}
        self.responses=[reply(calls=[call('read_file',{'path':'brief.txt'})]),reply('73000')]
        await self.run_turn([first])
        self.responses=[reply('New answer')]
        await self.run_turn([first,{'id':'u2','role':'user','content':'New request'}])
        self.assertFalse(any(m['role']=='tool' for m in self.payloads[-1]['messages']))
    async def test_unknown_tool_and_bad_json_recover_without_execution(self):
        self.responses=[reply(calls=[call('shell',{'cmd':'whoami'})]),
                        reply(calls=[call('read_file','{bad json')]),reply(calls=[call('read_file',{})]),reply('Blocked')]
        await self.run_turn([{'role':'user','content':'test'}])
        self.assertFalse(self.executed)
        self.assertIn('search_tools',json.dumps(self.payloads[1]))
        self.assertIn('required property',json.dumps(self.payloads[-1]))
    async def test_step_limit_remains_failure(self):
        from agents import MaxTurnsExceeded
        self.responses=[reply(calls=[call('list_files',{})])]*32
        with self.assertRaises(MaxTurnsExceeded):await self.run_turn([{'role':'user','content':'test'}])
        self.assertFalse(any(e.get('type')=='complete' for e in self.events))
        self.assertEqual(len(self.executed),2)
    async def test_compaction_preserves_intent_pairs_and_retrievable_original(self):
        state=LocalState(self.directory,self.events.append)
        self.addCleanup(state.db.close)
        model=OllamaModel(self.events.append,state)
        items=[{'role':'user','content':'项目海盐，预算73000，输出out.md，不发布。'}]
        for i in range(18):
            items += [{'role':'user','content':f'补充 {i}: '+'历史材料 '*160},
                      {'type':'function_call','name':'read_file','call_id':f'c{i}','arguments':'{"path":"brief.txt"}'},
                      {'type':'function_call_output','call_id':f'c{i}','output':'文件内容 '*180}]
        items += [{'role':'user','content':'继续完成当前任务，预算是什么？'}]
        self.responses=[]  # Context selection must never make hidden model calls.
        fitted=await state.fit(items,'test',[],model)
        self.assertLess(tokens(fitted),model.num_ctx-model.num_predict-1024)
        self.assertIn('73000',json.dumps(fitted,ensure_ascii=False))
        self.assertEqual(fitted[-1],items[-1])
        calls={i['call_id'] for i in fitted if i.get('type')=='function_call'}
        self.assertEqual(calls,{i['call_id'] for i in fitted if i.get('type')=='function_call_output'})
        self.assertTrue(state.recall(query='73000')['matches'])
        self.assertTrue(any(e.get('type')=='context_selected' for e in self.events))
        # Reopen the worker: local selection still makes no hidden model calls.
        restarted=LocalState(self.directory,self.events.append);self.addCleanup(restarted.db.close)
        self.responses=[]
        followup=items+[{'role':'assistant','content':'收到'},{'role':'user','content':'接着做'}]
        reused=await restarted.fit(followup,'test',[],OllamaModel(self.events.append,restarted))
        self.assertEqual(reused[-1],followup[-1])
        self.assertTrue(any(e.get('type')=='context_selected' for e in self.events))
    async def test_large_latest_request_is_not_cut_for_latency_target(self):
        state=LocalState(self.directory,self.events.append)
        self.addCleanup(state.db.close)
        model=OllamaModel(self.events.append,state)
        current={'role':'user','content':'Exact source: '+('abc def '*1800)}
        self.responses=[]
        fitted=await state.fit([current],'test',[],model)
        self.assertEqual(fitted[-1],current)
        self.assertFalse(self.payloads)

    async def test_sdk_mcp_real_workspace_transport(self):
        # No model server needed: actual SDK stdio discovery, read, error result, write.
        root=self.directory/'workspace';root.mkdir();(root/'brief.txt').write_text('Sea salt 73000')
        self.responses=[reply(calls=[call('read_file',{'path':'missing.txt'})]),
                        reply(calls=[call('list_files',{})]),reply(calls=[call('read_file',{'path':'brief.txt'})]),
                        reply(calls=[call('search_tools',{'query':'write_text'})]),
                        reply(calls=[call('write_text',{'path':'result.md','text':'Sea salt 73000'})]),reply('Done')]
        with patch.dict(os.environ,{'CHILLOR_WORKSPACE':str(root),'CHILLOR_TOOL_SCOPE':'all'}):
            await run_agent({'conversation':[{'id':'u1','role':'user','content':'Read and summarize'}]},'test',
                            self.execute,DEF,self.directory/'mcp-state',use_mcp=True)
        self.assertEqual((root/'result.md').read_text(),'Sea salt 73000')
        self.assertFalse(self.executed)

class TransportChecks(unittest.IsolatedAsyncioTestCase):
    async def test_native_context_options_stream_and_retry(self):
        import httpx2 as httpx
        received=[];events=[]
        def handle(request):
            received.append(json.loads(request.content))
            if len(received)==1:return httpx.Response(503)
            return httpx.Response(200,content=b'{"message":{"content":"ok"},"done":true,"eval_count":2}\n')
        client=httpx.AsyncClient
        with patch('ollama_model.httpx.AsyncClient',lambda **kw:client(transport=httpx.MockTransport(handle),**kw)):
            result=await OllamaModel(events.append).chat([{'role':'user','content':'test'}],visible=True)
        self.assertEqual(result[0],'ok')
        self.assertEqual(received[-1]['options']['num_ctx'],16384)
        self.assertTrue(received[-1]['stream']);self.assertFalse(received[-1]['think'])
        self.assertTrue(any(e['type']=='model_retry' for e in events))
    async def test_length_and_partial_disconnect_not_success(self):
        import httpx2 as httpx
        for body, expected in [(b'{"message":{"content":"partial"}}\n',httpx.ReadError),
                               (b'{"message":{"content":"partial"},"done":true,"done_reason":"length"}\n',RuntimeError)]:
            attempts=[];client=httpx.AsyncClient
            def handle(req):attempts.append(req);return httpx.Response(200,content=body)
            with patch('ollama_model.httpx.AsyncClient',lambda **kw:client(transport=httpx.MockTransport(handle),**kw)):
                with self.assertRaises(expected):await OllamaModel(lambda e:None).chat([],visible=True)
            self.assertEqual(len(attempts),1)

if __name__=='__main__':unittest.main()
