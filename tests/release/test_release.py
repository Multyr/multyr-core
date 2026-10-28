import importlib.util,json,pathlib,subprocess,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('release',ROOT/'script/release/release.py');r=importlib.util.module_from_spec(spec);spec.loader.exec_module(r)
class ReleaseTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();p=pathlib.Path(self.tmp.name);self.repo=p/'repo';self.repo.mkdir();self.remote=p/'remote.git'
  self.cmd('git','init','--bare',str(self.remote));self.cmd('git','init',str(self.repo));self.git('config','user.email','test@example.invalid');self.git('config','user.name','Test');(self.repo/'code').write_text('source');self.git('add','.');self.git('commit','-m','initial');self.git('remote','add','origin',str(self.remote));self.git('tag','-a','v1','-m','release');self.git('push','origin','HEAD','--tags')
 def tearDown(self):self.tmp.cleanup()
 def cmd(self,*a):return subprocess.check_output(a,stderr=subprocess.DEVNULL,text=True)
 def git(self,*a):return self.cmd('git','-C',str(self.repo),*a)
 def test_clean_pushed_tag(self):self.assertFalse(r.identity(self.repo,'v1')['dirty'])
 def test_modified_source_rejected(self):
  (self.repo/'code').write_text('changed')
  with self.assertRaises(ValueError):r.identity(self.repo,'v1')
 def test_untracked_source_rejected(self):
  (self.repo/'extra').write_text('new')
  with self.assertRaises(ValueError):r.identity(self.repo,'v1')
 def test_unpushed_tag_rejected(self):
  self.git('tag','v2')
  with self.assertRaises((ValueError,subprocess.CalledProcessError)):r.identity(self.repo,'v2')
 def test_tag_not_head_rejected(self):
  (self.repo/'code').write_text('changed');self.git('commit','-am','next')
  with self.assertRaises(ValueError):r.identity(self.repo,'v1')
 def test_record_cannot_be_overwritten(self):
  p=pathlib.Path(self.tmp.name)/'record.json';r.write_once(p,{'v':1})
  with self.assertRaises(FileExistsError):r.write_once(p,{'v':2})
  self.assertEqual(json.loads(p.read_text()),{'v':1})
 def test_every_deployment_entrypoint_has_guard(self):
  for p in list((ROOT/'script').glob('Deploy*.s.sol'))+list((ROOT/'script').glob('Redeploy*.s.sol')):self.assertIn('ReleaseGuard.check();',p.read_text(),str(p))
if __name__=='__main__':unittest.main()
