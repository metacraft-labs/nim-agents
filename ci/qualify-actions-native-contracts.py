"""Execute unchanged original Actions native Git contracts on real platform tools.
No mocked Git/OS or native instrumentation. Git TRACE2 inside the original suite
is application diagnostics. A recorded component verdict never substitutes the
consumer product's original tests or complete promotion gates.
"""
from pathlib import Path
import os, sys, stat, json, hashlib, subprocess, shutil, time, platform, re
PIN = '440187b477282220f1c4a8432b77b6d06f2a7146'
NAME = '.ci-actions-native-contracts'
ROOT = Path(os.environ['GITHUB_WORKSPACE']).absolute()
CONSUMER = Path.cwd().absolute()
NAMESPACE = os.environ['NIM_CI_NAMESPACE']
if not re.fullmatch(r'declared-ci-[0-9]+-[0-9]+-[A-Za-z0-9_-]+-[0-9]+', NAMESPACE):
    raise RuntimeError('Foreign task namespace')
TASK_ROOT = ROOT / NAMESPACE
TARGET = TASK_ROOT / NAME
RECEIPTS = CONSUMER / '.repro' / 'actions-native-contracts'
def identity(p):
    p = Path(p); s = p.lstat()
    value = {'path': str(p), 'type': stat.S_IFMT(s.st_mode), 'mode': stat.S_IMODE(s.st_mode), 'dev': s.st_dev, 'ino': s.st_ino}
    if stat.S_ISLNK(s.st_mode):
        value['link'] = os.readlink(p)
    elif stat.S_ISREG(s.st_mode):
        value['sha256'] = hashlib.sha256(p.read_bytes()).hexdigest()
        value['bytes'] = s.st_size
    elif not stat.S_ISDIR(s.st_mode):
        raise RuntimeError('Unsupported file type')
    if getattr(s, 'st_file_attributes', 0) & 0x400:
        raise RuntimeError('Reparse authority refused')
    return value

def directory(p):
    v = identity(p)
    if v['type'] != stat.S_IFDIR or p.resolve() != p:
        raise RuntimeError('Foreign directory authority')
    return v

def mkdir(p):
    try: p.mkdir()
    except FileExistsError: directory(p)
    return directory(p)

def metadata_environment():
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull, GIT_OPTIONAL_LOCKS='0', GIT_NO_REPLACE_OBJECTS='1')
    return env

def git(*args):
    return subprocess.check_output([TOOLS['git']['resolved'], '-C', str(TARGET), *args], env=metadata_environment())

def tool(name):
    lexical = shutil.which(name)
    if not lexical: raise RuntimeError('Missing native tool: ' + name)
    resolved = str(Path(lexical).resolve())
    if identity(resolved)['type'] != stat.S_IFREG: raise RuntimeError('Foreign native executable')
    return {'lexical': lexical, 'resolved': resolved, 'lexicalIdentity': identity(lexical), 'resolvedIdentity': identity(resolved)}

def source():
    if git('rev-parse', 'HEAD').decode().strip() != PIN:
        raise RuntimeError('Wrong published Actions source')
    index = git('ls-files', '--stage', '-z')
    tree = git('ls-tree', '-r', '-z', PIN)
    expected = {}
    for raw in tree.split(b'\0'):
        if not raw: continue
        header, name = raw.split(b'\t', 1)
        mode, kind, oid = header.split()
        if kind != b'blob': raise RuntimeError('Unsupported pinned source entry')
        expected[name] = (mode, oid)
    actual_index = {}
    tracked = {}
    for raw in index.split(b'\0'):
        if not raw: continue
        header, name = raw.split(b'\t', 1)
        mode, oid, stage = header.split()
        if stage != b'0': raise RuntimeError('Unmerged Actions source')
        actual_index[name] = (mode, oid)
        n = os.fsdecode(name); p = TARGET / n
        v = identity(p)
        body = os.readlink(p).encode() if p.is_symlink() else p.read_bytes()
        if body != git('cat-file', 'blob', oid.decode()):
            raise RuntimeError('Checkout bytes differ from published blob: ' + n)
        tracked[n] = v
    if actual_index != expected: raise RuntimeError('Index differs from pinned source tree')
    actual = {p.relative_to(TARGET).as_posix() for p in TARGET.rglob('*') if '.git' not in p.relative_to(TARGET).parts and not p.is_dir()}
    if actual != set(tracked): raise RuntimeError('Unknown Actions worktree entry')
    return {'head': PIN, 'index': index.hex(), 'pinnedTree': tree.hex(), 'entries': tracked, 'root': directory(TARGET), 'gitConfig': identity(TARGET / '.git/config'), 'gitDirectory': directory(TARGET / '.git')}

