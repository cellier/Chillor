"""Native Ollama Model adapter. The Agents SDK, not this module, owns the agent loop."""
import asyncio
import json
import os
import time
import uuid

import httpx2 as httpx
from agents import Model, ModelResponse, Usage
from openai.types.responses import ResponseFunctionToolCall, ResponseOutputMessage, ResponseOutputText


def plain_content(content):
    if isinstance(content, str):
        return content
    return '\n'.join(p.get('text', '') for p in (content or []) if isinstance(p, dict))


def to_ollama(items, thinking=None):
    """Replay call IDs, arguments and outputs in order; never orphan tool results."""
    messages, names = [], {}
    for item in items:
        kind = item.get('type', 'message')
        if kind == 'function_call':
            call_id = item['call_id']
            names[call_id] = item['name']
            try:
                args = json.loads(item['arguments'])
            except (ValueError, TypeError):
                args = {}  # Historical invalid call; its error output follows.
            call = {'id': call_id, 'function': {'name': item['name'], 'arguments': args}}
            if messages and messages[-1]['role'] == 'assistant' and not messages[-1].get('_closed'):
                messages[-1].setdefault('tool_calls', []).append(call)
            else:
                messages.append({'role': 'assistant', 'content': '', 'tool_calls': [call]})
            if thinking and call_id in thinking:
                messages[-1]['thinking'] = thinking[call_id]
        elif kind == 'function_call_output':
            if item['call_id'] not in names:
                continue
            messages.append({'role': 'tool', 'tool_call_id': item['call_id'],
                             'tool_name': names[item['call_id']], 'content': plain_content(item['output'])})
        elif kind == 'message' and item.get('role'):
            message = {'role': 'system' if item['role'] == 'developer' else item['role'],
                       'content': plain_content(item.get('content'))}
            if isinstance(item.get('content'), list):
                images = [p['image_url'].split(',', 1)[1] for p in item['content']
                          if p.get('type') == 'input_image' and p.get('image_url', '').startswith('data:')]
                if images:
                    message['images'] = images
            messages.append(message)
    return messages


