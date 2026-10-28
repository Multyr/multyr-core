#!/usr/bin/env python3
"""CI: deployment JSON and release evidence are append-only."""
import subprocess,sys
base=sys.argv[1]
lines=subprocess.check_output(['git','diff','--name-status','--no-renames',base,'HEAD','--','broadcast','deployments'],text=True).splitlines()
bad=[l for l in lines if not l.startswith('A\t') and l.split('\t')[-1].endswith('.json')]
if bad:raise SystemExit('Existing deployment records must not be edited/deleted; append a superseding snapshot:\n'+'\n'.join(bad))
