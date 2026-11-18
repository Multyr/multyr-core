#!/usr/bin/env python3
"""Fail-closed release entry point. No secrets are serialized."""
import argparse, datetime, hashlib, json, os, pathlib, re, shutil, subprocess, sys, tempfile, uuid
ROOT=pathlib.Path(__file__).resolve().parents[2]

def git(repo,*args):
    return subprocess.check_output(['git','-C',str(repo),*args],text=True,stderr=subprocess.PIPE).strip()
def identity(repo,tag):
    repo=pathlib.Path(repo).resolve()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/-]*',tag):raise ValueError('Invalid release tag')
    head=git(repo,'rev-parse','HEAD')
    if git(repo,'status','--porcelain','--untracked-files=all','--ignore-submodules=none'):raise ValueError('Dirty repository: '+repo.name)
    subs=git(repo,'submodule','status','--recursive')
    if any(line.startswith(('-', '+', 'U')) for line in subs.splitlines()):raise ValueError('Uninitialized/mismatched submodule')
    if git(repo,'rev-parse',f'refs/tags/{tag}^{{commit}}')!=head:raise ValueError('Tag does not identify HEAD')
    local=git(repo,'rev-parse',f'refs/tags/{tag}')
    remote=git(repo,'ls-remote','--exit-code','origin',f'refs/tags/{tag}').split()
    if not remote or remote[0]!=local:raise ValueError('Release tag not pushed to origin')
    return {'commit':head,'tag':tag,'tagObject':local,'dirty':False,'submodules':subs.splitlines()}
def attest():
    c=identity(ROOT,os.environ['RELEASE_CORE_TAG']);s=identity(os.environ['RELEASE_STRATEGY_REPO'],os.environ['RELEASE_STRATEGY_TAG'])
    if c['commit']!=os.environ['RELEASE_CORE_COMMIT'] or s['commit']!=os.environ['RELEASE_STRATEGY_COMMIT']:raise ValueError('Release revisions changed')
    release_id=os.environ['RELEASE_ID']
    if not re.fullmatch(r'[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}',release_id):raise ValueError('Invalid release ID')
    directory=ROOT/'broadcast'/'releases'/release_id
    preflight=json.loads((directory/'preflight.json').read_text())
    if preflight['core']!=c or preflight['strategy']!=s:raise ValueError('Preflight identity changed')
    if pathlib.Path(os.environ['OUTPUT_JSON']).resolve()!=directory/'addresses.json':raise ValueError('Output outside release directory')
    if pathlib.Path(os.environ['FOUNDRY_BROADCAST']).resolve()!=directory/'transactions':raise ValueError('Broadcast outside release directory')
    return c,s

def write_once(path,payload):
    with pathlib.Path(path).open('x') as f:json.dump(payload,f,indent=2);f.write('\n')
