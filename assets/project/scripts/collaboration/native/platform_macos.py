"""macOS file metadata and supervised process execution. Python 3.11+ standard library."""
from __future__ import annotations

import base64
import ctypes
import datetime as dt
import errno
import json
import os
from pathlib import Path
import re
import select
import signal
import stat
import struct
import subprocess
import sys
import threading
import time
import unicodedata


def utc(seconds=None):
    return dt.datetime.fromtimestamp(time.time() if seconds is None else seconds, dt.timezone.utc).isoformat()


def system_library():
    return ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)


def canonical_path(path):
    """Resolve actual stored spelling, including case/Unicode aliases, by inode."""
    if not os.path.isabs(path) or any(x in (".", "..") for x in path.split("/")):
        raise ValueError("Use an absolute path with explicit components")
    current = "/"
    missing = False
    for component in path.split("/")[1:]:
        if not component:
            continue
        candidate = os.path.join(current, component)
        if not missing and os.path.lexists(candidate):
            if os.path.islink(candidate):
                raise ValueError(f"Use the physical path instead of a symbolic link: {candidate}")
            identity = os.stat(candidate)
            matches = []
            for entry in os.scandir(current):
                entry_stat = entry.stat(follow_symlinks=False)
                if (entry_stat.st_dev, entry_stat.st_ino) == (identity.st_dev, identity.st_ino):
                    matches.append(entry.name)
            if len(matches) != 1:
                raise ValueError("Ambiguous hard-linked path")
            current = os.path.join(current, matches[0])
        else:
            missing = True
            current = candidate
    return current


def path_identity(path, names_only=False):
    """Read-only file identity, or prospective identity on its parent volume."""
    path = os.path.abspath(path)
    if names_only:
        current, name = os.path.split(path)
        if not name:
            raise ValueError("A file name is required for name identity")
        missing = [name]
    else:
        current = path
        missing = []
    while True:
        try:
            info = os.stat(current, follow_symlinks=False)
            break
        except FileNotFoundError:
            parent, name = os.path.split(current)
            if parent == current:
                raise
            missing.insert(0, name)
            current = parent
    if stat.S_ISLNK(info.st_mode):
        raise ValueError(f"Use a physical path for file identity: {current}")
    identity = f"{info.st_dev}:{info.st_ino}"
    if not missing:
        return "existing:" + identity
    if not stat.S_ISDIR(info.st_mode):
        raise ValueError(f"Missing path has a non-directory parent: {current}")
    # Darwin sys/unistd.h defines _PC_CASE_SENSITIVE as 11. Python's exported
    # pathconf_names does not expose this Darwin extension on every build.
    sensitive = os.pathconf(current, 11)
    if sensitive not in (0, 1):
        raise ValueError(f"Filesystem case semantics unavailable: {current}")
    suffix = "/".join(unicodedata.normalize("NFD", part) for part in missing)
    if not sensitive:
        suffix = suffix.casefold()
    return ("name:" if names_only else "missing:") + identity + ":" + suffix


def path_name_identity(path):
    """Identity of a directory entry; separate hardlinks keep separate names."""
    return path_identity(path, names_only=True)


def process_info(pid):
    # Darwin proc_bsdinfo ABI: PID/PPID at 12/16, PGID at 100,
    # microsecond process creation identity at 120/128; 136 bytes on arm64/x86_64.
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    lib.proc_pidinfo.restype = ctypes.c_int
    data = ctypes.create_string_buffer(136)
    n = lib.proc_pidinfo(pid, 3, 0, data, 136)
    if n == 0 and ctypes.get_errno() in (errno.ESRCH, errno.ENOENT):
        return None
    if n != 136:
        raise OSError(ctypes.get_errno(), f"process identity unavailable: {pid}")
    raw = data.raw
    sec, usec = struct.unpack_from("=QQ", raw, 120)
    return {
        "ProcessId": struct.unpack_from("=I", raw, 12)[0],
        "ParentProcessId": struct.unpack_from("=I", raw, 16)[0],
        "GroupId": struct.unpack_from("=I", raw, 100)[0],
        "CreationTimeUtc": utc(sec + usec / 1_000_000),
        "identity": f"{sec}:{usec}",
        "Name": raw[48:64].split(b"\0")[0].decode("utf-8", "replace"),
    }


def snapshot():
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid=,ppid=,pgid="], capture_output=True, text=True, check=True, timeout=10
    )
    rows = []
    for line in result.stdout.splitlines():
        values = line.split()
        if len(values) != 3:
            raise ValueError("Unexpected ps process row")
        rows.append(tuple(map(int, values)))
    return rows