ROOT_AUTH = directory(ROOT)
CONSUMER_AUTH = directory(CONSUMER)
if os.path.commonpath([str(ROOT), str(CONSUMER)]) != str(ROOT):
    raise RuntimeError('Consumer escapes physical workspace')
SELF = identity(Path(__file__).absolute())
mkdir(CONSUMER / '.repro'); mkdir(RECEIPTS)
CLAIM = RECEIPTS / 'claim.json'
if sys.argv[1:] == ['prepare']:
    # Atomic mkdir refuses existing/dangling/raced destination, without deletion.
    if sys.platform == 'win32':
        TASK_ROOT.mkdir()
    elif CONSUMER.parent != TASK_ROOT:
        raise RuntimeError('Consumer is not in the declared task workspace')
    directory(TASK_ROOT)
    TARGET.mkdir()
    claim = {'workspace': ROOT_AUTH, 'consumer': CONSUMER_AUTH, 'taskWorkspace': directory(TASK_ROOT), 'target': directory(TARGET), 'controller': SELF}
    with CLAIM.open('x') as f: json.dump(claim, f, indent=2)
    raise SystemExit(0)
if len(sys.argv) != 3 or sys.argv[1] not in ['checkout', 'execute'] or sys.argv[2] not in ['x64', 'arm64']:
    raise RuntimeError('Invalid native phase or declared architecture')
claim = json.loads(CLAIM.read_text())
def verify_claim():
    if claim != {'workspace': directory(ROOT), 'consumer': directory(CONSUMER), 'taskWorkspace': directory(TASK_ROOT), 'target': directory(TARGET), 'controller': identity(Path(__file__).absolute())}:
        raise RuntimeError('Changed native directory or controller authority')
