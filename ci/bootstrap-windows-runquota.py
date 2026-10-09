"""Construct the real release-source daemon before mandatory graph admission.
Private candidate: native Windows x64 execution remains unqualified. No daemon
is manually started/stopped; the full CLI retains its admission lifecycle.
"""
from pathlib import Path
import ctypes, hashlib, json, os, platform, re, shutil, stat, subprocess, sys, uuid, zipfile
from ctypes import wintypes
import urllib.request

POLICY_PATH = Path(__file__).with_name('bootstrap-policy.json')
with POLICY_PATH.open('rb') as policy_file:
    policy_stat = os.fstat(policy_file.fileno())
    if not stat.S_ISREG(policy_stat.st_mode) or getattr(policy_stat, 'st_file_attributes', 0) & 0x400:
        raise RuntimeError('Foreign policy source')
    POLICY_BYTES = policy_file.read()
    policy_after = os.fstat(policy_file.fileno())
    if (policy_stat.st_dev, policy_stat.st_ino, policy_stat.st_size, policy_stat.st_mtime_ns) != (policy_after.st_dev, policy_after.st_ino, policy_after.st_size, policy_after.st_mtime_ns):
        raise RuntimeError('Policy changed while captured')
    lexical_policy = POLICY_PATH.lstat()
    if (lexical_policy.st_dev, lexical_policy.st_ino) != (policy_stat.st_dev, policy_stat.st_ino):
        raise RuntimeError('Policy source path replaced')
POLICY_CAPTURE = {'path': str(POLICY_PATH), 'dev': policy_stat.st_dev, 'ino': policy_stat.st_ino,
                  'mode': stat.S_IMODE(policy_stat.st_mode), 'bytes': len(POLICY_BYTES),
                  'sha256': hashlib.sha256(POLICY_BYTES).hexdigest()}
POLICY = json.loads(POLICY_BYTES)
ROOT = Path.cwd().absolute()
STATE = {'success': False, 'scope': 'daemon bootstrap only; graph and product actions unexecuted'}
HELD = []

class HandleInfo(ctypes.Structure):
    _fields_ = [('attributes', wintypes.DWORD), ('created', wintypes.FILETIME),
                ('accessed', wintypes.FILETIME), ('written', wintypes.FILETIME),
                ('volume', wintypes.DWORD), ('sizeHigh', wintypes.DWORD),
                ('sizeLow', wintypes.DWORD), ('links', wintypes.DWORD),
                ('indexHigh', wintypes.DWORD), ('indexLow', wintypes.DWORD)]

def handle_identity(kernel, handle):
    kernel.GetFileInformationByHandle.argtypes = [wintypes.HANDLE, ctypes.POINTER(HandleInfo)]
    kernel.GetFileInformationByHandle.restype = wintypes.BOOL
    value = HandleInfo()
    if not kernel.GetFileInformationByHandle(handle, ctypes.byref(value)):
        raise ctypes.WinError(ctypes.get_last_error())
    if value.attributes & 0x400: raise RuntimeError('Held reparse entry refused')
    return [value.volume, value.indexHigh, value.indexLow, value.created.dwHighDateTime,
            value.created.dwLowDateTime, value.attributes, value.links]

def file_identity(path):
    path = Path(path); s = path.lstat()
    if not stat.S_ISREG(s.st_mode) or getattr(s, 'st_file_attributes', 0) & 0x400:
        raise RuntimeError('Nonregular file authority')
    return {'path': str(path), 'dev': s.st_dev, 'ino': s.st_ino, 'mode': stat.S_IMODE(s.st_mode),
            'bytes': s.st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}

def directory(path):
    path = Path(path); s = path.lstat()
    if not stat.S_ISDIR(s.st_mode) or getattr(s, 'st_file_attributes', 0) & 0x400 or path.resolve() != path:
        raise RuntimeError('Foreign directory authority')
    return {'path': str(path), 'dev': s.st_dev, 'ino': s.st_ino, 'mode': stat.S_IMODE(s.st_mode)}

