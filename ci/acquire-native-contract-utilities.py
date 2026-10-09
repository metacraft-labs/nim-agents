"""Acquire actual locked Unix utility closure for unchanged native Actions78/33.
No mocks, aliases, global PATH or original assertion edits. Caller Git configuration
and existing Git/Bash/Python suppliers remain unchanged; native execution required.
"""
from pathlib import Path
import os,sys,subprocess,json,hashlib,stat,tempfile,platform,struct,shutil
ROOT=Path.cwd();R={'success':False,'scope':__doc__}
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def run(argv):return subprocess.check_output(argv,cwd=ROOT)
def image(p):
  p=Path(p);q=p.resolve(strict=True);st=q.stat();assert stat.S_ISREG(st.st_mode)
  return {'lexical':str(p),'resolved':str(q),'mode':st.st_mode,'sha256':sha(q)}
def declared_tool(name):
  p=shutil.which(name)
  if p is None:raise RuntimeError('Missing declared native tool: '+name)
  return image(p)
def directory(p):
  st=p.lstat();assert stat.S_ISDIR(st.st_mode) and not p.is_symlink()
  return [st.st_dev,st.st_ino]
def source():
  assert Path(run(['git','rev-parse','--show-toplevel']).decode().strip())==ROOT
  head=run(['git','rev-parse','HEAD']).decode().strip();assert head==os.environ['GITHUB_SHA'],'Owning event mismatch'
  assert run(['git','diff','--cached','--name-only'])==b'' and run(['git','status','--porcelain','--untracked-files=no'])==b''
  rows={}
  for row in run(['git','ls-tree','-rz',head]).split(b'\0'):
    if not row:continue
    meta,name=row.split(b'\t',1);mode,kind,oid=meta.split();p=ROOT/os.fsdecode(name);body=run(['git','cat-file','blob',oid.decode()])
    if mode==b'120000':assert p.is_symlink() and os.fsencode(os.readlink(p))==body
    else:
      assert not p.is_symlink() and p.is_file() and p.read_bytes()==body
      assert bool(p.stat().st_mode&0o111)==(mode==b'100755')
    rows[os.fsdecode(name)]={'gitMode':mode.decode(),'oid':oid.decode(),'sha256':hashlib.sha256(body).hexdigest()}
  return {'head':head,'root':directory(ROOT),'rows':rows}
def closure(output):
  result=json.loads(run(['nix','path-info','--recursive','--json',output]));assert result
  verified={}
  entries=result.items() if isinstance(result,dict) else [(row['path'],row) for row in result]
  for name,row in entries:
    assert name.startswith('/nix/store/') and row['narHash']
    actual=run(['nix','hash','path','--type','sha256','--sri',name]).decode().strip();assert actual==row['narHash']
    verified[name]={'metadata':row,'actualNar':actual}
  return verified
def macho_cpus(path):
  b=Path(path).read_bytes();magic=b[:4]
  if magic in [b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe']:return [struct.unpack_from('<I',b,4)[0]]
  if magic in [b'\xfe\xed\xfa\xcf',b'\xfe\xed\xfa\xce']:return [struct.unpack_from('>I',b,4)[0]]
  assert magic in [b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf']
  count=struct.unpack_from('>I',b,4)[0];assert 0<count<32
  size=32 if magic==b'\xca\xfe\xba\xbf' else 20
  return [struct.unpack_from('>I',b,8+i*size)[0] for i in range(count)]
assert ROOT.is_absolute() and ROOT.resolve()==ROOT
native=platform.system();assert native=='Darwin' or os.environ.get('NIM_PRIVATE_LINUX_COMPONENT')=='1'
gitConfiguration=run(['git','config','--null','--show-origin','--show-scope','--list'])
before=source()
tools={role:declared_tool(role) for role in ['git','nix']};tools['python']=image(sys.executable)
base=Path(os.environ['RUNNER_TEMP']).resolve(strict=True);baseID=directory(base);receipt=Path(tempfile.mkdtemp(prefix='nim-native-utilities-',dir=base));receiptID=directory(receipt)
command=Path(os.environ['GITHUB_PATH']);assert command.is_absolute() and not command.is_symlink(),'Foreign activation path'
fd=None
try:
  fd=os.open(command,os.O_RDWR|os.O_APPEND|os.O_NOFOLLOW);held=os.fstat(fd);assert stat.S_ISREG(held.st_mode) and held.st_nlink==1,'Foreign activation object'
  original=os.pread(fd,held.st_size,0);assert not original or original.endswith(b'\n'),'Malformed existing activation record'
  def command_guard(expected):
    st=command.lstat();assert not stat.S_ISLNK(st.st_mode) and [st.st_dev,st.st_ino]==[held.st_dev,held.st_ino] and st.st_nlink==1
    assert os.pread(fd,len(expected)+1,0)==expected
  def guards(expected):
    assert gitConfiguration==run(['git','config','--null','--show-origin','--show-scope','--list'])
    assert before==source()
    assert tools=={role:image(v['lexical']) for role,v in tools.items()}
    assert directory(base)==baseID and directory(receipt)==receiptID
    command_guard(expected)
  ref='git+file://'+str(ROOT)+'?rev='+before['head']+'&shallow=1#ci-native-contract-utilities'
  expectedDeriver=run(['nix','eval','--raw','--no-update-lock-file',ref+'.drvPath']).decode().strip()
  build=json.loads(run(['nix','build','--no-link','--json','--no-update-lock-file',ref+'.out']));assert len(build)==1 and build[0]['drvPath']==expectedDeriver
  output=build[0]['outputs']['out'];assert output.startswith('/nix/store/') and '\n' not in output
  utilityNames=['grep','sed','sort','head','dirname','basename','mktemp','mkdir','rm','cat','chmod','env','sleep']
  shellImages={str(Path(output)/'bin'/name):image(Path(output)/'bin'/name) for name in utilityNames}
  version=b''
  for name in ['grep','sed','sort']:
    result=run([str(Path(output)/'bin'/name),'--version']);assert result;version+=result
  machine=platform.machine()
  if native=='Darwin':
    assert machine=='arm64'
    R['nativeImageCPUs']={name:macho_cpus(data['resolved']) for name,data in shellImages.items()}
    assert all(0x0100000c in cpus for cpus in R['nativeImageCPUs'].values())
  initialClosure=closure(output);R.update(build=build,closureBefore=initialClosure,shellImagesBefore=shellImages,versionSHA=hashlib.sha256(version).hexdigest(),machine=machine,sourceBefore=before,toolsBefore=tools,existingToolPathPreserved=True)
  guards(original)
  assert initialClosure==closure(output) and shellImages=={p:image(p) for p in shellImages}
  addition=(output+'/bin\n').encode();remaining=memoryview(addition)
  while remaining:
    written=os.write(fd,remaining);assert written>0;remaining=remaining[written:]
  os.fsync(fd)
  guards(original+addition)
  assert initialClosure==closure(output)
  R.update(success=True,sourceAfter=source(),toolsAfter={role:image(v['lexical']) for role,v in tools.items()},closureAfter=closure(output),activationSHA=hashlib.sha256(original+addition).hexdigest(),activationScope='Held GITHUB_PATH append complete; existing tool suppliers preserved')
finally:
  if fd is not None:os.close(fd)
  R['controllerSHA']=sha(Path(__file__));(receipt/'receipt.json').write_text(json.dumps(R,indent=2)+'\n')
print(receipt/'receipt.json')
