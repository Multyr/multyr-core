#!/usr/bin/env python3
"""Read-only creation/runtime/ownership proof. Never masks runtime differences."""
import argparse, concurrent.futures, hashlib, json, os, pathlib, urllib.request, time

def sha(data): return hashlib.sha256(bytes.fromhex(data.removeprefix('0x'))).hexdigest()
def rpc(method, params):
    for attempt in range(3):
        try:
            req=urllib.request.Request(os.environ['RPC_URL'],json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(),{'Content-Type':'application/json'})
            with urllib.request.urlopen(req,timeout=90) as r: result=json.load(r)
            if 'error' in result: raise RuntimeError(str(result['error'].get('code'))+': '+result['error'].get('message','RPC error'))
            return result['result']
        except Exception as ex:
            if attempt==2: raise RuntimeError('RPC request failed: '+method+' ('+(str(ex) if isinstance(ex,RuntimeError) else type(ex).__name__)+')') from None
            time.sleep(1)
def main():
    p=argparse.ArgumentParser();p.add_argument('--artifacts',required=True);p.add_argument('--commit',required=True);p.add_argument('--receipts',nargs='+',required=True);p.add_argument('--output',required=True);a=p.parse_args()
    assert int(rpc('eth_chainId',[]),16)==42161,'Wrong chain'
    block=rpc('eth_getBlockByNumber',['latest',False]);bn=block['number']
    artifacts=[]
    for f in pathlib.Path(a.artifacts).glob('*/*.json'):
        d=json.loads(f.read_text());code=d.get('bytecode',{}).get('object','').removeprefix('0x')
        if code: artifacts.append((code.lower(),d,f))
    txs=[t for f in a.receipts for t in json.load(open(f))['transactions'] if t['transactionType'] in ('CREATE','CREATE2')]
    def check(t):
        addr=t['contractAddress']; h=t.get('hash') or t['transactionHash']; tx=rpc('eth_getTransactionByHash',[h]);rec=rpc('eth_getTransactionReceipt',[h]);trace=rpc('debug_traceTransaction',[h,{'tracer':'callTracer'}]);live=rpc('eth_getCode',[addr,bn]).lower()
        init=tx['input'].removeprefix('0x').lower()
        matches=[x for x in artifacts if init.startswith(x[0])]
        if not matches: return {'address':addr,'transaction':h,'name':t.get('contractName'),'status':'CREATION_MISMATCH'}
        code,d,f=max(matches,key=lambda x:len(x[0]));out=trace.get('output','').lower();runtime=d['deployedBytecode']['object'].removeprefix('0x').lower();actual=live.removeprefix('0x')
        spans=[s for v in d['deployedBytecode'].get('immutableReferences',{}).values() for s in v]
        imm=[];patched=runtime
        for s in spans:
            lo=s['start']*2;hi=lo+s['length']*2;value=out.removeprefix('0x')[lo:hi];imm.append({**s,'creationValue':'0x'+value,'currentValue':'0x'+actual[lo:hi]});patched=patched[:lo]+value+patched[hi:]
        passed=(int(rec['status'],16)==1 and rec['contractAddress'].lower()==addr.lower() and trace.get('type') in ('CREATE','CREATE2') and not trace.get('error') and trace.get('input','').lower()==tx['input'].lower() and out==live and patched==actual)
        return {'name':f.stem,'address':addr,'transaction':h,'deploymentBlock':int(rec['blockNumber'],16),'status':'PASS' if passed else 'MISMATCH','compiledCreationPrefixMatch':True,'constructorAbi':next((x.get('inputs',[]) for x in d['abi'] if x['type']=='constructor'),[]),'constructorArgumentsHex':'0x'+init[len(code):],'runtimeBytes':len(actual)//2,'compiledCreationSha256':sha(code),'transactionInputSha256':sha(init),'creationRuntimeSha256':sha(out),'currentRuntimeSha256':sha(live),'creationRuntimeEqualsCurrent':out==live,'compiledRuntimeWithCreationImmutablesEqualsCurrent':patched==actual,'immutableBindings':imm}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as ex: checks=list(ex.map(check,txs))
    owners=[]
    for c in checks:
        if c['name'] in ['CoreVault','FeeCollector','VaultFactory','RecoveryGate']:
            def call(selector):return '0x'+rpc('eth_call',[{'to':c['address'],'data':selector},bn])[-40:]
            method,selector,pendingMethod,pendingSelector={'FeeCollector':('governor','0x0c340a24','pendingGovernor','0xe3056a34'),'RecoveryGate':('rootTimelock','0x9dd92e6e','pendingRootTimelock','0x084ca768')}.get(c['name'],('owner','0x8da5cb5b','pendingOwner','0xe30c3978'))
            try: owners.append({'name':c['name'],'address':c['address'],'authorityGetter':method,'authority':call(selector),'pendingAuthorityGetter':pendingMethod,'pendingAuthority':call(pendingSelector)})
            except RuntimeError as ex:owners.append({'name':c['name'],'address':c['address'],'error':str(ex)})
    result={'schemaVersion':1,'mode':'READ_ONLY','coreMainCommit':a.commit,'chainId':42161,'blockNumber':int(bn,16),'blockHash':block['hash'],'blockTimestamp':int(block['timestamp'],16),'hashAlgorithm':'SHA-256','method':'Exact compiled creation prefix against RPC transaction input; successful CREATE trace runtime compared byte-for-byte with pinned current runtime; compiler runtime patched only with trace-derived immutable values and compared byte-for-byte. No masked differences.','checks':checks,'ownership':owners,'allBytecodeChecksPass':all(c['status']=='PASS' for c in checks)}
    if rpc('eth_getBlockByNumber',[bn,False])['hash']!=block['hash']:raise RuntimeError('Pinned block reorganized')
    with open(a.output,'x') as f:json.dump(result,f,indent=2);f.write('\n')
    print(json.dumps({'allBytecodeChecksPass':result['allBytecodeChecksPass'],'contracts':len(checks),'blockNumber':result['blockNumber'],'ownership':owners}))
    if not result['allBytecodeChecksPass'] or any('error' in o for o in owners):raise SystemExit(1)
if __name__=='__main__':main()