verify_claim()
TOOLS = {n: tool(n) for n in ['bash', 'git']}
TOOLS['python-executable'] = tool(sys.executable)
if sys.argv[1] == 'checkout':
    if any(TARGET.iterdir()): raise RuntimeError('Occupied claimed checkout')
    env = dict(os.environ)
    forbidden = ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_TEMPLATE_DIR', 'GIT_CONFIG']
    if any(k in env for k in forbidden): raise RuntimeError('Inherited checkout authority refused')
    count = env.get('GIT_CONFIG_COUNT', '0')
    if not re.fullmatch(r'0|[1-9][0-9]*', count): raise RuntimeError('Invalid command configuration count')
    n = int(count)
    indexed = {k for k in env if re.fullmatch(r'GIT_CONFIG_(KEY|VALUE)_[0-9]+', k)}
    if indexed != {f'GIT_CONFIG_{role}_{i}' for i in range(n) for role in ['KEY', 'VALUE']}:
        raise RuntimeError('Incomplete command configuration')
    token = env.pop('NIM_NATIVE_CHECKOUT_TOKEN', '')
    if not token or any(c in token for c in '\r\n'): raise RuntimeError('Missing checkout token')
    import base64
    key = 'http.https://github.com/metacraft-labs/.extraHeader'
    value = 'AUTHORIZATION: basic ' + base64.b64encode(('x-access-token:' + token).encode()).decode()
    from urllib.parse import urlsplit
    if 'extraheader' in env.get('GIT_CONFIG_PARAMETERS', '').lower():
        raise RuntimeError('Unsupported parameter header authority')
    found = 0
    for i in range(n):
        k, v = env[f'GIT_CONFIG_KEY_{i}'], env[f'GIT_CONFIG_VALUE_{i}']
        if not k.lower().endswith('.extraheader'):
            continue
        if not re.match(r'^\s*authorization\s*:', v, re.IGNORECASE):
            continue
        applicable = k.lower() == 'http.extraheader'
        if k.lower().startswith('http.') and not applicable:
            scope = k[5:-12]
            parsed = urlsplit(scope)
            if '*' in scope or not parsed.scheme or not parsed.hostname:
                raise RuntimeError('Unsupported Authorization URL scope')
            if parsed.hostname.lower() == 'github.com':
                if parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.port:
                    raise RuntimeError('Unsupported GitHub Authorization scope')
                target_path = '/metacraft-labs/metacraft-github-actions'
                applicable = parsed.scheme.lower() == 'https' and (not parsed.path or target_path.startswith(parsed.path.rstrip('/') + '/') or target_path == parsed.path.rstrip('/'))
        if applicable:
            if k != key or v != value:
                raise RuntimeError('Conflicting checkout authorization')
            found += 1
    if found > 1: raise RuntimeError('Duplicate checkout authorization')
    if not found:
        env[f'GIT_CONFIG_KEY_{n}'] = key; env[f'GIT_CONFIG_VALUE_{n}'] = value; n += 1
    env.update(GIT_CONFIG_COUNT=str(n), GIT_TERMINAL_PROMPT='0', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
    record = {'pin': PIN, 'claim': claim, 'tools': TOOLS, 'success': False, 'steps': []}
    receipt = RECEIPTS / 'checkout.json'
    with receipt.open('x') as f: json.dump(record, f, indent=2)
    try:
        for args in [('init', '--template='), ('-c', 'core.longpaths=true', 'fetch', '--no-tags', '--depth=1', 'https://github.com/metacraft-labs/metacraft-github-actions', PIN)]:
            verify_claim()
            if {role: tool(v['lexical']) for role, v in TOOLS.items()} != TOOLS: raise RuntimeError('Changed checkout tools')
            result = subprocess.run([TOOLS['git']['resolved'], '-C', str(TARGET), *args], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            record['steps'].append({'operation': args[0], 'exit': result.returncode})
            if result.returncode: raise RuntimeError('Native checkout Git operation failed')
        if git('rev-parse', 'FETCH_HEAD').decode().strip() != PIN: raise RuntimeError('Wrong fetched object')
        result = subprocess.run([TOOLS['git']['resolved'], '-C', str(TARGET), 'checkout', '--detach', PIN], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode: raise RuntimeError('Native checkout detach failed')
        record['source'] = source(); verify_claim(); record['success'] = True
    except Exception as error:
        record['error'] = {'type': type(error).__name__, 'message': str(error)}
    finally:
        try:
            verify_claim()
            if {role: tool(v['lexical']) for role, v in TOOLS.items()} != TOOLS:
                raise RuntimeError('Changed terminal checkout tools')
        except Exception as error:
            record['success'] = False
            record['finalGuardError'] = {'type': type(error).__name__, 'message': str(error)}
        receipt.write_text(json.dumps(record, indent=2) + '\n')
    raise SystemExit(0 if record['success'] else 1)
BEFORE = source()
proof = {'scope': __doc__, 'platform': sys.platform, 'observedMachine': platform.machine(), 'declaredArchitecture': sys.argv[2], 'toolsBefore': TOOLS, 'sourceBefore': BEFORE, 'claim': claim, 'rows': [], 'success': False}
PROOF = RECEIPTS / 'proof.json'
with PROOF.open('x') as f: json.dump(proof, f, indent=2)
try:
    probe = subprocess.check_output([TOOLS['bash']['resolved'], '-c', 'printf "%s\n%s\n" "$BASH_VERSINFO" "$OSTYPE"'], text=True).splitlines()
    if len(probe) != 2 or int(probe[0]) < 4: raise RuntimeError('Unsupported native Bash')
    if sys.platform == 'win32' and not probe[1].startswith(('msys', 'cygwin')):
        raise RuntimeError('Windows Bash is not the native Git shell')
    if sys.platform not in ['win32', 'darwin']: raise RuntimeError('Native channel platform refused')
    proof['bashProbe'] = probe
    if sys.platform == 'darwin':
        # Real original fixture prerequisite; retain commit diagnostics instead of guessing.
        import tempfile
        fixture = Path(tempfile.mkdtemp(prefix='native-git-fixture-', dir=RECEIPTS))
        fixtureConfig = subprocess.check_output([TOOLS['git']['resolved'], 'config', '--null', '--show-origin', '--show-scope', '--list'], cwd=TARGET)
        for label, args in [('init', ['init', '-b', 'main', str(fixture)]), ('add', ['-C', str(fixture), 'add', 'README']), ('commit', ['-C', str(fixture), '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'init']), ('head', ['-C', str(fixture), 'rev-parse', 'HEAD'])]:
            if label == 'add': (fixture / 'README').write_text('genuine native Git fixture\n')
            out = RECEIPTS / ('fixture-' + label + '.stdout'); err = RECEIPTS / ('fixture-' + label + '.stderr')
            with out.open('xb') as stdout, err.open('xb') as stderr:
                child = subprocess.Popen([TOOLS['git']['resolved'], *args], cwd=TARGET, stdout=stdout, stderr=stderr)
                status = child.wait()
            proof.setdefault('fixtureRows', []).append({'stage': label, 'pid': child.pid, 'exit': status, 'stdout': identity(out), 'stderr': identity(err), 'scope': 'Owned direct-child natural wait only'})
            if fixtureConfig != subprocess.check_output([TOOLS['git']['resolved'], 'config', '--null', '--show-origin', '--show-scope', '--list'], cwd=TARGET): raise RuntimeError('Changed caller Git configuration')
            if status: raise RuntimeError('Original native Git fixture prerequisite failed')
    for name in ['authenticated-clone-test.sh', 'longpaths-test.sh']:
        if source() != BEFORE or {n: tool(v['lexical']) for n, v in TOOLS.items()} != TOOLS:
            raise RuntimeError('Changed native source or tool before suite')
        out = RECEIPTS / (name + '.stdout'); err = RECEIPTS / (name + '.stderr')
        with out.open('xb') as stdout, err.open('xb') as stderr:
            child = subprocess.Popen([TOOLS['bash']['resolved'], 'git-auth/' + name], cwd=TARGET, stdout=stdout, stderr=stderr, env=dict(os.environ, MCL_TEST_PYTHON_EXECUTABLE=Path(TOOLS['python-executable']['resolved']).as_posix(), PYTHONDONTWRITEBYTECODE='1'))
            row = {'name': name, 'pid': child.pid, 'scope': 'Owned direct-child natural wait; no descendant census claim'}
            try: pass
            finally: row['exit'] = child.wait()
        row.update(stdout=identity(out), stderr=identity(err), sourceGuard=source() == BEFORE)
        proof['rows'].append(row)
        if row['exit'] != 0 or not row['sourceGuard']: raise RuntimeError('Original native suite failed')
    proof['success'] = True
except Exception as error:
    proof['error'] = {'type': type(error).__name__, 'message': str(error)}
finally:
    try:
        proof['sourceAfter'] = source()
        proof['toolsAfter'] = {n: tool(v['lexical']) for n, v in TOOLS.items()}
        proof['controllerAfter'] = identity(Path(__file__).absolute())
        proof['success'] = proof['success'] and proof['sourceAfter'] == BEFORE and proof['toolsAfter'] == TOOLS and proof['controllerAfter'] == SELF
    except Exception as error:
        proof['success'] = False
        proof['finalGuardError'] = {'type': type(error).__name__, 'message': str(error)}
    PROOF.write_text(json.dumps(proof, indent=2) + '\n')
raise SystemExit(0 if proof['success'] else 1)
