import hashlib,json,os,shutil,subprocess,tempfile,time,urllib.request
from pathlib import Path
root=Path(os.environ.get('CAMPFIRE_RUST_ROOT', Path(__file__).resolve().parents[4]/'once-campfire-rust'))
seed=root/'parity/.seed/default'
labels=json.loads((seed/'labels.json').read_text())
containers=[]
work=Path(tempfile.mkdtemp(prefix='campfire-parity-perf-'))
images=['campfire-swift:baseline-65a938d','campfire-swift:optimized']
records={}
try:
 for index,image in enumerate(images):
  name=f'campfire-perf-parity-{index}'
  containers.append(name)
  port=4591+index
  directory=work/str(index)
  shutil.copytree(seed/'db',directory/'db')
  shutil.copytree(seed/'storage',directory/'files')
  subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  subprocess.check_output(['docker','run','-d','--name',name,'--network','host','--cpuset-cpus','0-3','--user',f'{os.getuid()}:{os.getgid()}','--env-file',str(root/'parity/.env.reference'),'-e',f'HTTP_PORT={port}','-v',f'{directory}/db:/rails/storage/db','-v',f'{directory}/files:/rails/storage/files',image],text=True)
  base=f'http://127.0.0.1:{port}'
  for _ in range(100):
   try: urllib.request.urlopen(base+'/up',timeout=1).close();break
   except Exception: time.sleep(.1)
  result=subprocess.run([str(root/'target/bench/release/loadgen'),'login','--base',base,'--email',labels['emails.david'],'--password',labels['passwords.all']],capture_output=True,text=True)
  if result.returncode: raise RuntimeError('local login failed')
  cookie=json.loads(result.stdout)['cookie']
  snapshots=[]
  for route in [f"/rooms/{labels['rooms.watercooler']}",f"/rooms/{labels['rooms.watercooler']}/messages?before={labels['messages.busy_060']}",'/users/me/sidebar','/searches?q=coffee']:
   request=urllib.request.Request(base+route,headers={'Cookie':cookie,'Accept-Encoding':'identity','Host':'campfire-benchmark.test'})
   with urllib.request.urlopen(request) as response:
    body=response.read()
    snapshots.append({'route':route,'status':response.status,'sha256':hashlib.sha256(body).hexdigest(),'bytes':len(body),'etag':response.headers.get('etag'),'content_type':response.headers.get('content-type'),'cache_control':response.headers.get('cache-control')})
  records[image]=snapshots
 equal=records[images[0]]==records[images[1]]
 print(json.dumps({'identical_read_responses':equal,'snapshots':records},indent=2))
 if not equal: raise RuntimeError('read responses differ')
finally:
 for name in containers: subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 shutil.rmtree(work)