def acl_text(path):
    result = subprocess.run(
        ["/bin/ls", "-led", str(path)], capture_output=True, text=True, check=True, timeout=10,
        env={**os.environ, "LC_ALL": "C"},
    )
    return "\n".join(re.sub(r"^\s*\d+:\s*", "", line) for line in result.stdout.splitlines()[1:]
                     if re.match(r"^\s*\d+:", line))


def birth_time(path, value=None):
    lib = system_library()
    # attrlist bitmapcount=5, commonattr=ATTR_CMN_CRTIME.
    attributes = ctypes.create_string_buffer(struct.pack("=HHIIIII", 5, 0, 0x200, 0, 0, 0, 0))
    if value is None:
        data = ctypes.create_string_buffer(20)  # uint32 size + packed timespec
        lib.getattrlist.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ulong]
        if lib.getattrlist(os.fsencode(path), attributes, data, 20, 1) != 0:
            raise OSError(ctypes.get_errno(), "getattrlist creation time")
        seconds, nanos = struct.unpack_from("=qq", data.raw, 4)
        return seconds * 1_000_000_000 + nanos
    data = ctypes.create_string_buffer(struct.pack("=qq", *divmod(int(value), 1_000_000_000)))
    lib.setattrlist.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ulong]
    if lib.setattrlist(os.fsencode(path), attributes, data, 16, 1) != 0:
        raise OSError(ctypes.get_errno(), "setattrlist creation time")


def metadata(path):
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
        raise ValueError("Metadata backup requires a regular single-link file")
    if st.st_flags & (stat.UF_IMMUTABLE | stat.UF_APPEND | stat.SF_IMMUTABLE | stat.SF_APPEND):
        raise ValueError("Immutable/append-only file requires operator preparation")
    return {
        "platform": "macos", "mode": stat.S_IMODE(st.st_mode), "uid": st.st_uid, "gid": st.st_gid,
        "birthNs": birth_time(path), "writeNs": st.st_mtime_ns, "accessNs": st.st_atime_ns,
        "flags": st.st_flags, "acl": acl_text(path),
        "xattrs": {key: base64.b64encode(os.getxattr(path, key, follow_symlinks=False)).decode("ascii")
                   for key in sorted(os.listxattr(path, follow_symlinks=False))},
    }


def restore(path, data):
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
        raise ValueError("Restore requires a regular single-link file")
    if (st.st_uid, st.st_gid) != (data["uid"], data["gid"]):
        os.chown(path, data["uid"], data["gid"], follow_symlinks=False)
    os.chmod(path, data["mode"], follow_symlinks=False)
    subprocess.run(["/bin/chmod", "-N", path], check=True, capture_output=True, timeout=10)
    if data["acl"]:
        subprocess.run(["/bin/chmod", "-E", path], input=data["acl"] + "\n",
                       text=True, check=True, capture_output=True, timeout=10)
    for key in set(os.listxattr(path, follow_symlinks=False)) - set(data["xattrs"]):
        os.removexattr(path, key, follow_symlinks=False)
    for key, value in data["xattrs"].items():
        os.setxattr(path, key, base64.b64decode(value), follow_symlinks=False)
    birth_time(path, data["birthNs"])
    os.utime(path, ns=(data["accessNs"], data["writeNs"]), follow_symlinks=False)
    os.chflags(path, data["flags"], follow_symlinks=False)
    actual = metadata(path)
    if actual != data:
        raise ValueError("macOS metadata roundtrip mismatch")


def redact(text):
    text = re.sub(r"(?i)\bsk-[\w-]{8,}", "sk-«REDACTED»", text)
    text = re.sub(r"(?i)(\bbearer\s+)[\w.\-]{10,}", r"\1«REDACTED»", text)
    return re.sub(
        r'(?i)((?:api[_-]?key|token|password|secret|authorization)["\']?\s*[:=]\s*["\']?)[^\s"\',;}]{8,}',
        r"\1«REDACTED»", text)


