"""Exact initial Git-producer transition; no mocks or persistent hook admission.

Prepare is read-only for the subject. Apply authenticates complete prepared and
subject inventories before every replace and before any rollback. The phases
also permit real filesystem-limit failure controls without mock replacements.
"""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time

SELECTED = Path(sys.argv[1])
CAPTURE_SOURCE_SHA = sys.argv[2]
FLAKE_SOURCE_SHA = sys.argv[3]
ARGS = sys.argv[4:]
REFUSED_ENV = (
    "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_TEMPLATE_DIR",
    "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "NIM_AGENTS_NATIVE_DIRECTORY_AUTHORITY",
)


def require(condition, diagnostic):
    if not condition:
        raise RuntimeError(diagnostic)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def regular(path):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode), "Unknown nonregular file authority: " + str(path))
    return {"mode": stat.S_IMODE(info.st_mode), "sha": digest(path.read_bytes())}


def directories(root, common, hooks):
    result = {}
    for name, path in [("root", root), ("common", common), ("hooks", hooks)]:
        info = path.lstat()
        require(stat.S_ISDIR(info.st_mode), "Unknown directory authority: " + name)
        result[name] = {"path": str(path), "dev": info.st_dev, "ino": info.st_ino,
                        "mode": stat.S_IMODE(info.st_mode)}
    return result


def git(tool, root, *args):
    return subprocess.check_output([str(tool), "--no-optional-locks", "-C", str(root), *args],
                                    env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))