def run(a):
    strategy=pathlib.Path(a.strategy_repo).resolve();core=identity(ROOT,a.core_tag);other=identity(strategy,a.strategy_tag)
    script=(ROOT/a.script).resolve()
    if script.parent!=ROOT/'script' or not script.name.endswith('.s.sol') or not script.name.startswith(('Deploy','Redeploy')):raise ValueError('Only checked deployment entry points are supported')
    previous=json.loads(pathlib.Path(a.addresses).read_text())
    release_id=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:12]
    output=ROOT/'broadcast'/'releases'/release_id;output.mkdir(parents=True,exist_ok=False)
    e=dict(os.environ);e.update(RELEASE_CORE_TAG=a.core_tag,RELEASE_CORE_COMMIT=core['commit'],RELEASE_STRATEGY_REPO=str(strategy),RELEASE_STRATEGY_TAG=a.strategy_tag,RELEASE_STRATEGY_COMMIT=other['commit'],RELEASE_ID=release_id,OUTPUT_JSON=str(output/'addresses.json'),CLAIM_OUTPUT_JSON=str(output/'addresses.json'),FOUNDRY_BROADCAST=str(output/'transactions'))
    config=json.loads(subprocess.check_output(['forge','config','--json'],cwd=ROOT,env=e,text=True))
    compiler={k:config.get(k) for k in ('solc','optimizer','optimizer_runs','via_ir','evm_version','bytecode_hash','cbor_metadata','remappings')}
    manifest={'compilerSettings':compiler,'foundryVersion':subprocess.check_output(['forge','--version'],text=True).strip(),'schemaVersion':1,'releaseId':release_id,'core':core,'strategy':other,'script':a.script,'priorAddresses':previous,'mode':'broadcast' if a.broadcast else 'simulation','status':'PREPARED'}
    write_once(output/'preflight.json',manifest)
    # The script re-attests immediately before startBroadcast via FFI.
    args=['forge','script',str(script.relative_to(ROOT)),'--ffi','--rpc-url',e['RPC_URL'],'--slow']
    if a.broadcast:args.append('--broadcast')
    result=subprocess.run(args,cwd=ROOT,env=e,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    log=result.stdout
    for key,value in e.items():
        if value and (key.endswith(('PRIVATE_KEY','TOKEN','SECRET')) or key=='RPC_URL'):log=log.replace(value,'[REDACTED]')
    (output/'execution.log').write_text(log)
    # Archive run-latest once; authoritative copies never use a mutable filename.
    receipts=[]; transactions=[]
    for f in (output/'transactions').rglob('run-latest.json'):
        d=json.loads(f.read_text());receipts.extend(d.get('receipts',[]));transactions.extend(d.get('transactions',[]))
        shutil.copyfile(f,output/('receipts-'+hashlib.sha256(str(f.relative_to(output)).encode()).hexdigest()[:12]+'.json'))
    address_file=output/'addresses.json'
    manifest['createdContracts']=[{'name':t.get('contractName'),'address':t.get('contractAddress'),'transactionHash':t.get('hash')} for t in transactions if t.get('transactionType') in ('CREATE','CREATE2')]
    manifest.update(exitCode=result.returncode,addresses=json.loads(address_file.read_text()) if address_file.exists() else {},receiptCount=len(receipts),status='SIMULATED' if result.returncode==0 and not a.broadcast else 'INCOMPLETE')
    if a.broadcast and result.returncode==0 and receipts and len(receipts)==len(transactions) and all(int(str(r.get('status','0')),0)==1 for r in receipts):manifest['status']='RECEIPTS_CAPTURED_REVIEW_REQUIRED'
    manifest['filesSha256']={str(f.relative_to(output)):hashlib.sha256(f.read_bytes()).hexdigest() for f in output.glob('*') if f.is_file()}
    write_once(output/'manifest.json',manifest)
    # Identical release identity and address manifest in both repositories; exclusive creation.
    for repo in (ROOT,strategy):
        dest=repo/'deployments'/'releases'/release_id;dest.mkdir(parents=True,exist_ok=False)
        for f in output.glob('*'):
            if f.is_file():shutil.copyfile(f,dest/f.name)
    print(json.dumps({'releaseId':release_id,'status':manifest['status'],'exitCode':result.returncode}))
    if result.returncode:raise SystemExit(result.returncode)
    if a.broadcast and manifest['status']=='INCOMPLETE':raise SystemExit('Incomplete broadcast; inspect receipts. Never rerun with a new ID to recover.')
if __name__=='__main__':
    try:
        if sys.argv[1:]==['attest']:
            attest();print('0x01');raise SystemExit(0)
        p=argparse.ArgumentParser();p.add_argument('--core-tag',required=True);p.add_argument('--strategy-tag',required=True);p.add_argument('--strategy-repo',required=True);p.add_argument('--script',default='script/DeployCoreSystem.s.sol');p.add_argument('--addresses',required=True,help='Reviewed existing Core/Strategy address inventory');p.add_argument('--broadcast',action='store_true');run(p.parse_args())
    except (ValueError,KeyError,subprocess.CalledProcessError) as ex:
        print('Release rejected: '+(str(ex) if not isinstance(ex,subprocess.CalledProcessError) else 'Git validation failed'),file=sys.stderr);raise SystemExit(1)
