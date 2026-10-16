"""Observe the unchanged constructor; counters alone do not assign its kill cause.

The Nix daemon/builder may have a different cgroup from this direct child. No
environment, command line, kernel log, or arbitrary process inventory is read.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

EVENTS = {"low", "high", "max", "oom", "oom_kill", "oom_group_kill"}
MEMORY = {"MemTotal", "MemAvailable", "SwapTotal", "SwapFree"}


def bounded(path, limit=4096):
    with open(path, "rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError("oversize selected counter")
    return data.decode("ascii")


def natural(value):
    if not value.isascii() or not value.isdecimal() or len(value) > 24:
        raise ValueError("malformed selected counter")
    return int(value)


def memory():
    result = {}
    for line in bounded("/proc/meminfo", 16384).splitlines():
        key, value = line.split(":", 1)
        if key in MEMORY:
            amount, unit = value.split()
            if unit != "kB":
                raise ValueError("unexpected memory unit")
            result[key] = natural(amount) * 1024
    if set(result) != MEMORY:
        raise ValueError("missing selected memory counter")
    return result


def cgroup(pid):
    # Read only this observer or its direct child, never other process metadata.
    birth_before = bounded(f"/proc/{pid}/stat").rsplit(")", 1)[1].split()[19]
    rows = bounded(f"/proc/{pid}/cgroup").splitlines()
    birth_after = bounded(f"/proc/{pid}/stat").rsplit(")", 1)[1].split()[19]
    if birth_before != birth_after:
        raise ValueError("process identity changed")
    unified = [line[3:] for line in rows if line.startswith("0::")]
    if len(unified) != 1:
        raise ValueError("unified cgroup unavailable")
    relative = unified[0]
    if not relative.startswith("/") or ".." in relative.split("/"):
        raise ValueError("invalid cgroup membership")
    root = Path("/sys/fs/cgroup")
    path = root / relative.lstrip("/")
    if root.resolve() not in [path.resolve(), *path.resolve().parents]:
        raise ValueError("foreign cgroup namespace")
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    info = os.fstat(fd)
    return fd, {"pathSHA256": hashlib.sha256(relative.encode()).hexdigest(),
                "device": info.st_dev, "inode": info.st_ino,
                "processBirth": natural(birth_after)}


def counters(fd):
    result = {}
    for name in ["memory.current", "memory.peak", "memory.max", "memory.swap.max"]:
        try:
            value = bounded(f"/proc/self/fd/{fd}/{name}").strip()
            result[name] = "max" if value == "max" else natural(value)
        except FileNotFoundError:
            result[name] = None
    result["memory.events"] = {}
    for line in bounded(f"/proc/self/fd/{fd}/memory.events").splitlines():
        key, value = line.split()
        if key in EVENTS:
            result["memory.events"][key] = natural(value)
    return result


def observe(command, receipt, identity):
    output = os.open(receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    proof = {"constructor": identity, "builderCgroupObserved": False,
              "killCauseEstablished": False, "finished": False}
    held = []
    def save():
        data = (json.dumps(proof, indent=2) + "\n").encode()
        os.lseek(output, 0, os.SEEK_SET)
        pending = memoryview(data)
        while pending:
            pending = pending[os.write(output, pending):]
        os.ftruncate(output, len(data))
        os.fsync(output)
    def snapshot(pid, label):
        fd = None
        try:
            fd, group = cgroup(pid)
            before = counters(fd)
            held.append((label, fd, group))
            fd = None
            proof[label] = {"identity": group, "before": before}
        except (OSError, ValueError, IndexError):
            proof[label] = {"unavailable": True}
        finally:
            if fd is not None:
                os.close(fd)
    try:
        proof["memoryBefore"] = memory()
        snapshot(os.getpid(), "observer")
        save()
        child = subprocess.Popen(command)
        proof["directChildPID"] = child.pid
        try:
            snapshot(child.pid, "directChild")
            save()
        except (OSError, ValueError, IndexError, KeyError, TypeError):
            proof["observerFailure"] = True
        finally:
            # Every observer exception after launch still drains this exact child.
            status = child.wait()  # No deadline, polling timer, or termination.
        proof["returnCode"] = status
        proof["directChildSignal"] = -status if status < 0 else None
        proof["shellExitCode"] = 128 - status if status < 0 else status
        try:
            proof["memoryAfter"] = memory()
            for label, fd, group in held:
                info = os.fstat(fd)
                if (info.st_dev, info.st_ino) != (group["device"], group["inode"]):
                    raise ValueError("held cgroup identity changed")
                after = counters(fd)
                proof[label]["after"] = after
                before = proof[label]["before"]["memory.events"]
                increments = {key: after["memory.events"][key] - value for key, value in before.items()
                              if key in after["memory.events"]}
                if any(value < 0 for value in increments.values()):
                    raise ValueError("cgroup counters decreased")
                proof[label]["eventIncrements"] = increments
        except (OSError, ValueError, IndexError):
            # Diagnostic refusal never masks the original constructor failure.
            proof["afterCountersUnavailable"] = True
            if status == 0:
                proof["shellExitCode"] = 1
        if proof.get("observerFailure") and status == 0:
            proof["shellExitCode"] = 1
        proof["finished"] = True
        try:
            save()
        except (OSError, ValueError, TypeError):
            print("Constructor witness persistence failed; direct child exit retained", file=sys.stderr)
            if status == 0:
                proof["shellExitCode"] = 1
        return proof["shellExitCode"]
    finally:
        for _, fd, _ in held:
            os.close(fd)
        os.close(output)


if __name__ == "__main__":
    nix, receipt = sys.argv[1:]
    if not Path(nix).is_absolute() or not Path(nix).is_file():
        raise ValueError("invalid existing Nix executable")
    drv = subprocess.check_output([nix, "eval", "--raw", ".#ci-managed-hook-constructor.drvPath"], text=True).strip()
    out = subprocess.check_output([nix, "eval", "--raw", ".#ci-managed-hook-constructor.outPath"], text=True).strip()
    if not drv.startswith("/nix/store/") or not drv.endswith(".drv") or not out.startswith("/nix/store/"):
        raise ValueError("invalid declared constructor identity")
    print(drv, flush=True)
    identity = {"SDKRevision": "064daf5b154ea6a0758ddb2dcbcbc07685216e44",
                "derivation": drv, "output": out,
                "nixImageSHA256": hashlib.sha256(Path(nix).read_bytes()).hexdigest()}
    command = [nix, "build", ".#ci-managed-hook-constructor", "--no-link", "--max-jobs", "1", "--print-build-logs", "--print-out-paths"]
    raise SystemExit(observe(command, receipt, identity))