def hold(path):
    before = directory(path)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                    ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p]
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    handle = kernel.CreateFileW(str(path), 0x80, 3, None, 3, 0x02200000, None)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    HELD.append((kernel, handle, Path(path), before, handle_identity(kernel, handle)))
    if directory(path) != before: raise RuntimeError('Changed claimed directory')

def verify_directories():
    for kernel, handle, path, before, native in HELD:
        if directory(path) != before: raise RuntimeError('Changed held directory')
        if handle_identity(kernel, handle) != native: raise RuntimeError('Changed held handle authority')
        current = kernel.CreateFileW(str(path), 0x80, 3, None, 3, 0x02200000, None)
        if current == ctypes.c_void_p(-1).value: raise ctypes.WinError(ctypes.get_last_error())
        try:
            if handle_identity(kernel, current) != native: raise RuntimeError('Held directory path was replaced')
        finally: kernel.CloseHandle(current)

def whole_files(root, expected, git_metadata=False):
    root = Path(root); directory(root); actual = {}
    for parent, dirs, files in os.walk(root, followlinks=False):
        directory(Path(parent))
        if git_metadata and Path(parent) == root:
            dirs[:] = [name for name in dirs if name != '.git']
        for name in dirs: directory(Path(parent) / name)
        for name in files:
            q = Path(parent) / name; actual[q.relative_to(root).as_posix()] = file_identity(q)
    if set(actual) != set(expected): raise RuntimeError('Unknown or missing source/runtime member')
    for name, value in expected.items():
        digest = value if isinstance(value, str) else value['sha256']
        if actual[name]['sha256'] != digest: raise RuntimeError('Changed source/runtime member: ' + name)
    return actual

def owning(git):
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                GIT_OPTIONAL_LOCKS='0', GIT_NO_REPLACE_OBJECTS='1')
    def query(*args): return subprocess.check_output([str(git), '-C', str(ROOT), *args], env=env)
    head = query('rev-parse', 'HEAD').decode().strip()
    if head != os.environ['GITHUB_SHA']: raise RuntimeError('Foreign triggering event checkout')
    tracked = {}
    for name in query('ls-files', '-z').decode().split('\0'):
        if name: tracked[name] = file_identity(ROOT / name)
    return {'head': head, 'index': hashlib.sha256(query('ls-files', '--stage', '-z')).hexdigest(), 'tracked': tracked}

def pe64(path):
    b = Path(path).read_bytes()
    if len(b) < 64 or b[:2] != b'MZ': raise RuntimeError('Missing native PE image')
    offset = int.from_bytes(b[60:64], 'little')
    if offset > len(b) - 26 or b[offset:offset+4] != b'PE\0\0' or int.from_bytes(b[offset+4:offset+6], 'little') != 0x8664 or int.from_bytes(b[offset+24:offset+26], 'little') != 0x20b:
        raise RuntimeError('Non-AMD64 PE32+ image')

def child(name, argv, cwd, env):
    verify_directories()
    out, err = OWNED / (name + '.stdout'), OWNED / (name + '.stderr')
    with out.open('xb') as stdout, err.open('xb') as stderr:
        p = subprocess.Popen(argv, cwd=cwd, env=env, stdout=stdout, stderr=stderr)
        code = p.wait()
    STATE.setdefault('rows', []).append({'name': name, 'pid': p.pid, 'exit': code,
        'scope': 'owned direct-child natural wait; no descendant census',
        'stdout': file_identity(out), 'stderr': file_identity(err)})
    verify_directories()
    if code: raise RuntimeError(name + ' failed; original raw retained')
    return out.read_text(errors='strict').strip()

def archive_integrity(archive, contract):
    observed = file_identity(archive)
    if observed['sha256'] != contract['sha256'] or observed['bytes'] != contract['bytes']:
        raise RuntimeError('Changed declared bootstrap archive')
    return observed