def run(request):
    started = time.monotonic()
    logs = Path(request["LogDirectory"])
    logs.mkdir(parents=True, exist_ok=True)
    record = {
        "InvocationId": request["InvocationId"], "Pid": None, "ProcessStartTimeUtc": None,
        "Platform": "macos", "ProcessGroup": None, "Launched": False, "ExitCode": None,
        "RootExited": False, "TimedOut": False, "IdleTimedOut": False, "ForcedTermination": False,
        "Cleanup": "not_started", "CleanupDetail": "", "Descendants": [], "Errors": [],
        "StdoutPath": str(logs / "stdout.log"), "StderrPath": str(logs / "stderr.log"),
        "ResultFile": str(logs / request.get("ResultFileName", "result.txt")),
        "StartedAtUtc": utc(), "Ok": False,
    }
    cancelled = threading.Event()
    def watch_owner():
        # A closed supervisor lifetime pipe requests orderly worker cleanup.
        while os.read(sys.stdin.fileno(), 4096):
            pass
        cancelled.set()
    threading.Thread(target=watch_owner, daemon=True).start()
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda *_: cancelled.set())
    owner = os.getppid()
    child = None
    owned = {}
    threads = []
    activity = [time.monotonic()]
    uncertain = False
    escaped = False
    fork_events = False
    events = None

    def collect():
        nonlocal escaped, uncertain, fork_events
        if events is not None:
            for event in events.control(None, 128, 0):
                if event.flags & select.KQ_EV_ERROR:
                    uncertain = True
                if event.fflags & select.KQ_NOTE_FORK:
                    # Darwin no longer implements NOTE_TRACK. A fork event can
                    # represent children already reparented before our snapshot.
                    fork_events = True
                    uncertain = True
        rows = snapshot()
        known = {}
        for pid, identity in owned:
            info = process_info(pid)
            if info and info["identity"] == identity:
                known[pid] = info
        group_anchor = any(info["GroupId"] == child.pid for info in known.values())
        candidates = {pid for pid, _, _ in rows}
        # PPID/PGID from a snapshot are hints. Re-read current identity and
        # current parent before adopting any new PID into the owned set.
        while True:
            added = False
            for pid in candidates - set(known):
                info = process_info(pid) if any(row[0] == pid and (row[1] in known or row[2] == child.pid) for row in rows) else None
                if not info:
                    continue
                parent = known.get(info["ParentProcessId"])
                parent_now = process_info(info["ParentProcessId"]) if parent else None
                parent_matches = parent and parent_now and parent["identity"] == parent_now["identity"]
                if not parent_matches and not (group_anchor and info["GroupId"] == child.pid):
                    uncertain = True
                    continue
                current = process_info(pid)
                if not current or current["identity"] != info["identity"]:
                    uncertain = True
                    continue
                known[pid] = current
                owned[(pid, current["identity"])] = current
                added = True
            if not added:
                break
        live = list(known.values())
        escaped |= any(info["GroupId"] != child.pid for info in live)
        return live

    def signal_owned(sig):
        for info in collect():
            current = process_info(info["ProcessId"])
            if current and current["identity"] == info["identity"]:
                try:
                    os.kill(info["ProcessId"], sig)
                except ProcessLookupError:
                    pass

    def drain(stream, filename):
        try:
            drain_stream(stream, filename)
        except Exception as exc:
            record["Errors"].append(redact(f"Output collection: {exc}"))
            cancelled.set()

    def drain_stream(stream, filename):
        carry = b""
        with open(filename, "w", encoding="utf-8") as output:
            while True:
                chunk = os.read(stream.fileno(), 65536)
                if not chunk:
                    break
                activity[0] = time.monotonic()
                carry += chunk
                while b"\n" in carry:
                    line, carry = carry.split(b"\n", 1)
                    output.write(redact(line.decode("utf-8", "replace")) + "\n")
                    output.flush()
                if len(carry) > 4 * 1024 * 1024:
                    cancelled.set()
                    record["Errors"].append("Output line exceeds 4 MiB")
                    carry = b""
            output.write(redact(carry.decode("utf-8", "replace")))

    try:
        snapshot()  # Establish query capability before launch.
        child = subprocess.Popen(
            [sys.executable, "-B", __file__, "exec-gate"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            cwd=request["WorkingDirectory"], start_new_session=True,
            env={**os.environ, **request.get("Environment", {})},
        )
        record["Pid"] = child.pid
        record["ProcessGroup"] = child.pid
        identity = process_info(child.pid)
        if not identity or identity["GroupId"] != child.pid:
            raise RuntimeError("Worker process group handshake failed")
        record["ProcessStartTimeUtc"] = identity["CreationTimeUtc"]
        owned[(child.pid, identity["identity"])] = identity
        events = select.kqueue()
        events.control([select.kevent(child.pid, filter=select.KQ_FILTER_PROC,
                                      flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_CLEAR,
                                      fflags=select.KQ_NOTE_FORK | select.KQ_NOTE_EXIT)], 0, 0)
        # Gate waits for this request before exec; the identity is already recorded.
        child.stdin.write((json.dumps({"exe": request["ExePath"], "argv": request["Arguments"]}) + "\n").encode())
        child.stdin.close()
        record["Launched"] = True
        for stream, filename in ((child.stdout, record["StdoutPath"]), (child.stderr, record["StderrPath"])):
            thread = threading.Thread(target=drain, args=(stream, filename), daemon=True)
            thread.start()
            threads.append(thread)
        while child.poll() is None:
            collect()
            now = time.monotonic()
            if now - started >= request.get("TotalTimeoutSeconds", 900):
                record["TimedOut"] = True
                break
            if now - activity[0] >= request.get("IdleTimeoutSeconds", 240):
                record["IdleTimedOut"] = True
                break
            if cancelled.is_set() or os.getppid() != owner:
                raise RuntimeError("Supervisor disconnected or output collection cancelled")
            time.sleep(0.1)
    except Exception as exc:
        record["Errors"].append(redact(str(exc)))
        uncertain = child is not None
    finally:
        if child is not None:
            try:
                signal_owned(signal.SIGTERM)
                until = time.monotonic() + request.get("GracefulSeconds", 10)
                while time.monotonic() < until:
                    child.poll()
                    if not collect():
                        break
                    time.sleep(0.1)
                if collect():
                    record["ForcedTermination"] = True
                    signal_owned(signal.SIGKILL)
                until = time.monotonic() + request.get("ForceSeconds", 20)
                while time.monotonic() < until:
                    child.poll()
                    if not collect():
                        break
                    time.sleep(0.1)
                live = collect()
                record["RootExited"] = child.poll() is not None
                record["ExitCode"] = child.returncode
                for thread in threads:
                    thread.join(timeout=2)
                uncertain |= any(thread.is_alive() for thread in threads) or escaped
                record["Cleanup"] = "uncertain" if uncertain else ("failed" if live else "verified")
                record["CleanupDetail"] = ("process group and recorded identities inspected; "
                                           f"live={len(live)}, escaped={escaped}, forkEvents={fork_events}, queryUncertain={uncertain}")
            except Exception as exc:
                record["Errors"].append(redact(str(exc)))
                record["Cleanup"] = "uncertain"
            record["Descendants"] = [v for v in owned.values() if v["ProcessId"] != child.pid]
        if events is not None:
            events.close()
        record["ForkEventsObserved"] = fork_events
        record["DescendantCount"] = len(record["Descendants"])
        record["EndedAtUtc"] = utc()
        record["DurationMs"] = int((time.monotonic() - started) * 1000)
        record["Ok"] = record["RootExited"] and record["Cleanup"] == "verified" and not record["Errors"]
        temporary = logs / "process.json.tmp"
        temporary.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
        os.replace(temporary, logs / "process.json")
    return record


def main():
    if sys.platform != "darwin":
        raise RuntimeError("This helper runs on macOS")
    if len(sys.argv) > 1 and sys.argv[1] == "exec-gate":
        line = sys.stdin.buffer.readline()
        if not line:
            return
        request = json.loads(line)
        os.execve(request["exe"], [request["exe"], *request["argv"]], os.environ)
    request = json.loads(sys.stdin.readline())
    operation = request["operation"]
    if operation == "run":
        result = run(request)
    elif operation == "metadata":
        result = {"metadata": metadata(request["path"])}
    elif operation == "canonical":
        result = {"path": canonical_path(request["path"])}
    elif operation == "path_identities":
        identity = path_name_identity if request.get("namesOnly", False) else path_identity
        result = {"identities": [identity(path) for path in request["paths"]]}
    elif operation == "restore":
        restore(request["path"], request["metadata"])
        result = {"ok": True}
    elif operation == "snapshot":
        items = []
        for pid, parent, group in snapshot():
            # Absence checks include all PIDs, even when another user's identity is unreadable.
            try:
                info = process_info(pid)
            except OSError:
                info = None
            items.append(info or {"ProcessId": pid, "ParentProcessId": parent,
                                  "GroupId": group, "CreationTimeUtc": None, "Name": ""})
        result = {"Ok": True, "Code": "ok", "Items": items}
    else:
        raise ValueError(f"Unknown platform operation: {operation}")
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(json.dumps({"error": str(exc)}))
        sys.exit(1)
