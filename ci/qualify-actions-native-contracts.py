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
signing_home = None
signing_identity = None
signing_fd = None
signing_env = dict(os.environ)
with PROOF.open('x') as f: json.dump(proof, f, indent=2)
try:
    probe = subprocess.check_output([TOOLS['bash']['resolved'], '-c', 'printf "%s\n%s\n" "$BASH_VERSINFO" "$OSTYPE"'], text=True).splitlines()
    if len(probe) != 2 or int(probe[0]) < 4: raise RuntimeError('Unsupported native Bash')
    if sys.platform == 'win32' and not probe[1].startswith(('msys', 'cygwin')):
        raise RuntimeError('Windows Bash is not the native Git shell')
    if sys.platform not in ['win32', 'darwin']: raise RuntimeError('Native channel platform refused')
    proof['bashProbe'] = probe
    if sys.platform == 'darwin':
        # A private repository isolates the real Git init/add/commit/HEAD prerequisite.
        # Match the original suite's default commit policy; do not mask signing failures.
        import tempfile
        # These are real signed fixture commits with a private, disposable key.
        # Indexed Git authorization remains intact; runner signing keys are unused.
        for role in ['gpg', 'gpgconf']:
            TOOLS[role] = tool(role)
        proof['toolsBefore'] = TOOLS
        temp_root = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
        temp_identity = directory(temp_root)
        signing_home = Path(tempfile.mkdtemp(prefix='nim-sign-', dir=temp_root))
        signing_identity = directory(signing_home)
        signing_fd = os.open(signing_home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        signing_stat = os.fstat(signing_fd)
        if signing_stat.st_uid != os.getuid():
            raise RuntimeError('Foreign signing fixture owner')
        if os.path.commonpath([str(signing_home), str(RECEIPTS)]) == str(RECEIPTS):
            raise RuntimeError('Signing keys overlap archived receipts')
        if signing_home.parent != temp_root or not signing_home.name.startswith('nim-sign-'):
            raise RuntimeError('Foreign signing fixture namespace')
        # Darwin sockaddr_un.sun_path is 104 bytes including the terminator.
        # https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/sys/un.h
        # The browser socket is the longest default selector; keep the private
        # unique home short and refuse an overlong runner temp root, never fallback.
        # The workflow archives nim-native-utilities-*/receipt.json and
        # native-runquota-* logs, not this separate private signing prefix.
        proof['fixtureSigning'] = {'home': signing_identity, 'owner': signing_stat.st_uid, 'scope': 'Exclusive private signing namespace outside declared artifact roots'}
        if signing_identity['mode'] != 0o700:
            raise RuntimeError('Signing fixture directory is not private')
        signing_env['GNUPGHOME'] = str(signing_home)
        socket_rows = []
        for role in ['socketdir', 'agent-socket', 'agent-extra-socket', 'agent-browser-socket']:
            witness = subprocess.run([TOOLS['gpgconf']['resolved'], '--homedir', str(signing_home), '--list-dirs', role], env=signing_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            # Only the source-defined directory selector's path is public; stderr is hashed.
            raw_path = witness.stdout.rstrip(b'\r\n')
            if witness.returncode == 0 and (not raw_path or len(raw_path) > 4096 or any(c < 32 or c == 127 for c in raw_path) or re.search(rb'%(?![0-9A-Fa-f]{2})', raw_path)):
                raise RuntimeError('Malformed GnuPG socket selector output')
            if witness.returncode == 0:
                from urllib.parse import unquote_to_bytes
                socket_path_bytes = unquote_to_bytes(raw_path)
                if any(c < 32 or c == 127 for c in socket_path_bytes) or (sys.platform == "darwin" and len(socket_path_bytes) >= 104):
                    raise RuntimeError("Selected signing socket exceeds Darwin path capacity")
            socket_rows.append({'role': role, 'exit': witness.returncode, 'percentEncodedSelector': raw_path.decode(errors='strict') if witness.returncode == 0 else None, 'encodedBytes': len(raw_path), 'stderrSHA256': hashlib.sha256(witness.stderr).hexdigest(), 'stderrBytes': len(witness.stderr)})
        proof['fixtureSigning']['socketDirectories'] = socket_rows
        # Capture only the agent diagnostic channel in this private disposable home.
        # GnuPG 2.4.9 agent/gpg-agent.c oLogFile supports this without debug output.
        agent_log = signing_home / "agent-diagnostic.log"
        with agent_log.open("xb") as log:
            os.fchmod(log.fileno(), 0o600)
            agent_log_stat = os.fstat(log.fileno())
        if any(c in str(agent_log) for c in "\r\n\x00"):
            raise RuntimeError("Invalid private diagnostic path")
        with (signing_home / "gpg-agent.conf").open("x") as config:
            os.chmod(config.name, 0o600)
            config.write("log-file " + str(agent_log) + "\n")
        generate = subprocess.Popen([TOOLS['gpg']['resolved'], '--batch', '--pinentry-mode', 'loopback', '--passphrase', '', '--quick-generate-key', 'NimAgents CI fixture <ci-fixture@invalid>', 'ed25519', 'sign', '1d'], env=signing_env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        _, generation_error = generate.communicate()
        # GnuPG 2.4.9 agent/gpg literals: emit fixed classifications, never stderr text.
        agent_fd = os.open(agent_log, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            agent_stat = os.fstat(agent_fd)
            if (agent_stat.st_dev, agent_stat.st_ino) != (agent_log_stat.st_dev, agent_log_stat.st_ino) or not stat.S_ISREG(agent_stat.st_mode) or agent_stat.st_uid != os.getuid() or stat.S_IMODE(agent_stat.st_mode) != 0o600 or agent_stat.st_size > 65536:
                raise RuntimeError("Foreign or unbounded private agent diagnostic")
            agent_error = os.read(agent_fd, 65537)
            agent_after = os.fstat(agent_fd)
            if len(agent_error) > 65536 or agent_after.st_size > 65536 or agent_after.st_size != len(agent_error) or (agent_after.st_dev, agent_after.st_ino, agent_after.st_uid, agent_after.st_mode, agent_after.st_mtime_ns) != (agent_stat.st_dev, agent_stat.st_ino, agent_stat.st_uid, agent_stat.st_mode, agent_stat.st_mtime_ns):
                raise RuntimeError("Changed or unbounded private agent diagnostic snapshot")
        finally:
            os.close(agent_fd)
        diagnostic_error = generation_error + agent_error
        classifications = {
            'socketNameTooLong': b"socket name '" in diagnostic_error and b"' is too long" in diagnostic_error,
            'socketPreparationFailed': b'error preparing socket' in diagnostic_error,
            'socketCreationFailed': b"can't create socket" in diagnostic_error,
            'socketBindingFailed': b'error binding socket' in diagnostic_error,
        }
        proof['fixtureSigning']['generation'] = {'pid': generate.pid, 'exit': generate.returncode, 'stderrSHA256': hashlib.sha256(generation_error).hexdigest(), 'stderrBytes': len(generation_error), 'classifications': classifications, 'privateAgentLogSHA256': hashlib.sha256(agent_error).hexdigest(), 'privateAgentLogBytes': len(agent_error)}
        if generate.returncode:
            raise RuntimeError('Real fixture signing-key generation failed')
        keys = subprocess.check_output([TOOLS['gpg']['resolved'], '--batch', '--with-colons', '--list-secret-keys'], env=signing_env, stderr=subprocess.DEVNULL).decode().splitlines()
        fingerprints = [row.split(':')[9] for row in keys if row.startswith('fpr:')]
        if len(fingerprints) != 1 or not re.fullmatch(r'[0-9A-F]{40}', fingerprints[0]):
            raise RuntimeError('Signing fixture key is not unique')
        count = signing_env.get('GIT_CONFIG_COUNT', '0')
        if not re.fullmatch(r'0|[1-9][0-9]*', count):
            raise RuntimeError('Malformed indexed Git signing environment')
        n = int(count)
        indexed = {k for k in signing_env if re.fullmatch(r'GIT_CONFIG_(KEY|VALUE)_[0-9]+', k)}
        if indexed != {f'GIT_CONFIG_{role}_{i}' for i in range(n) for role in ['KEY', 'VALUE']}:
            raise RuntimeError('Incomplete indexed Git signing environment')
        for key, value in [('commit.gpgsign', 'true'), ('gpg.format', 'openpgp'), ('gpg.program', TOOLS['gpg']['resolved']), ('user.signingkey', fingerprints[0])]:
            signing_env[f'GIT_CONFIG_KEY_{n}'] = key
            signing_env[f'GIT_CONFIG_VALUE_{n}'] = value
            n += 1
        signing_env['GIT_CONFIG_COUNT'] = str(n)
        if directory(temp_root) != temp_identity or directory(signing_home) != signing_identity:
            raise RuntimeError('Changed signing fixture directory')
        proof['fixtureSigning']['fingerprint'] = fingerprints[0]
        fixture = Path(tempfile.mkdtemp(prefix='native-git-fixture-', dir=RECEIPTS))
        fixtureConfig = subprocess.check_output([TOOLS['git']['resolved'], 'config', '--null', '--show-origin', '--show-scope', '--list'], cwd=TARGET, env=signing_env)
        for label, args in [('init', ['init', '-b', 'main', str(fixture)]), ('add', ['-C', str(fixture), 'add', 'README']), ('commit', ['-C', str(fixture), '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'init']), ('head', ['-C', str(fixture), 'rev-parse', 'HEAD']), ('verify-signature', ['-C', str(fixture), 'verify-commit', 'HEAD']), ('signer-fingerprint', ['-C', str(fixture), 'log', '-1', '--format=%GF'])]:
            if label == 'add': (fixture / 'README').write_text('genuine native Git fixture\n')
            out = RECEIPTS / ('fixture-' + label + '.stdout'); err = RECEIPTS / ('fixture-' + label + '.stderr')
            with out.open('xb') as stdout, err.open('xb') as stderr:
                child = subprocess.Popen([TOOLS['git']['resolved'], *args], cwd=TARGET, stdout=stdout, stderr=stderr, env=signing_env)
                status = child.wait()
            proof.setdefault('fixtureRows', []).append({'stage': label, 'pid': child.pid, 'exit': status, 'stdout': identity(out), 'stderr': identity(err), 'scope': 'Owned direct-child natural wait only'})
            if fixtureConfig != subprocess.check_output([TOOLS['git']['resolved'], 'config', '--null', '--show-origin', '--show-scope', '--list'], cwd=TARGET, env=signing_env): raise RuntimeError('Changed caller Git configuration')
            if status: raise RuntimeError('Original native Git fixture prerequisite failed')
            if label == 'signer-fingerprint' and out.read_text().strip() != fingerprints[0]:
                raise RuntimeError('Fixture commit has a foreign signing fingerprint')
    for name in ['authenticated-clone-test.sh', 'longpaths-test.sh']:
        if source() != BEFORE or {n: tool(v['lexical']) for n, v in TOOLS.items()} != TOOLS:
            raise RuntimeError('Changed native source or tool before suite')
        out = RECEIPTS / (name + '.stdout'); err = RECEIPTS / (name + '.stderr')
        with out.open('xb') as stdout, err.open('xb') as stderr:
            child = subprocess.Popen([TOOLS['bash']['resolved'], 'git-auth/' + name], cwd=TARGET, stdout=stdout, stderr=stderr, env=dict(signing_env, MCL_TEST_PYTHON_EXECUTABLE=Path(TOOLS['python-executable']['resolved']).as_posix(), PYTHONDONTWRITEBYTECODE='1'))
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
    if signing_home is not None:
        try:
            if signing_identity is None:
                raise RuntimeError('Unconfirmed signing directory retained; no key generation occurred')
            current_stat = signing_home.lstat()
            if directory(signing_home) != signing_identity or current_stat.st_uid != os.getuid():
                raise RuntimeError('Changed owned signing fixture before cleanup')
            held_stat = os.fstat(signing_fd)
            if (current_stat.st_dev, current_stat.st_ino) != (held_stat.st_dev, held_stat.st_ino):
                raise RuntimeError('Replaced signing fixture directory')
            stopped = subprocess.run([TOOLS['gpgconf']['resolved'], '--homedir', str(signing_home), '--kill', 'gpg-agent'], env=signing_env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            if stopped.returncode:
                raise RuntimeError('Owned signing fixture agent cleanup failed')
            shutil.rmtree(signing_home)
            proof.setdefault('fixtureSigning', {})['cleaned'] = True
        except Exception as error:
            proof['success'] = False
            proof['signingCleanupError'] = {'type': type(error).__name__, 'message': str(error)}
        finally:
            if signing_fd is not None:
                os.close(signing_fd)
    PROOF.write_text(json.dumps(proof, indent=2) + '\n')
raise SystemExit(0 if proof['success'] else 1)