def archive_entry(entry, seen):
    name = entry.filename.rstrip('/')
    if entry.orig_filename != entry.filename or not name or name.startswith('/') or '\\' in name or ':' in name or '..' in name.split('/') or any(ord(c) < 32 for c in name) or name.casefold() in seen:
        raise RuntimeError('Foreign/colliding archive member')
    if stat.S_IFMT(entry.external_attr >> 16) == stat.S_IFLNK:
        raise RuntimeError('Archive symlink refused')
    seen.add(name.casefold())
    return name

def package(key):
    contract = POLICY[key]; archive = OWNED / (key + '.zip')
    request = urllib.request.Request(contract['url'], headers={'User-Agent': 'metacraft-nim-runquota-bootstrap/1'})
    with urllib.request.urlopen(request) as incoming, archive.open('xb') as out:
        shutil.copyfileobj(incoming, out)
    observed = archive_integrity(archive, contract)
    destination = OWNED / key; destination.mkdir(); hold(destination)
    names, seen = {}, set()
    with zipfile.ZipFile(archive) as z:
        if len(z.infolist()) != contract['entries']: raise RuntimeError('Archive membership refused')
        for entry in z.infolist():
            name = archive_entry(entry, seen); target = destination / name
            if entry.is_dir(): target.mkdir(parents=True, exist_ok=True); names[name] = ('D', 0, '')
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with z.open(entry) as incoming, target.open('xb') as out: shutil.copyfileobj(incoming, out)
                identity = file_identity(target)
                if identity['bytes'] != entry.file_size: raise RuntimeError('Incomplete archive member')
                names[name] = ('F', identity['bytes'], identity['sha256'])
    actual = {}
    for parent, dirs, files in os.walk(destination, followlinks=False):
        directory(Path(parent))
        for name in dirs:
            q = Path(parent) / name; directory(q); actual[q.relative_to(destination).as_posix()] = ('D', 0, '')
        for name in files:
            q = Path(parent) / name; i = file_identity(q); actual[q.relative_to(destination).as_posix()] = ('F', i['bytes'], i['sha256'])
    if actual != names: raise RuntimeError('Unknown realized bootstrap member')
    canonical = ''.join('D\0' + n + '\n' if v[0] == 'D' else 'F\0' + n + '\0' + str(v[1]) + '\0' + v[2] + '\n'
                        for n, v in sorted(actual.items())).encode()
    if hashlib.sha256(canonical).hexdigest() != contract['canonicalSHA']:
        raise RuntimeError('Whole bootstrap payload refused')
    STATE.setdefault('packages', {})[key] = {'archive': observed, 'canonicalSHA': contract['canonicalSHA'], 'members': actual}
    return destination / contract['root']

def unchanged_package(key):
    destination = OWNED / key; actual = {}
    for parent, dirs, files in os.walk(destination, followlinks=False):
        directory(Path(parent))
        for name in dirs:
            q = Path(parent) / name; directory(q); actual[q.relative_to(destination).as_posix()] = ('D', 0, '')
        for name in files:
            q = Path(parent) / name; i = file_identity(q); actual[q.relative_to(destination).as_posix()] = ('F', i['bytes'], i['sha256'])
    if actual != STATE['packages'][key]['members']: raise RuntimeError('Changed bootstrap runtime/header payload')
    if file_identity(OWNED / (key + '.zip')) != STATE['packages'][key]['archive']: raise RuntimeError('Changed bootstrap archive')

