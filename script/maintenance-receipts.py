#!/usr/bin/env python3
"""Print public transaction receipt data only; never output signing/cache material."""
import json
from pathlib import Path
p=Path(__file__).resolve().parents[1]/'broadcast/RunArbitrumMaintenance.s.sol/42161/run-latest.json'
if not p.exists(): raise SystemExit('No broadcast file. Simulation receipts are not mainnet transactions.')
d=json.loads(p.read_text())
for r in d.get('receipts',[]):
 h=r.get('transactionHash');status=r.get('status')
 if h: print(json.dumps({'hash':h,'status':status,'gasUsed':r.get('gasUsed'),'arbiscan':'https://arbiscan.io/tx/'+h}))
print('Receipt status alone does not prove adapter deposits; check upkeep failure events and live positions.')
