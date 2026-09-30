"""Deterministic loopback Ollama fixture: no real download or model is loaded."""
import json,time,threading
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
state={'mode':'ok','installed':False,'warmups':0,'pulls':0}
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def respond(self,value,status=200):
  self.send_response(status);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(json.dumps(value).encode())
 def do_GET(self):
  if self.path=='/api/tags':self.respond({'models':[{'name':'qwen3.5:4b'}] if state['installed'] else []})
  elif self.path=='/test/stats':self.respond(state)
  else:self.respond({})
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))) or '{}')
  if self.path=='/test/mode':state.update(body);self.respond({});return
  if self.path=='/api/pull':
   state['pulls']+=1
   if state['mode']=='failure':self.respond({'error':'test offline'},500);return
   self.send_response(200);self.send_header('Content-Type','application/x-ndjson');self.end_headers()
   try:
    for n in range(1,5):
     self.wfile.write((json.dumps({'status':'pulling','digest':'a','total':100,'completed':n*25})+'\n').encode());self.wfile.flush();time.sleep(.25 if state['mode']!='slow' else 2)
    state['installed']=True;self.wfile.write(b'{"status":"success"}\n')
   except (BrokenPipeError,ConnectionResetError):pass
  elif self.path=='/api/show':self.respond({'capabilities':['completion','vision','tools']})
  elif self.path=='/api/chat':self.respond({'done':True,'message':{'role':'assistant','content':'OK'}})
  elif self.path=='/api/generate':state['warmups']+=1;time.sleep(.3);self.respond({'done':True})
  else:self.respond({})
ThreadingHTTPServer(('127.0.0.1',11449),Handler).serve_forever()