def main():
    global OWNED, RECEIPT_PARENT
    if os.name != 'nt' or platform.machine().lower() not in ('amd64', 'x86_64') or os.environ.get('RUNNER_ARCH') != 'X64':
        raise RuntimeError('Native Windows x64 bootstrap required')
    if os.environ.get('REPRO_FULL_CLI') or os.environ.get('REPRO_PUBLIC_CLI_PATH'):
        raise RuntimeError('Inherited backend selector refused')
    for key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE',
                'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_NAMESPACE',
                'GIT_TEMPLATE_DIR', 'GIT_CONFIG', 'GIT_REPLACE_REF_BASE'):
        if key in os.environ: raise RuntimeError('Inherited Git path authority refused')
    namespace = os.environ['NIM_CI_NAMESPACE']
    if not re.fullmatch(r'declared-ci-[0-9]+-[0-9]+-[A-Za-z0-9_-]+-[0-9]+', namespace):
        raise RuntimeError('Foreign task namespace')
    if ROOT != Path(os.environ['GITHUB_WORKSPACE']).absolute(): raise RuntimeError('Foreign physical Windows consumer root')
    hold(ROOT)
    STATE['githubEnvironmentBefore'] = file_identity(Path(os.environ['GITHUB_ENV']))
    RECEIPT_PARENT = ROOT / '.repro'
    try: RECEIPT_PARENT.mkdir()
    except FileExistsError: directory(RECEIPT_PARENT)
    hold(RECEIPT_PARENT)
    public = Path(shutil.which('repro') or '').absolute(); backend = public.with_name('reprobuild.exe')
    STATE['public'] = file_identity(public); STATE['backend'] = file_identity(backend)
    if STATE['public']['sha256'] != POLICY['thinSHA'] or STATE['backend']['sha256'] != POLICY['backendSHA']:
        raise RuntimeError('Foreign released launcher/backend')
    release_bin = whole_files(public.parent, POLICY['releaseBin'])
    package_root = public.parent.parent
    source = package_root / 'share/repro/src/runquota'; source_before = whole_files(source, POLICY['runquota'])
    actions = ROOT / namespace / '.ci-actions-native-contracts'
    git = Path(shutil.which('git') or '').absolute(); bash = Path(shutil.which('bash') or '').absolute()
    STATE['principals'] = {str(q): file_identity(q) for q in (Path(sys.executable), git, bash, Path(__file__), POLICY_PATH)}
    if STATE['principals'][str(POLICY_PATH)] != POLICY_CAPTURE:
        raise RuntimeError('Policy principal differs from captured parsed bytes')
    STATE['owningBefore'] = owning(git)
    policy_relative = POLICY_PATH.relative_to(ROOT).as_posix()
    metadata_env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    metadata_env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull, GIT_OPTIONAL_LOCKS='0', GIT_NO_REPLACE_OBJECTS='1')
    if subprocess.check_output([str(git), '-C', str(ROOT), 'show', 'HEAD:' + policy_relative], env=metadata_env) != POLICY_BYTES:
        raise RuntimeError('Captured policy differs from triggering tracked Git blob')
    if subprocess.check_output([str(git), '-C', str(actions), 'rev-parse', 'HEAD']).decode().strip() != POLICY['actionsRevision']:
        raise RuntimeError('Wrong immutable authentication helper checkout')
    helpers_before = {}
    for name, digest in POLICY['authenticationHelpers'].items():
        helpers_before[name] = file_identity(actions / name)
        if helpers_before[name]['sha256'] != digest: raise RuntimeError('Changed authentication helper source')
    temporary = Path(os.environ['RUNNER_TEMP']).absolute(); hold(temporary)
    OWNED = temporary / ('native-runquota-' + uuid.uuid4().hex); OWNED.mkdir(); hold(OWNED)
    STATE['ownedRoot'] = str(OWNED)
    gcc_root, nim_root = package('gcc'), package('nim')
    gcc, nim = gcc_root / 'bin/gcc.exe', nim_root / 'bin/nim.exe'
    pe64(gcc); pe64(nim)
    STATE['compilerImages'] = {str(q): file_identity(q) for q in (gcc, nim)}
    env = dict(os.environ)
    env['PATH'] = str(gcc.parent) + os.pathsep + str(nim.parent) + os.pathsep + env.get('PATH', '')
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    if child('gcc-version', [str(gcc), '-dumpfullversion'], OWNED, env) != '16.1.0': raise RuntimeError('Wrong bootstrap GCC version')
    if child('gcc-target', [str(gcc), '-dumpmachine'], OWNED, env) != 'x86_64-w64-mingw32': raise RuntimeError('Wrong native compiler target')
    STATE['nimVersion'] = child('nim-version', [str(nim), '--version'], OWNED, env)
    if not STATE['nimVersion'].startswith('Nim Compiler Version 2.2.8 [Windows: amd64]'):
        raise RuntimeError('Wrong native Nim compiler identity')
    daemon_source = OWNED / 'runquota'; daemon_source.mkdir(); hold(daemon_source)
    for name in POLICY['runquota']:
        q = daemon_source / name; q.parent.mkdir(parents=True, exist_ok=True)
        with q.open('xb') as out: out.write((source / name).read_bytes())
    whole_files(daemon_source, POLICY['runquota'])
    lease = OWNED / 'nim-shm-lease'
    env['GH_TOKEN'] = os.environ['NIM_RUNQUOTA_BOOTSTRAP_TOKEN']
    env['GIT_AUTH_DIR'] = (actions / 'git-auth').as_posix()
    env['GIT_CONFIG_PARAMETERS'] = (env.get('GIT_CONFIG_PARAMETERS', '') + ' ' if env.get('GIT_CONFIG_PARAMETERS') else '') + "'core.autocrlf'='false' 'core.eol'='lf' 'core.attributesfile'=''"
    command = '. "$GIT_AUTH_DIR/scoped-git-auth.sh"; export TOKEN_OWNERS=metacraft-labs SCOPED_GIT_AUTH_MASK=1; scoped_git_auth_build && scoped_git_auth_export && bash "$GIT_AUTH_DIR/authenticated-clone.sh" --repo metacraft-labs/nim-shm-lease --dest "$1" --rev "$2" --shallow'
    child('lease-source', [str(bash), '-euo', 'pipefail', '-c', command, 'bootstrap', lease.as_posix(), POLICY['leaseRevision']], OWNED, env)
    hold(lease)
    expected = POLICY['lease']; actual = whole_files(lease, expected, git_metadata=True)
    metadata_env = {k: v for k, v in env.items() if not k.startswith('GIT_')}
    metadata_env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull, GIT_OPTIONAL_LOCKS='0', GIT_NO_REPLACE_OBJECTS='1')
    lease_head = subprocess.check_output([str(git), '-C', str(lease), 'rev-parse', 'HEAD'], env=metadata_env).decode().strip()
    if lease_head != POLICY['leaseRevision']: raise RuntimeError('Foreign lease source revision')
    lease_index = subprocess.check_output([str(git), '-C', str(lease), 'ls-files', '--stage', '-z'], env=metadata_env)
    indexed = {}
    for record in lease_index.split(b'\0'):
        if not record: continue
        metadata, name = record.split(b'\t'); mode, blob, stage = metadata.split()
        if stage != b'0' or name.decode() in indexed: raise RuntimeError('Foreign staged lease source')
        indexed[name.decode()] = {'gitMode': mode.decode(), 'gitBlob': blob.decode()}
    if indexed != {name: {k: row[k] for k in ('gitMode', 'gitBlob')} for name, row in expected.items()}:
        raise RuntimeError('Lease index does not equal immutable tree')
    STATE['leaseSource'] = actual
    env.pop('GH_TOKEN', None); env.pop('NIM_RUNQUOTA_BOOTSTRAP_TOKEN', None)
    env['SHM_LEASE_SRC'] = str(lease / 'src')
    env.pop('REPROBUILD_SRC', None)
    for key in ('GCC_EXEC_PREFIX', 'COMPILER_PATH', 'LIBRARY_PATH', 'CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH'):
        if env.get(key): raise RuntimeError('Inherited compiler search authority refused')
    library_roots = sorted({name.split('/')[1] for name in POLICY['runquota'] if name.startswith('libs/') and '/src/' in name})
    paths = ['--path:' + str(daemon_source / 'libs' / name / 'src') for name in library_roots]
    paths.append('--path:' + str(lease / 'src'))
    daemon = OWNED / 'runquotad.exe'
    child('daemon-compile', [str(nim), 'c', '--skipUserCfg', '--skipParentCfg', '--skipProjCfg', '--threads:on', '-d:release', '--lib:' + str(nim_root / 'lib'), '--gcc.exe:' + str(gcc), '--gcc.linkerexe:' + str(gcc), '--nimcache:' + str(OWNED / 'nimcache'), '--out:' + str(daemon), *paths, 'apps/runquotad/runquotad.nim'], daemon_source, env)
    STATE['daemon'] = file_identity(daemon)
    pe64(daemon)
    STATE['daemonVersion'] = child('daemon-version', [str(daemon), '--version'], OWNED, env)
    if file_identity(daemon) != STATE['daemon']: raise RuntimeError('Daemon image changed through version probe')
    whole_files(daemon_source, POLICY['runquota'])
    unchanged_package('gcc'); unchanged_package('nim')
    if whole_files(lease, expected, git_metadata=True) != actual or subprocess.check_output([str(git), '-C', str(lease), 'ls-files', '--stage', '-z'], env=metadata_env) != lease_index:
        raise RuntimeError('Changed lease source/index')
    STATE['leaseIndexSHA'] = hashlib.sha256(lease_index).hexdigest()
    if whole_files(source, POLICY['runquota']) != source_before or whole_files(public.parent, POLICY['releaseBin']) != release_bin:
        raise RuntimeError('Changed release source/runtime')
    for path, expected in STATE['principals'].items():
        if file_identity(path) != expected: raise RuntimeError('Changed bootstrap principal')
    for name, expected in helpers_before.items():
        if file_identity(actions / name) != expected: raise RuntimeError('Changed authentication helper')
    STATE['owningAfter'] = owning(git)
    if STATE['owningAfter'] != STATE['owningBefore']: raise RuntimeError('Changed owning source/index/event')
    for path, expected in STATE['compilerImages'].items():
        if file_identity(path) != expected: raise RuntimeError('Changed bootstrap compiler image')
    verify_directories(); STATE['success'] = True
    return backend, daemon