def refuse_configuration(tool, root):
    for key in ["core.hooksPath", "init.templateDir"]:
        result = subprocess.run([str(tool), "--no-optional-locks", "-C", str(root),
                                  "config", "--get", key], stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
        require(result.returncode == 1, "Configured Git authority refused: " + key)


def source_census(tool, root):
    indexed = git(tool, root, "ls-files", "--stage", "-z")
    data = bytearray()
    for row in indexed.split(b"\0"):
        if not row:
            continue
        fields, name = row.split(b"\t", 1)
        require(fields.split()[-1] == b"0", "Unmerged source index refused")
        path = root / os.fsdecode(name)
        info = path.lstat()
        kind = fields.split()[0]
        if kind == b"120000":
            require(stat.S_ISLNK(info.st_mode), "Changed source link kind")
            body = os.fsencode(os.readlink(path)) + b"\0"
        else:
            require(kind in [b"100644", b"100755"] and stat.S_ISREG(info.st_mode),
                    "Unknown tracked source kind")
            body = path.read_bytes()
        data.extend(row + b"\0" + format(stat.S_IMODE(info.st_mode), "o").encode() +
                    b"\0" + digest(body).encode() + b"\0")
    return digest(data)


def hook_inventory(hooks):
    return {p.name: regular(p) for p in sorted(hooks.iterdir())}


def state(tool, root):
    common = Path(os.fsdecode(git(tool, root, "rev-parse", "--path-format=absolute",
                                  "--git-common-dir")).strip())
    require(common == root / ".git", "Ordinary checkout required")
    hooks = common / "hooks"
    effective = Path(os.fsdecode(git(tool, root, "rev-parse", "--path-format=absolute",
                                    "--git-path", "hooks")).strip())
    require(effective == hooks, "Foreign effective hook path refused")
    refuse_configuration(tool, root)
    return {"head": git(tool, root, "rev-parse", "HEAD").decode().strip(),
            "source_sha": source_census(tool, root),
            "index_sha": digest((common / "index").read_bytes()),
            "config_sha": digest((common / "config").read_bytes()),
            "directories": directories(root, common, hooks), "hooks": hook_inventory(hooks)}


def tree_inventory(root):
    result = {}
    for path in sorted(root.rglob("*")):
        info = path.lstat()
        name = str(path.relative_to(root))
        if stat.S_ISDIR(info.st_mode):
            result[name] = {"directory_mode": stat.S_IMODE(info.st_mode)}
        else:
            result[name] = regular(path)
    return result


def session_members(sid):
    live, unknown = [], []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
            if fields[0] != "Z" and int(fields[3]) == sid:
                live.append(entry.name)
        except (FileNotFoundError, ProcessLookupError):
            continue
        except (PermissionError, ValueError, IndexError) as error:
            unknown.append([entry.name, type(error).__name__])
    return live, unknown


def initialize(tool, templates, destination):
    record = {"argv": [str(tool), "init", "--template=" + str(templates), str(destination)]}
    child = None
    try:
        child = subprocess.Popen(record["argv"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  start_new_session=True, env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
        record["pid_sid"] = child.pid
        try:
            record["birth"] = Path("/proc", str(child.pid), "stat").read_text().rsplit(")", 1)[1].split()[19]
        except (FileNotFoundError, ProcessLookupError):
            require(child.poll() is not None, "Missing live owned process identity")
        out, err = child.communicate()
        record.update(exit=child.returncode, stdout_sha=digest(out), stderr_sha=digest(err))
        require(child.returncode == 0, "Actual Git initialization failed")
    finally:
        if child is not None:
            while child.poll() is None:
                try:
                    child.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    pass
            while True:
                live, unknown = session_members(child.pid)
                require(not unknown, "Unknown owned session census")
                if not live:
                    break
                time.sleep(0.05)
            record["natural_sid_empty"] = True
    return record


def read_sample_table(path):
    result = {}
    for line in path.read_text().splitlines():
        name, mode, body = line.split("\t")
        require(name not in result and name.endswith(".sample") and "/" not in name,
                "Malformed sample receipt")
        require(len(body) == 64 and all(c in "0123456789abcdef" for c in body), "Malformed digest")
        result[name] = {"mode": int(mode, 8), "sha": body}
    require(len(result) == 14, "Complete fourteen-member producer required")
    return result


def prepare(receipt):
    require(receipt.is_absolute() and not receipt.is_symlink(), "Foreign receipt path refused")
    root = Path((receipt / "own-root.txt").read_text().strip())
    require(root == Path.cwd(), "Foreign caller root refused")
    require(regular(root / "flake.nix")["sha"] == FLAKE_SOURCE_SHA, "Foreign owning flake source")
    require(root.is_absolute() and receipt.parent == root / ".repro", "Foreign receipt destination")
    capture_source = root / "ci/capture-checkout-git-templates.sh"
    require(regular(capture_source)["sha"] == CAPTURE_SOURCE_SHA, "Capture source authority changed")
    creator = Path((receipt / "git-image.txt").read_text().strip())
    require(creator.is_absolute() and str(creator).startswith("/nix/store/") and
            str(creator).endswith("/bin/git"), "Foreign creator image refused")
    require(os.access(creator, os.X_OK) and regular(creator)["sha"] ==
            (receipt / "git-image.sha256").read_text().split()[0], "Creator image changed")
    initial = state(creator, root)
    require(not git(creator, root, "status", "--porcelain=v1", "--untracked-files=no").strip(),
            "Dirty tracked source refused")
    for field, file in [("head", "source-head.txt"), ("source_sha", "tracked-source.sha256"),
                        ("index_sha", "index.sha256"), ("config_sha", "config.sha256")]:
        require(initial[field] == (receipt / file).read_text().split()[0], "Captured authority changed: " + field)
    recorded_dirs = {}
    for line in (receipt / "directory-authority.tsv").read_text().splitlines():
        name, path, values = line.split("\t")
        dev, ino, mode = values.split(":")
        recorded_dirs[name] = {"path": path, "dev": int(dev), "ino": int(ino), "mode": int(mode, 8)}
    require(recorded_dirs == initial["directories"], "Captured directory authority changed")
    require(initial["hooks"] == read_sample_table(receipt / "initialized-before.tsv"),
            "Captured initial sample inventory changed")
    prepared = Path(tempfile.mkdtemp(prefix="ci-samples-prepared-", dir=receipt.parent))
    proof = {"root": str(root), "receipt": str(receipt), "initial": initial,
              "receipt_inventory": tree_inventory(receipt), "commands": [],
              "prepared_directory": directories(prepared, prepared, prepared)["root"],
              "capture_source_sha": CAPTURE_SOURCE_SHA,
              "script_sha": digest(Path(__file__).read_bytes()), "principals": {},
              "creator_git": str(creator), "flake_source_sha": FLAKE_SOURCE_SHA}
    for label, tool in [("creator", creator), ("selected", SELECTED)]:
        require(tool.is_absolute() and str(tool).startswith("/nix/store/") and
                str(tool).endswith("/bin/git") and os.access(tool, os.X_OK), "Foreign Git principal")
        proof["principals"][str(tool)] = regular(tool)
        templates = tool.parent.parent / "share/git-core/templates"
        require(not templates.is_symlink() and not (templates / "hooks").is_symlink(), "Unknown template path")
        raw_before = hook_inventory(templates / "hooks")
        proof["commands"].append(initialize(tool, templates, prepared / label))
        materialized = hook_inventory(prepared / label / ".git/hooks")
        require(len(materialized) == 14 and set(materialized) == set(raw_before), "Incomplete constructor inventory")
        require(all(materialized[n]["sha"] == raw_before[n]["sha"] and
                    materialized[n]["mode"] == raw_before[n]["mode"] | stat.S_IWUSR
                    for n in raw_before), "Unexpected Git materialization body/mode")
        require(hook_inventory(templates / "hooks") == raw_before, "Template source changed across initialization")
        proof[label] = materialized
    require(proof["creator"] == initial["hooks"], "Initial hooks do not match actual creator")
    require(state(creator, root) == initial and tree_inventory(receipt) == proof["receipt_inventory"],
            "State changed during read-only preparation")
    proof["prepared_inventory"] = tree_inventory(prepared)
    with (prepared / "authority.json").open("x") as out:
        json.dump(proof, out, indent=2)
        out.write("\n")
    return prepared, digest((prepared / "authority.json").read_bytes())


def replace_known(hooks, name, body, mode, verify):
    descriptor, temporary = tempfile.mkstemp(prefix=".ci-sample-owned-", dir=hooks)
    path = Path(temporary)
    owned = os.fstat(descriptor)
    try:
        with os.fdopen(descriptor, "wb") as out:
            out.write(body)
            out.flush()
            os.fchmod(out.fileno(), mode)
            current = os.fstat(out.fileno())
        require(current.st_dev == owned.st_dev and current.st_ino == owned.st_ino,
                "Owned temporary inode changed")
        require(path.lstat().st_dev == owned.st_dev and path.lstat().st_ino == owned.st_ino and
                regular(path) == {"mode": mode, "sha": digest(body)}, "Unknown temporary postimage")
        verify(path.name)
        os.replace(path, hooks / name)
    finally:
        if path.exists() or path.is_symlink():
            info = path.lstat()
            known_identity = stat.S_ISREG(info.st_mode) and info.st_dev == owned.st_dev and info.st_ino == owned.st_ino
            actual = path.read_bytes() if known_identity else None
            if known_identity and len(actual) <= len(body) and actual == body[:len(actual)] and stat.S_IMODE(info.st_mode) in [0o600, mode]:
                path.unlink()
            else:
                raise RuntimeError("Unknown temporary retained without cleanup")


def apply(prepared, authority_sha):
    require(regular(prepared / "authority.json")["sha"] == authority_sha, "Prepared authority changed")
    proof = json.loads((prepared / "authority.json").read_text())
    creator = Path(proof["creator_git"])
    root = Path(proof["root"])
    receipt = Path(proof["receipt"])
    require(root == Path.cwd() and prepared.parent == root / ".repro", "Foreign prepared root refused")
    require(proof["flake_source_sha"] == FLAKE_SOURCE_SHA and regular(root / "flake.nix")["sha"] == FLAKE_SOURCE_SHA, "Prepared flake authority changed")
    hooks = root / ".git/hooks"
    initial = proof["initial"]
    changed = []
    result = {"success": False, "changed": changed, "prepared": str(prepared), "mutations": []}

    def verify(temporary=None):
        require(regular(prepared / "authority.json")["sha"] == authority_sha, "Prepared authority changed")
        require(digest(Path(__file__).read_bytes()) == proof["script_sha"] and
                regular(root / "ci/capture-checkout-git-templates.sh")["sha"] == proof["capture_source_sha"],
                "Program source authority changed")
        require(directories(prepared, prepared, prepared)["root"] == proof["prepared_directory"], "Prepared directory changed")
        require(tree_inventory(receipt) == proof["receipt_inventory"], "Receipt authority changed")
        inventory = tree_inventory(prepared)
        inventory.pop("authority.json", None)
        require(inventory == proof["prepared_inventory"], "Prepared backup/constructor authority changed")
        require(all(regular(Path(k)) == v for k, v in proof["principals"].items()), "Git principal changed")
        current = state(creator, root)
        expected = dict(initial)
        expected["hooks"] = dict(initial["hooks"])
        for name in changed:
            expected["hooks"][name] = proof["selected"][name]
        if temporary:
            current["hooks"].pop(temporary, None)
        require(current == expected, "Unknown source/index/config/hooks/directory postimage")

    try:
        current = state(creator, root)
        if current["hooks"] == proof["selected"]:
            changed.extend(sorted(proof["selected"]))
            verify()
            result.update(success=True, reentry=True, after=current)
            return result
        verify()
        for name in sorted(proof["selected"]):
            entry = proof["selected"][name]
            body = (prepared / "selected/.git/hooks" / name).read_bytes()
            replace_known(hooks, name, body, entry["mode"], verify)
            changed.append(name)
            result["mutations"].append({"phase": "replace", "name": name, "identity": regular(hooks / name)})
            verify()
        result.update(success=True, after=state(creator, root))
    except BaseException as error:
        result["error"] = repr(error)
        try:
            verify()  # WHOLE authority preflight before the first restoration write.
            for name in reversed(changed.copy()):
                entry = proof["creator"][name]
                body = (prepared / "creator/.git/hooks" / name).read_bytes()
                replace_known(hooks, name, body, entry["mode"], verify)
                changed.remove(name)
                result["mutations"].append({"phase": "restore", "name": name, "identity": regular(hooks / name)})
                verify()
            result["rollback_exact"] = state(creator, root) == initial
        except BaseException as rollback_error:
            result["rollback_refused"] = repr(rollback_error)
    return result


require(sys.platform.startswith("linux"), "Linux-only preparation capability")
for name in REFUSED_ENV:
    require(not os.environ.get(name), "Inherited authority refused: " + name)
require(len(ARGS) in [1, 2, 3], "Invalid preparation arguments")
if len(ARGS) == 2 and ARGS[0] == "--prepare":
    context, authority_sha = prepare(Path(ARGS[1]).absolute())
    print(json.dumps({"success": True, "prepared": str(context), "authority_sha": authority_sha}))
elif len(ARGS) == 3 and ARGS[0] == "--apply":
    outcome = apply(Path(ARGS[1]).absolute(), ARGS[2])
    print(json.dumps(outcome))
    sys.exit(0 if outcome["success"] else 1)
else:
    require(len(ARGS) == 1, "Unknown preparation phase")
    context, authority_sha = prepare(Path(ARGS[0]).absolute())
    outcome = apply(context, authority_sha)
    print(json.dumps(outcome))
    sys.exit(0 if outcome["success"] else 1)
