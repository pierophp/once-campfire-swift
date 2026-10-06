import json, os, shutil, subprocess, sys, tempfile, time, urllib.request
from pathlib import Path
root=Path(os.environ.get('CAMPFIRE_RUST_ROOT', Path(__file__).resolve().parents[4]/'once-campfire-rust'))
seed=root/'parity/.seed/default'
labels=json.loads((seed/'labels.json').read_text())
work=Path(tempfile.mkdtemp(prefix='campfire-perf-'))
name='campfire-swift-perf-loop'
port=4590
image=sys.argv[1] if len(sys.argv)>1 else 'campfire-swift:optimized'
lg=str(root/'target/bench/release/loadgen')
workload=sys.argv[2] if len(sys.argv)>2 else 'sidebar'
assert workload in ('sidebar','messages_page')
route='/users/me/sidebar' if workload=='sidebar' else f"/rooms/{labels['rooms.watercooler']}/messages?before={labels['messages.busy_060']}"
threshold=100 if workload=='sidebar' else 500
def call(args):
 return subprocess.check_output(args, text=True)
def load(args):
 return json.loads(call(['taskset','-c','4-7',lg]+args))
try:
 shutil.copytree(seed/'db',work/'db')
 shutil.copytree(seed/'storage',work/'files')
 subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 call(['docker','run','-d','--name',name,'--network','host','--cpuset-cpus','0-3','--user',f'{os.getuid()}:{os.getgid()}','--env-file',str(root/'parity/.env.reference'),'-e',f'HTTP_PORT={port}','-e','RAILS_MAX_THREADS=5','-v',f'{work}/db:/rails/storage/db','-v',f'{work}/files:/rails/storage/files',image])
 base=f'http://127.0.0.1:{port}'
 for _ in range(100):
  try:
   urllib.request.urlopen(base+'/up',timeout=1).close(); break
  except Exception: time.sleep(.1)
 cookie=load(['login','--base',base,'--email',labels['emails.david'],'--password',labels['passwords.all']])['cookie']
 args=['http','--base',base,'--cookie',cookie,'--path',route,'--conc','16']
 load(args+['--duration','1'])
 result=load(args+['--duration','3'])
 print(json.dumps({k:result[k] for k in ('rps','statuses','errors','latency')},indent=2))
 passed=result['rps']>=threshold and result['errors']==0 and set(result['statuses'])=={'200'}
 print('PASS' if passed else f'FAIL: {workload} must exceed {threshold} successful requests/sec')
 sys.exit(0 if passed else 1)
finally:
 subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 shutil.rmtree(work)
