"""Execute unchanged original Actions native Git contracts on real platform tools.
No mocked Git/OS or native instrumentation. Git TRACE2 inside the original suite
is application diagnostics. A recorded component verdict never substitutes the
consumer product's original tests or complete promotion gates.
"""
from pathlib import Path
import os, sys, stat, json, hashlib, subprocess, shutil, time, platform, re
PIN = 'acb1123da41eba0f6d6792e7bb65bdbefef813ed'
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
if len(sys.argv) != 3 or sys.argv[1] != 'execute' or sys.argv[2] not in ['x64', 'arm64']:
    raise RuntimeError('Invalid native phase or declared architecture')
claim = json.loads(CLAIM.read_text())
if claim != {'workspace': ROOT_AUTH, 'consumer': CONSUMER_AUTH, 'taskWorkspace': directory(TASK_ROOT), 'target': directory(TARGET), 'controller': SELF}:
    raise RuntimeError('Changed native directory or controller authority')
TOOLS = {n: tool(n) for n in (['bash', 'git'] if sys.platform == 'win32' else ['bash', 'git', 'python3'])}
TOOLS['python-executable'] = tool(sys.executable)
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
