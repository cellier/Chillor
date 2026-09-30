import subprocess,tempfile,json,pathlib,os,sys
script=pathlib.Path(os.environ.get('CHILLOR_TEST_TOOL_SCRIPT','Resources/AgentTools/server.py')).resolve()
python=os.environ.get('CHILLOR_TEST_PYTHON',sys.executable)
with tempfile.TemporaryDirectory() as root:
 p=subprocess.Popen([python,str(script)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,env={**os.environ,'CHILLOR_WORKSPACE':root})
 seq=0
 def call(name,args):
  global seq
  seq+=1;p.stdin.write(json.dumps({'jsonrpc':'2.0','id':seq,'method':'tools/call','params':{'name':name,'arguments':args}})+'\n');p.stdin.flush();return json.loads(p.stdout.readline())['result']
 def ok(name,args):
  r=call(name,args);assert not r['isError'],r;return json.loads(r['content'][0]['text'])
 try:
  assert call('write_text',{'path':'../escape.txt','text':'bad'})['isError']
  pathlib.Path(root,'outside').symlink_to('/tmp',target_is_directory=True)
  assert call('write_text',{'path':'outside/chillor-escape.txt','text':'bad'})['isError']
  ok('write_text',{'path':'site/index.html','text':'<!doctype html><title>Bakery</title><h1>Bakery</h1>'})
  ok('write_text',{'path':'site/index.html','text':'<!doctype html><title>Bakery</title><h1>Fresh bread</h1>'})
  assert list(pathlib.Path(root,'.versions').iterdir())
  markdown='# PRD\n\n## Scope\n\n- **Master layout**\n- [ ] Review\n\n| Item | Status |\n| --- | --- |\n| Layout | Draft |\n\n```swift\nlet version = 1\n```\n'
  result=ok('write_text',{'path':'draft.md','text':markdown})
  assert result['path']=='draft.md' and result['sha256']
  assert pathlib.Path(root,'draft.md').read_text(encoding='utf-8')==markdown
  assert ok('read_file',{'path':'draft.md'})['text']==markdown
  revised=markdown+'\n## Acceptance\n\nPreserve the requested format.\n'
  ok('write_text',{'path':'draft.md','text':revised})
  assert ok('read_file',{'path':'draft.md'})['text']==revised
  assert any(f.name.endswith('-draft.md') and f.read_text(encoding='utf-8')==markdown for f in pathlib.Path(root,'.versions').iterdir())
  print('PASS: Markdown create, exact read-back, update and version backup')
  ok('create_document',{'path':'brief.docx','title':'项目简报','blocks':[{'heading':'目标','text':'原始文字'}]})
  ok('replace_document_text',{'path':'brief.docx','find':'原始文字','replace':'修改后文字'})
  assert '修改后文字' in ok('read_file',{'path':'brief.docx'})['text']
  ok('create_spreadsheet',{'path':'budget.xlsx','sheets':[{'name':'预算','rows':[['项目','金额'],['A',12],['合计','=SUM(B2:B2)']]}]})
  assert '=SUM(B2:B2)' in ok('read_file',{'path':'budget.xlsx'})['text']
  ok('edit_spreadsheet',{'path':'budget.xlsx','changes':[{'sheet':'预算','cell':'B2','value':24}]})
  assert '24' in ok('read_file',{'path':'budget.xlsx'})['text']
  ok('create_presentation',{'path':'plan.pptx','slides':[{'title':'计划','bullets':['第一阶段','第二阶段']}]})
  ok('replace_presentation_text',{'path':'plan.pptx','find':'第二阶段','replace':'第三阶段'})
  assert '第三阶段' in ok('read_file',{'path':'plan.pptx'})['text']
  print('PASS: path/symlink escape rejection, versioned website writes, Word create/modify/read, Excel formulas, editable PowerPoint')
 finally:p.terminate();p.wait(timeout=5)

# Preview serves only explicitly supported files under a private loopback URL.
import urllib.request,urllib.error
with tempfile.TemporaryDirectory() as root:
 pathlib.Path(root,'index.html').write_text('<h1>Local preview</h1>')
 pathlib.Path(root,'private.docx').write_text('not a web resource')
 pathlib.Path(root,'escape').symlink_to('/tmp',target_is_directory=True)
 p=subprocess.Popen([python,str(script),'--preview'],stdout=subprocess.PIPE,text=True,env={**os.environ,'CHILLOR_WORKSPACE':root})
 try:
  base=json.loads(p.stdout.readline())['url']
  with urllib.request.urlopen(base+'index.html',timeout=3) as response:
   assert b'Local preview' in response.read()
   assert "connect-src 'none'" in response.headers['Content-Security-Policy']
   assert "form-action 'none'" in response.headers['Content-Security-Policy']
  for suffix in ['../index.html','%2e%2e/index.html','private.docx','escape/secret.html']:
   try:urllib.request.urlopen(base+suffix,timeout=3);raise AssertionError(suffix)
   except urllib.error.HTTPError as error:assert error.code==404
  try:urllib.request.urlopen(base.rsplit('/',2)[0]+'/index.html',timeout=3);raise AssertionError('missing token')
  except urllib.error.HTTPError as error:assert error.code==404
  print('PASS: loopback preview, private URL, no Office exposure, traversal rejection, network/form restrictions')
 finally:p.terminate();p.wait(timeout=5)
