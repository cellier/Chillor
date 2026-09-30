import sys,socket,unittest,threading
from unittest.mock import patch
sys.path.insert(0,'Resources/AgentTools')
# Match the production worker: bundled Python uses wheels for its own ABI.
if sys.version_info < (3,10):sys.path.insert(0,'Resources/AgentTools/packages')
import web_tools as web

class WebChecks(unittest.TestCase):
 def test_private_targets(self):
  for url in ['file:///etc/passwd','http://localhost/','http://user:secret@example.com','http://127.0.0.1:9000/','http://printer.local/']:
   with self.subTest(url=url),self.assertRaises(ValueError):web.public_target(url)
  for address in ['127.0.0.1','10.0.0.1','169.254.169.254','::1','fc00::1','192.168.1.1']:
   with patch('socket.getaddrinfo',return_value=[(socket.AF_INET,socket.SOCK_STREAM,6,'',(address,443))]),self.assertRaises(ValueError):web.public_target('https://example.com/')
 def test_parse_search(self):
  data=b'<html><li class="b_algo"><h2><a href="https://example.com/source">Current forecast</a></h2><p>Read this source.</p></li></html>'
  with patch.object(web,'fetch',return_value=('https://www.bing.com/search',data,'text/html')):
   result=web.search_web('forecast');self.assertEqual(result['results'][0]['url'],'https://example.com/source');self.assertIn('retrieved_at',result)
 def test_content_is_not_executed(self):
  data=b'<html><title>Source</title><script>EVIL_SCRIPT</script><main>Actual text <a href="/next">Next page</a></main></html>'
  with patch.object(web,'fetch',return_value=('https://example.com/page',data,'text/html; charset=utf-8')):
   result=web.read_page('https://example.com/page');self.assertNotIn('EVIL_SCRIPT',result['text']);self.assertIn('Actual text',result['text']);self.assertEqual(result['links'][0]['url'],'https://example.com/next')
 def test_failure_is_explicit(self):
  with patch.object(web,'fetch',side_effect=ValueError('blocked')),self.assertRaisesRegex(ValueError,'unavailable'):web.search_web('test')
 def test_query_limits(self):
  for q in ['', 'x'*401]:
   with self.assertRaises(ValueError):web.search_web(q)
 def test_search_sources_overlap(self):
  barrier=threading.Barrier(2,timeout=2)
  def source(provider):
   barrier.wait()
   return {'provider':provider,'results':[{'title':provider,'url':'https://example.com/'+provider}]}
  with patch.object(web,'search_sogou',side_effect=lambda q:source('Sogou')),patch.object(web,'search_bing',side_effect=lambda q:source('Bing')):
   result=web.search_web('test')
  self.assertEqual([r['title'] for r in result['results']],['Sogou','Bing'])
 def test_one_source_failure_keeps_other(self):
  with patch.object(web,'search_sogou',side_effect=ValueError('blocked')),patch.object(web,'search_bing',return_value={'provider':'Bing','results':[{'title':'ok','url':'https://example.com'}]}):
   result=web.search_web('test')
  self.assertEqual(result['provider'],'Bing');self.assertEqual(len(result['results']),1)

if __name__ == '__main__':unittest.main()
