# Confined native installer adapter; ordinary factory/tool calls forward unchanged.
import json, os, pathlib, stat, subprocess, sys
binary, git_exe = sys.argv[1:3]
arguments = sys.argv[3:]
key = "NIM_AGENTS_NATIVE_DIRECTORY_AUTHORITY"
encoded = os.environ.get(key)
if encoded is None:
    os.execv(binary, [binary, *arguments])
def refuse(message):
    raise SystemExit("Native directory authority refused: " + message)
try:
    authority = json.loads(encoded)
    if set(authority) != {"root", "common", "hooks", "root_stat", "common_stat", "hooks_stat"}:
        refuse("unknown authority fields")
    root, common, hooks = (pathlib.Path(authority[k]) for k in ("root", "common", "hooks"))
    for path in (root, common, hooks):
        if not path.is_absolute() or path.resolve() != path:
            refuse("noncanonical or symlink directory")
        if not stat.S_ISDIR(path.lstat().st_mode):
            refuse("non-directory authority")
    if pathlib.Path.cwd().resolve() != root or hooks != common / "hooks":
        refuse("foreign root or hooks directory")
    def directory(path):
        info = path.lstat()
        return [info.st_dev, info.st_ino, stat.S_IMODE(info.st_mode)]
    def query(*args):
        return subprocess.check_output([git_exe, "-C", str(root), *args], text=True).rstrip("\n")
    if query("rev-parse", "--show-toplevel") != str(root):
        refuse("changed repository")
    if query("rev-parse", "--path-format=absolute", "--git-common-dir") != str(common):
        refuse("changed common directory")
    if directory(root) != authority["root_stat"] or directory(common) != authority["common_stat"] or directory(hooks) != authority["hooks_stat"]:
        refuse("changed directory identity")
    if not arguments or arguments[0] not in ("install", "uninstall"):
        refuse("unexpected native operation")
    if any(arg == "--git-dir" or arg.startswith("--git-dir=") for arg in arguments):
        refuse("foreign explicit target")
except (KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
    refuse(type(error).__name__)
os.execv(binary, [binary, arguments[0], "--git-dir", str(common), *arguments[1:]])
