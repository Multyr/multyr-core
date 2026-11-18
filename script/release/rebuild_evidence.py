#!/usr/bin/env python3
"""Rebuild main source with recorded compiler settings, including metadata remappings."""
import argparse,hashlib,json,pathlib,subprocess
p=argparse.ArgumentParser();p.add_argument('--source-root',required=True);p.add_argument('--metadata',required=True);p.add_argument('--solc',required=True);p.add_argument('--out',required=True);a=p.parse_args()
root=pathlib.Path(a.source_root);recipes=json.load(open(a.metadata));groups={}
for name,r in recipes.items():
 settings=dict(r['settings']);target=settings.pop('compilationTarget');key=json.dumps(settings,sort_keys=True)
 g=groups.setdefault(key,{'settings':settings,'sources':{},'targets':{}});g['targets'].update(target)
 for path,record in r['sources'].items():g['sources'][path]={'content':(root/path).read_text()}
out=pathlib.Path(a.out);out.mkdir(parents=True,exist_ok=True)
for idx,g in enumerate(groups.values()):
 settings=g['settings'];settings['outputSelection']={'*':{'*':['abi','metadata','evm.bytecode','evm.deployedBytecode']}}
 payload={'language':'Solidity','sources':g['sources'],'settings':settings}
 res=subprocess.run([a.solc,'--standard-json'],input=json.dumps(payload),text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True);d=json.loads(res.stdout)
 errors=[x for x in d.get('errors',[]) if x['severity']=='error']
 if errors:raise RuntimeError(str(errors))
 for path,name in g['targets'].items():
  c=d['contracts'][path][name];m=json.loads(c['metadata']);record=recipes[name]
  normalized=json.loads(json.dumps(m['settings']))
  # Foundry's parsed metadata omits the empty-context ':' in remappings;
  # raw solc metadata includes it. This is serialization, not bytecode masking.
  normalized['remappings']=[x.removeprefix(':') for x in normalized['remappings']]
  if m['compiler']!=record['compiler'] or m['sources']!=record['sources'] or normalized!=record['settings']:raise RuntimeError('Compiler metadata differs: '+name)
  dest=out/pathlib.Path(path).name;dest.mkdir(exist_ok=True)
  (dest/(name+'.json')).write_text(json.dumps({'abi':c['abi'],'bytecode':c['evm']['bytecode'],'deployedBytecode':c['evm']['deployedBytecode'],'metadata':m}))
 print('Rebuilt',len(g['targets']),'contracts with exact metadata/source hashes',flush=True)