class OllamaModel(Model):
    def __init__(self, emit, context=None):
        self.emit, self.context = emit, context
        self.model = os.environ.get('CHILLOR_MODEL', os.environ.get('GOOSE_MODEL', 'qwen3.8:27b'))
        self.num_ctx = int(os.environ.get('CHILLOR_NUM_CTX', '16384'))
        self.num_predict = int(os.environ.get('CHILLOR_MAX_TOKENS', '4096'))
        if self.num_ctx < 8192 or self.num_predict > self.num_ctx // 2:
            raise ValueError('Invalid local context/output budget')
        self.round = 0
        self.thinking = {}

    async def chat(self, messages, tools=(), visible=False, think=False, max_tokens=None):
        mid = str(uuid.uuid4())
        body = {'model': self.model, 'messages': messages, 'stream': True, 'think': think,
                'keep_alive': os.environ.get('CHILLOR_KEEP_ALIVE', '10m'),
                'options': {'num_ctx': self.num_ctx, 'num_predict': max_tokens or self.num_predict, 'temperature': 0.2}}
        if tools:
            body['tools'] = list(tools)
        # Hard loopback endpoint, proxies disabled, no cloud client/fallback.
        for attempt in range(3):
            text, thoughts, calls, first = '', '', [], None
            started = time.monotonic()
            try:
                async with httpx.AsyncClient(trust_env=False, timeout=httpx.Timeout(300, connect=5)) as client:
                    async with client.stream('POST', 'http://127.0.0.1:11440/api/chat', json=body) as response:
                        response.raise_for_status()
                        async for line in response.aiter_lines():
                            if not line:
                                continue
                            if len(line) > 2_000_000:
                                raise RuntimeError('Model event exceeds size limit')
                            chunk = json.loads(line)
                            if chunk.get('error'):
                                raise RuntimeError(str(chunk['error']))
                            msg = chunk.get('message', {})
                            delta = msg.get('content', '')
                            text += delta
                            thoughts += msg.get('thinking', '')
                            calls.extend(msg.get('tool_calls', []))
                            if first is None and (delta or calls):
                                first = time.monotonic() - started
                            if visible and delta:
                                self.emit({'type': 'message', 'message': {'id': mid, 'role': 'assistant',
                                           'content': [{'type': 'text', 'text': delta}]}})
                            if chunk.get('done'):
                                if chunk.get('done_reason') == 'length':
                                    raise RuntimeError('Local model reached its response limit; task remains incomplete.')
                                self.emit({'type': 'performance', 'round': self.round, 'first_action_s': first,
                                           'total_s': time.monotonic()-started, 'load_s': chunk.get('load_duration', 0)/1e9,
                                           'prompt_s': chunk.get('prompt_eval_duration', 0)/1e9,
                                           'input_tokens': chunk.get('prompt_eval_count', 0),
                                           'cached_input_tokens': chunk.get('prompt_eval_cached_count'),
                                           'generation_s': chunk.get('eval_duration', 0)/1e9,
                                           'output_tokens': chunk.get('eval_count', 0), 'context_size': self.num_ctx,
                                           'purpose': 'agent' if visible else 'summary'})
                                return text, thoughts, calls, chunk
                        raise httpx.ReadError('Local model connection ended before completing the response')
            except (httpx.TransportError, httpx.HTTPStatusError) as error:
                retryable = not isinstance(error, httpx.HTTPStatusError) or error.response.status_code in (429, 500, 502, 503, 504)
                # Never replay a partly displayed response. No tool has been executed here.
                if attempt == 2 or not retryable or (visible and text):
                    raise
                self.emit({'type': 'model_retry', 'attempt': attempt + 1, 'reason': type(error).__name__})
                await asyncio.sleep(0.5 * 2**attempt)

    async def get_response(self, system_instructions, input, model_settings, tools, output_schema,
                           handoffs, tracing, **kwargs):
        items = [{'role': 'user', 'content': input}] if isinstance(input, str) else input
        schemas = [{'type': 'function', 'function': {'name': t.name, 'description': t.description,
                    'parameters': t.params_json_schema}} for t in tools]
        if self.context:
            items = await self.context.fit(items, system_instructions or '', schemas, self)
        messages = [{'role': 'system', 'content': system_instructions or ''}] + to_ollama(items, self.thinking)
        text, thoughts, calls, usage = await self.chat(messages, schemas, visible=True,
                          think=os.environ.get('CHILLOR_THINK', 'false') != 'false')
        self.round += 1
        output = []
        if text:
            output.append(ResponseOutputMessage(id='msg_'+uuid.uuid4().hex, role='assistant', status='completed',
                          content=[ResponseOutputText(type='output_text', text=text, annotations=[])], type='message'))
        available = {t.name for t in tools}
        for call in calls:
            f = call.get('function', {})
            name, args = f.get('name', ''), f.get('arguments', {})
            call_id = 'call_'+uuid.uuid4().hex
            if name not in available:
                args = {'requested_tool': name, 'error': 'Tool is not loaded or not available. Use search_tools to find an available tool.'}
                name = 'tool_error'
            output.append(ResponseFunctionToolCall(type='function_call', call_id=call_id, name=name,
                          arguments=args if isinstance(args, str) else json.dumps(args, ensure_ascii=False)))
            if thoughts:
                self.thinking[call_id] = thoughts
        if not output:
            raise RuntimeError('Local model returned an empty answer; task remains incomplete.')
        return ModelResponse(output=output, usage=Usage(requests=1, input_tokens=usage.get('prompt_eval_count', 0),
                             output_tokens=usage.get('eval_count', 0),
                             total_tokens=usage.get('prompt_eval_count', 0)+usage.get('eval_count', 0)), response_id=None)

    async def stream_response(self, *args, **kwargs):
        # Runner.run uses get_response; native deltas above drive the existing Swift UI.
        raise NotImplementedError('Use Runner.run with the native UI event adapter')
        yield