if __name__ == '__main__':
    result = None
    try: result = main()
    except BaseException as error:
        STATE['failure'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        if 'RECEIPT_PARENT' in globals():
            try: verify_directories()
            except BaseException as error:
                STATE['success'] = False
                STATE['terminalGuardFailure'] = type(error).__name__ + ': ' + str(error)
            if 'RECEIPT_PARENT' in globals():
                for kernel, handle, path, before, native in HELD[:2]:
                    if directory(path) != before or handle_identity(kernel, handle) != native:
                        raise RuntimeError('Failure receipt parent authority lost; unknown state preserved')
                receipt = RECEIPT_PARENT / ('runquota-bootstrap-' + uuid.uuid4().hex + '.json')
                with receipt.open('x') as out: json.dump(STATE, out, indent=2)
                if result and STATE['success']:
                    if file_identity(result[1]) != STATE['daemon'] or file_identity(result[0]) != STATE['backend']:
                        raise RuntimeError('Daemon/backend image changed before activation')
                    env_path = Path(os.environ['GITHUB_ENV'])
                    if file_identity(env_path) != STATE['githubEnvironmentBefore']:
                        raise RuntimeError('GITHUB_ENV changed before activation')
                    with env_path.open('a', encoding='utf-8') as out:
                        s = os.fstat(out.fileno())
                        if (s.st_dev, s.st_ino) != (STATE['githubEnvironmentBefore']['dev'], STATE['githubEnvironmentBefore']['ino']):
                            raise RuntimeError('Changed environment file identity')
                        out.write('REPRO_FULL_CLI=' + str(result[0]) + '\nRUNQUOTAD_BIN=' + str(result[1]) + '\n')
                        out.flush(); os.fsync(out.fileno())
        for kernel, handle, _, _, _ in reversed(HELD): kernel.CloseHandle(handle)
        if STATE.get('terminalGuardFailure'): raise RuntimeError('Terminal root authority refused; unknown paths preserved')
