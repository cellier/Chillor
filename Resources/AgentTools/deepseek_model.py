"""DeepSeek Model adapter for the Agents SDK. Used only when the user selects it.

Mirrors ollama_model.OllamaModel: the SDK owns the agent loop, this module owns
one request. Reasoning is disabled so the output budget buys visible answer
tokens, and reasoning text is never surfaced, traced or stored.
"""
import asyncio
import json
import os
import time
import uuid

import httpx2 as httpx
from agents import Model, ModelResponse, Usage
from openai.types.responses import ResponseFunctionToolCall, ResponseOutputMessage, ResponseOutputText

# Image input is model-dependent; sending parts a model cannot read invites
# invented descriptions. Workspace text and OCR excerpts are unaffected.
VISION_MODELS = {'deepseek-flash'}


def plain_content(content):
    if isinstance(content, str):
        return content
    # Image parts carry no text; joining their empty strings would append stray
    # newlines to every multimodal message.
    return '\n'.join(p['text'] for p in (content or [])
                     if isinstance(p, dict) and p.get('text'))


def to_openai(items, model):
    """Replay call IDs, arguments and outputs in order; never orphan tool results."""
    messages, names, dropped = [], {}, False
    for item in items:
        kind = item.get('type', 'message')
        if kind == 'function_call':
            call_id = item['call_id']
            names[call_id] = item['name']
            arguments = item['arguments']
            if not isinstance(arguments, str):
                arguments = json.dumps(arguments, ensure_ascii=False)
            call = {'id': call_id, 'type': 'function',
                    'function': {'name': item['name'], 'arguments': arguments}}
            if messages and messages[-1]['role'] == 'assistant' and 'tool_calls' in messages[-1]:
                messages[-1]['tool_calls'].append(call)
            else:
                messages.append({'role': 'assistant', 'content': '', 'tool_calls': [call]})
        elif kind == 'function_call_output':
            # An orphaned tool result is rejected by the API; drop it like the local adapter.
            if item['call_id'] not in names:
                continue
            messages.append({'role': 'tool', 'tool_call_id': item['call_id'],
                             'content': plain_content(item['output'])})
        elif kind == 'message' and item.get('role'):
            role = 'system' if item['role'] == 'developer' else item['role']
            text = plain_content(item.get('content'))
            images = []
            if isinstance(item.get('content'), list):
                images = [p['image_url'] for p in item['content']
                          if p.get('type') == 'input_image' and str(p.get('image_url', '')).startswith('data:')]
            if images and model not in VISION_MODELS:
                dropped = True
                images = []
            if images and role == 'user':
                parts = ([{'type': 'text', 'text': text}] if text else []) + [
                    {'type': 'image_url', 'image_url': {'url': url}} for url in images[:4]]
                messages.append({'role': role, 'content': parts})
            else:
                messages.append({'role': role, 'content': text})
    if dropped:
        messages.insert(0, {'role': 'system', 'content':
            'An image was attached but this model cannot read images. Use only the supplied text. '
            'Do not describe or guess image contents; say the image could not be read if it matters.'})
    return messages


