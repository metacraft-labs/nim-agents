"""Route only known owning GitHub credentials; never print/store credential values."""
import re

def route_tokens(existing, old_app, fresh_app, public_job, host='github.com', owner='metacraft-labs'):
    """Preserve unrelated scopes and refuse any ambiguous owned host/path authority."""
    if not isinstance(existing, dict):
        raise ValueError('Nix token settings are not a map')
    def safe(value):
        return isinstance(value, str) and bool(value) and not any(c.isspace() or ord(c)<32 or ord(c)==127 for c in value)
    if not all(safe(v) for v in (old_app, fresh_app, public_job)):
        raise ValueError('Invalid declared credential shape')
    if not re.fullmatch(r'[a-zA-Z0-9.-]+(?::[0-9]+)?',host) or not re.fullmatch(r'[a-zA-Z0-9-]+',owner):
        raise ValueError('Invalid declared routing scope')
    result=dict(existing)
    for key,value in result.items():
        if not safe(key) or '=' in key or not safe(value):
            raise ValueError('Unsupported existing token map shape')
    if result.get(host) not in (old_app,public_job):
        raise ValueError('Foreign or absent whole-host credential authority')
    scope=host+'/'+owner
    for key,value in list(result.items()):
        if key==scope or key.startswith(scope+'/'):
            if value not in (old_app,fresh_app):
                raise ValueError('Foreign owner-scope credential authority')
            result[key]=fresh_app
    result[host]=public_job
    result[scope]=fresh_app
    return result

def child_config(inherited, routed):
    if not isinstance(inherited,str) or '\x00' in inherited or '\r' in inherited:
        raise ValueError('Unsupported inherited Nix configuration')
    # Keep every original setting byte; this last setting overrides only token
    # routing, retaining the complete effective unrelated scope map.
    entries=' '.join(key+'='+routed[key] for key in sorted(routed))
    return inherited+('' if not inherited or inherited.endswith('\n') else '\n')+'access-tokens = '+entries+'\n'


