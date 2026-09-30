"""Source, revision, deletion, scope and long-context regressions; no model required."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'Resources/AgentTools'))
from personal_memory import PersonalMemory
from agent_context import LocalState, tokens
from context_builder import ContextBuilder
from ollama_model import OllamaModel
from agent_loop import run_agent


class MemoryChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)/'personal.sqlite'
        self.memory = PersonalMemory(self.path, 'task-a', 'u1');self.addCleanup(self.memory.db.close)
        self.sources = []

    def source(self, mid, text, role='user'):
        source = {'id': mid, 'role': role, 'text': text, 'taskID': 'task-a'}
        self.sources.append(source);self.memory.current_id = mid
        self.memory.sync(self.sources, authoritative=True)
        return source

    def test_cross_task_reopen_and_provenance(self):
        self.source('u1', '请记住：海盐项目的预算是73000元。')
        saved = self.memory.remember('budget', '73000元', self.sources[-1]['text'], 'project:海盐')
        reopened = PersonalMemory(self.path, 'task-b', 'u2');self.addCleanup(reopened.db.close)
        matches = reopened.context('海盐预算是多少')
        self.assertEqual(matches[0]['value'], '73000元')
        self.assertEqual(matches[0]['source_id'], 'u1')
        self.assertEqual(matches[0]['id'], saved['id'])
        self.assertFalse(reopened.context('如何煮鸡蛋'))

    def test_correction_supersedes_old_value(self):
        self.source('u1', '海盐预算73000元。')
        old = self.memory.remember('budget', '73000元', self.sources[-1]['text'], 'project:海盐')
        self.source('u2', '更正：海盐预算现在改为94860元。')
        new = self.memory.remember('budget', '94860元', self.sources[-1]['text'], 'project:海盐')
        self.assertEqual(new['replaces'], old['id'])
        self.assertEqual([r['value'] for r in self.memory.search('海盐预算')], ['94860元'])
        self.assertFalse(self.memory.search('73000'))

    def test_forget_erases_all_revisions_and_prevents_relearning(self):
        self.test_correction_supersedes_old_value()
        current = self.memory.search('海盐')[0]
        self.memory.forget([current['id']])
        self.assertFalse(self.memory.search())
        self.assertEqual(self.memory.db.execute('SELECT count(*) FROM memory_search').fetchone()[0], 0)
        self.assertFalse(any(row[0] for row in self.memory.db.execute('SELECT value FROM memories')))
        reopened = PersonalMemory(self.path, 'task-c', 'u3');self.addCleanup(reopened.db.close)
        reopened.sync(self.sources, authoritative=True)
        self.assertFalse(reopened.context('海盐预算'))
        self.assertNotIn('94860', reopened.redact('旧回答：94860元'))
        self.assertNotIn('73000', reopened.redact('旧回答：73000元'))
        self.assertFalse(reopened.filter_history([{'id':'u1','role':'user','content':'海盐预算73000元。'},
                                                {'id':'a1','replyTo':'u1','role':'assistant','content':'73000元'}]))

    def test_deletion_never_restores_superseded_value(self):
        self.test_correction_supersedes_old_value()
        self.memory.sync(self.sources[:1], authoritative=True)
        self.assertFalse(self.memory.search('预算'))

    def test_reject_assistant_tool_inference_and_old_sources(self):
        self.source('a1', '你喜欢红色', 'assistant')
        with self.assertRaises(ValueError):self.memory.remember('color','红色','你喜欢红色')
        self.source('u1', '我喜欢蓝色。')
        with self.assertRaises(ValueError):self.memory.remember('color','红色','我喜欢蓝色。')
        self.source('u2', '请继续')
        with self.assertRaises(ValueError):self.memory.remember('color','蓝色','我喜欢蓝色。',source_id='u1')
        self.assertFalse(self.memory.search())

    def test_preferences_are_fast_and_corrections_take_effect(self):
        self.source('u1', '以后用中文回答，回复简短。')
        self.assertEqual(len(self.memory.capture_explicit_preferences()), 2)
        self.source('u2', '以后回复详细一点。')
        self.memory.capture_explicit_preferences()
        values = {r['key']: r['value'] for r in self.memory.context('介绍一下月亮')}
        self.assertEqual(values, {'response_language':'中文', 'response_length':'详细'})

    def test_forgetting_one_preference_preserves_other_from_same_message(self):
        self.source('u1', '以后用中文回答，回复简短。')
        self.memory.capture_explicit_preferences()
        length = next(r for r in self.memory.search() if r['key']=='response_length')
        self.memory.forget([length['id']])
        self.memory.sync(self.sources, authoritative=True)
        self.assertEqual([(r['key'],r['value']) for r in self.memory.search()], [('response_language','中文')])
        self.assertNotIn('简短', str(self.memory.context('回复')))
        self.assertFalse(self.memory.capture_explicit_preferences())
        self.memory.forget([self.memory.search()[0]['id']])
        reopened = PersonalMemory(self.path);self.addCleanup(reopened.db.close)
        reopened.sync(self.sources, authoritative=True)
        self.assertNotIn('中文', reopened.redact('偏好：中文'))
        self.assertFalse(reopened.search())

    def test_quotes_questions_and_attachments_do_not_auto_create_memory(self):
        for i, text in enumerate(['他问：“以后用中文回答？”', '翻译这句："以后用中文回答"', '以后用中文回答好吗？']):
            self.source(str(i), text)
            self.assertFalse(self.memory.capture_explicit_preferences())
        self.assertFalse(self.memory.search())

    def test_task_scope_and_sql_search_input(self):
        self.source('u1', '预算73000元。')
        self.memory.remember('budget','73000元','预算73000元。','task:task-a')
        self.memory.task_id = 'task-b'
        self.assertFalse(self.memory.context('预算73000'))
        self.assertFalse(self.memory.search('预算73000'))
        self.memory.search('" OR * DROP TABLE memories; 海盐')
        self.assertEqual(self.memory.db.execute('SELECT count(*) FROM memories').fetchone()[0], 1)

    def test_legacy_user_source_recall_and_deletion(self):
        self.source('old', '我喜欢茶色封面。')
        self.source('new', '我喜欢什么颜色的封面？')
        self.assertIn('茶色', str(self.memory.search_sources('封面')))
        self.memory.sync(self.sources[1:], authoritative=True)
        self.assertFalse(self.memory.search_sources('封面'))


class ContextChecks(unittest.IsolatedAsyncioTestCase):
    async def test_memory_prefix_is_stable_during_tool_execution(self):
        with tempfile.TemporaryDirectory() as root:
            state = LocalState(root, lambda _:None);self.addCleanup(state.db.close)
            memory = PersonalMemory(Path(root)/'memory.sqlite', 't', 'u');self.addCleanup(memory.db.close)
            memory.sync([{'id':'u','role':'user','content':'请记住：我的代号是松鹤。'}])
            state.personal_memory = memory
            model = OllamaModel(lambda _:None,state)
            items = [{'role':'user','content':'请记住：我的代号是松鹤。'}]
            await state.fit(items,'',[],model)
            memory.remember('codename','松鹤','我的代号是松鹤。')
            view = await state.fit(items,'',[],model)
            self.assertEqual(view,items)  # Success is delivered by the tool, not a rewritten prefix.
            state.memory_snapshot = None
            view = await state.fit(items,'',[],model)
            self.assertIn('<personal_memory',view[0]['content'])

    async def test_role_metadata_does_not_retrieve_unrelated_personal_facts(self):
        with tempfile.TemporaryDirectory() as root:
            state = LocalState(root, lambda _:None);self.addCleanup(state.db.close)
            memory = PersonalMemory(Path(root)/'memory.sqlite', 'new', 'u1');self.addCleanup(memory.db.close)
            memory.sync([{'id':'u1','role':'user','content':'我的代号是松鹤。'}])
            memory.remember('user_codename','松鹤','我的代号是松鹤。')
            state.personal_memory = memory
            view = await state.fit([{'role':'user','content':'请解释月亮的圆缺。'}], '', [], OllamaModel(lambda _:None,state))
            self.assertNotIn('松鹤', json.dumps(view,ensure_ascii=False))

    async def test_middle_correction_and_current_request_survive_long_context(self):
        with tempfile.TemporaryDirectory() as root:
            events = [];state = LocalState(root, events.append)
            self.addCleanup(state.db.close)
            items = [{'role':'user','content':'当前任务：蓝鹭采购方案，预算84270元，负责人周遥，交付proposal.md，仅本地草稿，不发布。'}]
            for i in range(40):
                items += [{'role':'assistant','content':'收到。'+('背景材料 '*200)},
                          {'role':'user','content':('更正：预算改为94860元。' if i == 3 else '')+f'材料{i}：'+('背景说明 '*120)}]
            items += [{'role':'user','content':'接着做。最终预算、负责人、交付文件和发布限制是什么？'}]
            with patch.object(OllamaModel, 'chat', side_effect=AssertionError('Hidden model call')):
                view = await state.fit(items, 'system', [], OllamaModel(events.append, state))
            text = json.dumps(view, ensure_ascii=False)
            for term in ['蓝鹭','94860','周遥','proposal.md','不发布']:
                self.assertIn(term, text)
            self.assertEqual(view[-1], items[-1])
            self.assertLess(tokens(view), 5000)
            self.assertGreater(events[-1]['items_omitted'], 50)

    async def test_large_active_tool_batch_preserves_request_and_pairs(self):
        with tempfile.TemporaryDirectory() as root:
            state = LocalState(root, lambda _:None);self.addCleanup(state.db.close)
            items = [{'role':'user','content':'读取并比较这两份文件，保留全部约束。'}]
            for i in range(2):
                items.extend([{'type':'function_call','name':'read_file','call_id':str(i),'arguments':'{}'},
                              {'type':'function_call_output','call_id':str(i),'output':'word '*1600}])
            view = await state.fit(items, '', [], OllamaModel(lambda _:None, state))
            self.assertEqual(view[0], items[0])
            self.assertEqual({i['call_id'] for i in view if i.get('type')=='function_call'},
                             {i['call_id'] for i in view if i.get('type')=='function_call_output'})


if __name__ == '__main__':
    unittest.main()