class DeepSeekModel(Model):
    def __init__(self, emit, context=None):
        self.emit, self.context = emit, context
        self.model = os.environ.get('CHILLOR_MODEL', 'deepseek-flash')
        self.base = os.environ.get('CHILLOR_API_BASE', 'https://api.deepseek.com').rstrip('/')
        self.key = os.environ.get('CHILLOR_API_KEY', '')
        if not self.key:
            raise ValueError('No DeepSeek API key was supplied to the work runtime.')
        self.num_ctx = int(os.environ.get('CHILLOR_NUM_CTX', '65536'))
        self.num_predict = int(os.environ.get('CHILLOR_MAX_TOKENS', '8192'))
        if self.num_ctx < 8192 or self.num_predict > self.num_ctx // 2:
            raise ValueError('Invalid remote context/output budget')
        self.round = 0
        self.thinking = {}

    @staticmethod
    def merge_tool_calls(pending, deltas):
        for delta in deltas:
            slot = pending.setdefault(delta.get('index', 0), {'id': '', 'name': '', 'arguments': ''})
            if delta.get('id'):
                slot['id'] = delta['id']
            function = delta.get('function') or {}
            if function.get('name'):
                slot['name'] = function['name']
            if function.get('arguments'):
                slot['arguments'] += function['arguments']
        return pending

    async def chat(self, messages, tools=(), visible=False, max_tokens=None):
        mid = str(uuid.uuid4())
        body = {'model': self.model, 'messages': messages, 'stream': True,
                'stream_options': {'include_usage': True},
                'reasoning_effort': 'none',
                'max_tokens': max_tokens or self.num_predict, 'temperature': 0.2}
        if tools:
            body['tools'] = list(tools)
        headers = {'Authorization': 'Bearer '+self.key, 'Content-Type': 'application/json',
                   'Accept': 'text/event-stream'}
        for attempt in range(3):
            text, pending, usage, finish = '', {}, {}, None
            started = time.monotonic()
            first = None
            try:
                # trust_env is on: a user behind a system proxy must still reach the API.
                async with httpx.AsyncClient(timeout=httpx.Timeout(300, connect=15)) as client:
                    async with client.stream('POST', self.base+'/chat/completions', json=body, headers=headers) as response:
                        if response.status_code != 200:
                            detail = (await response.aread())[:800].decode('utf-8', 'replace')
                            raise httpx.HTTPStatusError(self.describe(response.status_code, detail),
                                                        request=response.request, response=response)
                        async for line in response.aiter_lines():
                            if not line or not line.startswith('data:'):
                                continue
                            payload = line[5:].strip()
                            if payload == '[DONE]':
                                break
                            if len(payload) > 2_000_000:
                                raise RuntimeError('Model event exceeds size limit')
                            chunk = json.loads(payload)
                            if chunk.get('error'):
                                raise RuntimeError(str(chunk['error'].get('message', chunk['error'])))
                            if chunk.get('usage'):
                                usage = chunk['usage']
                            choices = chunk.get('choices') or []
                            if not choices:
                                continue
                            choice = choices[0]
                            delta = choice.get('delta') or {}
                            # reasoning_content is deliberately ignored: not shown, not traced.
                            content = delta.get('content') or ''
                            if content:
                                text += content
                                if first is None:
                                    first = time.monotonic()-started
                                if visible:
                                    self.emit({'type': 'message', 'message': {'id': mid, 'role': 'assistant',
                                               'content': [{'type': 'text', 'text': content}]}})
                            if delta.get('tool_calls'):
                                self.merge_tool_calls(pending, delta['tool_calls'])
                                if first is None:
                                    first = time.monotonic()-started
                            if choice.get('finish_reason'):
                                finish = choice['finish_reason']
                if finish == 'length' and not text and not pending:
                    raise RuntimeError('DeepSeek reached its output limit before producing a reply; task remains incomplete.')
                if finish is None and not text and not pending:
                    raise httpx.ReadError('The DeepSeek connection ended before completing the response')
                self.emit({'type': 'performance', 'round': self.round, 'first_action_s': first,
                           'total_s': time.monotonic()-started, 'load_s': 0, 'prompt_s': 0,
                           'input_tokens': usage.get('prompt_tokens', 0),
                           'cached_input_tokens': (usage.get('prompt_tokens_details') or {}).get('cached_tokens'),
                           'generation_s': 0, 'output_tokens': usage.get('completion_tokens', 0),
                           'context_size': self.num_ctx, 'provider': 'deepseek',
                           'purpose': 'agent' if visible else 'summary'})
                calls = [pending[index] for index in sorted(pending)]
                return text, calls, usage
            except (httpx.TransportError, httpx.HTTPStatusError) as error:
                retryable = not isinstance(error, httpx.HTTPStatusError) or error.response.status_code in (429, 500, 502, 503, 504)
                # Never replay a partly displayed response. No tool has run here.
                if attempt == 2 or not retryable or (visible and text):
                    raise
                self.emit({'type': 'model_retry', 'attempt': attempt+1, 'reason': type(error).__name__})
                await asyncio.sleep(0.5 * 2**attempt)

    @staticmethod
    def describe(status, detail):
        try:
            message = json.loads(detail)['error']['message']
        except Exception:
            message = ''
        if status == 401:
            return 'DeepSeek rejected this API key. Check it in Settings.'
        if status == 402:
            return 'This DeepSeek account has no balance left. Top it up, or switch back to the local model.'
        if status == 429:
            return 'DeepSeek is rate limiting this key. Wait a moment and retry.'
        return message or ('DeepSeek could not complete this request (HTTP '+str(status)+')')

    async def get_response(self, system_instructions, input, model_settings, tools, output_schema,
                           handoffs, tracing, **kwargs):
        items = [{'role': 'user', 'content': input}] if isinstance(input, str) else input
        schemas = [{'type': 'function', 'function': {'name': t.name, 'description': t.description,
                    'parameters': t.params_json_schema}} for t in tools]
        if self.context:
            items = await self.context.fit(items, system_instructions or '', schemas, self)
        messages = [{'role': 'system', 'content': system_instructions or ''}] + to_openai(items, self.model)
        text, calls, usage = await self.chat(messages, schemas, visible=True)
        self.round += 1
        output = []
        if text:
            output.append(ResponseOutputMessage(id='msg_'+uuid.uuid4().hex, role='assistant', status='completed',
                          content=[ResponseOutputText(type='output_text', text=text, annotations=[])], type='message'))
        available = {t.name for t in tools}
        for call in calls:
            name, arguments = call['name'], call['arguments'] or '{}'
            call_id = call['id'] or 'call_'+uuid.uuid4().hex
            if name not in available:
                arguments = json.dumps({'requested_tool': name,
                    'error': 'Tool is not loaded or not available. Use search_tools to find an available tool.'})
                name = 'tool_error'
            output.append(ResponseFunctionToolCall(type='function_call', call_id=call_id, name=name,
                                                  arguments=arguments))
        if not output:
            raise RuntimeError('DeepSeek returned an empty answer; task remains incomplete.')
        return ModelResponse(output=output, usage=Usage(requests=1,
                             input_tokens=usage.get('prompt_tokens', 0),
                             output_tokens=usage.get('completion_tokens', 0),
                             total_tokens=usage.get('total_tokens', 0)), response_id=None)

    async def stream_response(self, *args, **kwargs):
        # Runner.run uses get_response; native deltas above drive the existing Swift UI.
        raise NotImplementedError('Use Runner.run with the native UI event adapter')
        yield