def main():
    import hashlib,json,os,shutil,stat,subprocess,sys,uuid
    from pathlib import Path
    root=Path(os.environ.get('NIM_NIX_SOURCE_ROOT',''))
    revision=os.environ.get('GITHUB_SHA','')
    if not root.is_absolute() or root.is_symlink() or root.resolve(strict=True)!=root or not re.fullmatch('[0-9a-f]{40}',revision):
        raise ValueError('Invalid owning root or event identity')
    root_id=(root.stat().st_dev,root.stat().st_ino)
    script=Path(__file__).resolve();relative=script.relative_to(root).as_posix()
    metadata_env={k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
    git_lexical=Path(shutil.which('git') or '')
    if not git_lexical.is_absolute() or not git_lexical.is_file():raise ValueError('Git principal is unavailable')
    git_image=git_lexical.resolve(strict=True);git_body=git_image.read_bytes()
    python_image=Path(sys.executable).resolve(strict=True);python_body=python_image.read_bytes()
    def git(*args):
        x=subprocess.run([str(git_lexical),'-C',str(root),*args],env=metadata_env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        if x.returncode:raise ValueError('Owning Git metadata operation failed')
        return x.stdout
    def source_state():
        if root.is_symlink() or root.resolve(strict=True)!=root or (root.stat().st_dev,root.stat().st_ino)!=root_id or git('rev-parse','HEAD').decode().strip()!=revision or git('rev-parse','--show-toplevel').decode().strip()!=str(root):
            raise ValueError('Owning source identity changed')
        tree={}
        for row in git('ls-tree','-rz',revision).split(b'\0'):
            if not row:continue
            meta,name=row.split(b'\t',1);mode,kind,oid=meta.split();tree[name]=(mode,oid)
        index={}
        for row in git('ls-files','--stage','-z').split(b'\0'):
            if not row:continue
            meta,name=row.split(b'\t',1);mode,oid,stage=meta.split()
            if stage!=b'0' or name in index:raise ValueError('Unsupported index authority')
            index[name]=(mode,oid)
        if tree!=index:raise ValueError('Owning index differs from pinned event tree')
        body={}
        for name,(mode,oid) in tree.items():
            f=root/os.fsdecode(name);s=f.lstat()
            if mode==b'120000' and stat.S_ISLNK(s.st_mode):raw=os.readlink(f).encode()
            elif mode in (b'100644',b'100755') and stat.S_ISREG(s.st_mode):raw=f.read_bytes()
            else:raise ValueError('Unsupported physical tracked source')
            if hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest().encode()!=oid:raise ValueError('Physical source differs from pinned blob')
            body[os.fsdecode(name)]=(s.st_dev,s.st_ino,s.st_mode,hashlib.sha256(raw).hexdigest())
        if relative not in body:raise ValueError('Credential helper is not pinned source')
        return body
    before=source_state()
    nix=Path(os.environ.get('NIM_NIX_EXECUTABLE',''))
    if not nix.is_absolute() or not nix.is_file() or not os.access(nix,os.X_OK):raise ValueError('Nix principal is not a declared absolute executable')
    nix_image=nix.resolve(strict=True);nix_body=nix_image.read_bytes();nix_id=(nix_image.stat().st_dev,nix_image.stat().st_ino,nix_image.stat().st_mode)
    x=subprocess.Popen([str(nix),'config','show','--json'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:output,diagnostic=x.communicate()
    except Exception:
        # Keep this exact child and source authority until natural terminal.
        x.wait()
        raise ValueError('Nix inspection stream failed') from None
    if x.returncode:raise ValueError('Effective Nix configuration inspection failed')
    try:settings=json.loads(output);tokens=settings['access-tokens']['value']
    except Exception:raise ValueError('Unsupported effective Nix configuration schema') from None
    routed=route_tokens(tokens,os.environ.get('NIM_NIX_OLD_APP',''),os.environ.get('NIM_NIX_FRESH_APP',''),os.environ.get('NIM_NIX_PUBLIC_JOB',''))
    inherited=os.environ.get('NIX_CONFIG','');configuration=child_config(inherited,routed)
    if git_lexical.resolve(strict=True)!=git_image or git_image.read_bytes()!=git_body or python_image.read_bytes()!=python_body or nix.resolve(strict=True)!=nix_image:raise ValueError('Selected execution principal changed')
    if before!=source_state() or nix_image.read_bytes()!=nix_body or (nix_image.stat().st_dev,nix_image.stat().st_ino,nix_image.stat().st_mode)!=nix_id:
        raise ValueError('Source or selected Nix principal changed')
    metadata=root/'.repro'
    try:metadata.mkdir()
    except FileExistsError:pass
    fd=os.open(metadata,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    held=os.fstat(fd)
    if not stat.S_ISDIR(held.st_mode):raise ValueError('Metadata parent is not a held directory')
    envfile=Path(os.environ.get('GITHUB_ENV',''));temporary=Path(os.environ.get('RUNNER_TEMP','')).resolve(strict=True)
    if not envfile.is_absolute() or envfile.resolve(strict=True)!=envfile or not envfile.is_relative_to(temporary):raise ValueError('Activation file is outside actual runner temporary authority')
    envfd=os.open(envfile,os.O_WRONLY|os.O_APPEND|os.O_NOFOLLOW);envstat=os.fstat(envfd)
    if not stat.S_ISREG(envstat.st_mode) or envstat.st_nlink!=1 or envstat.st_size!=0:raise ValueError('Activation file is not an empty unique regular step file')
    receipt={'sourceHead':revision,'scriptSHA':before[relative][3],'nixImageSHA':hashlib.sha256(nix_body).hexdigest(),'gitImageSHA':hashlib.sha256(git_body).hexdigest(),'pythonImageSHA':hashlib.sha256(python_body).hexdigest(),'configProcessPID':x.pid,'configProcessExit':x.returncode,'processScope':'Direct process naturally waited; descendants unqualified','unrelatedScopesPreserved':all(routed[k]==v for k,v in tokens.items() if k!='github.com' and not (k=='github.com/metacraft-labs' or k.startswith('github.com/metacraft-labs/'))),'publicScope':'github.com','privateScope':'github.com/metacraft-labs','credentialValues':'Not retained; no credential hashes','validationSuccess':True,'activationScope':'Receipt precedes activation; actual helper exit and published environment remain required'}
    receipt_name='nix-credential-routing-'+uuid.uuid4().hex+'.json'
    receiptfd=os.open(receipt_name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=fd)
    with os.fdopen(receiptfd,'w') as f:json.dump(receipt,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
    current=metadata.lstat()
    env_current=envfile.stat()
    if (env_current.st_dev,env_current.st_ino)!=(envstat.st_dev,envstat.st_ino):raise ValueError('Runner activation file changed')
    if git_lexical.resolve(strict=True)!=git_image or git_image.read_bytes()!=git_body or python_image.read_bytes()!=python_body or nix.resolve(strict=True)!=nix_image or nix_image.read_bytes()!=nix_body:raise ValueError('Execution principal changed before activation')
    if (current.st_dev,current.st_ino)!=(held.st_dev,held.st_ino) or before!=source_state():raise ValueError('Owning authority changed before activation')
    check=subprocess.Popen([str(nix),'config','show','--json'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:current_output,current_diagnostic=check.communicate()
    except Exception:
        check.wait()
        raise ValueError('Terminal Nix inspection stream failed') from None
    if check.returncode:raise ValueError('Terminal Nix configuration inspection failed')
    try:current_settings=json.loads(current_output)
    except Exception:raise ValueError('Terminal Nix schema changed') from None
    if current_settings!=settings:raise ValueError('Effective inherited Nix settings changed')
    if git_lexical.resolve(strict=True)!=git_image or git_image.read_bytes()!=git_body or python_image.read_bytes()!=python_body or nix.resolve(strict=True)!=nix_image or nix_image.read_bytes()!=nix_body:raise ValueError('Terminal execution principal changed')
    if (envfile.stat().st_dev,envfile.stat().st_ino)!=(envstat.st_dev,envstat.st_ino) or envfile.stat().st_size!=0 or before!=source_state():raise ValueError('Activation authority changed')
    separator='NIX_CONFIG_'+uuid.uuid4().hex
    payload='NIX_CONFIG<<'+separator+'\n'+configuration+separator+'\n'
    with os.fdopen(envfd,'a') as f:f.write(payload);f.flush();os.fsync(f.fileno())
    os.close(fd)

if __name__=='__main__':
    try:main()
    except Exception:
        # Never echo captured config/error payloads or credential-valued input.
        import sys
        print('Nix credential routing refused',file=sys.stderr)
        raise SystemExit(1)
