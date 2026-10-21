"""Portable unit fixtures for macOS helper logic; run with Python 3.11+."""
import ctypes
import errno
from pathlib import Path
import posixpath
import struct
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "assets/project/scripts/collaboration/native/platform_macos.py"
platform = ModuleType("platform_macos_fixture")
platform.__file__ = str(SOURCE)
exec(compile(SOURCE.read_text(encoding="utf-8"), str(SOURCE), "exec"), platform.__dict__)


class Function:
    def __init__(self, action):
        self.action = action

    def __call__(self, *args):
        return self.action(*args)


class PlatformContracts(unittest.TestCase):
    def test_process_identity_abi(self):
        raw = bytearray(136)
        struct.pack_into("=II", raw, 12, 123, 99)
        struct.pack_into("=I", raw, 100, 123)
        struct.pack_into("=QQ", raw, 120, 1_700_000_000, 123456)
        raw[48:54] = b"worker"
        def read(pid, flavor, arg, target, size):
            self.assertEqual((pid, flavor, size), (123, 3, 136))
            ctypes.memmove(target, bytes(raw), len(raw))
            return 136
        with patch.object(platform.ctypes, "CDLL", return_value=SimpleNamespace(proc_pidinfo=Function(read))):
            info = platform.process_info(123)
        self.assertEqual(info["identity"], "1700000000:123456")
        self.assertEqual(info["ParentProcessId"], 99)
        self.assertEqual(info["GroupId"], 123)
        self.assertEqual(info["Name"], "worker")

    def test_missing_process(self):
        ctypes.set_errno(errno.ESRCH)
        with patch.object(platform.ctypes, "CDLL", return_value=SimpleNamespace(proc_pidinfo=Function(lambda *args: 0))):
            self.assertIsNone(platform.process_info(100))

    def test_unreadable_process_is_not_absent(self):
        ctypes.set_errno(errno.EPERM)
        with patch.object(platform.ctypes, "CDLL", return_value=SimpleNamespace(proc_pidinfo=Function(lambda *args: 0))):
            with self.assertRaises(OSError):
                platform.process_info(100)

    def test_birth_time_packed_layout(self):
        def read(path, attributes, target, size, options):
            self.assertEqual(struct.unpack_from("=I", attributes.raw, 4)[0], 0x200)
            self.assertEqual((size, options), (20, 1))
            ctypes.memmove(target, struct.pack("=Iqq", 20, 123, 456), 20)
            return 0
        with patch.object(platform, "system_library", return_value=SimpleNamespace(getattrlist=Function(read))):
            self.assertEqual(platform.birth_time("/fixture"), 123000000456)

    def test_canonical_case_alias(self):
        paths = {"/workspace": (1, 10), "/workspace/file.txt": (1, 11)}
        def stat(path):
            device, inode = paths[path.lower()]
            return SimpleNamespace(st_dev=device, st_ino=inode)
        def scan(path):
            names = ["Workspace"] if path == "/" else ["File.txt"]
            return [SimpleNamespace(name=name, stat=lambda follow_symlinks=False, p=posixpath.join(path, name): stat(p)) for name in names]
        filesystem = SimpleNamespace(
            path=SimpleNamespace(isabs=posixpath.isabs, join=posixpath.join,
                                 lexists=lambda p: p.lower() in paths, islink=lambda p: False),
            stat=stat, scandir=scan,
        )
        with patch.object(platform, "os", filesystem):
            self.assertEqual(platform.canonical_path("/workspace/FILE.txt"), "/Workspace/File.txt")
            self.assertEqual(platform.canonical_path("/workspace/new/file"), "/Workspace/new/file")

    def test_canonical_rejects_symlink(self):
        filesystem = SimpleNamespace(path=SimpleNamespace(
            isabs=posixpath.isabs, join=posixpath.join, lexists=lambda p: True, islink=lambda p: True))
        with patch.object(platform, "os", filesystem):
            with self.assertRaises(ValueError):
                platform.canonical_path("/alias")

    def test_log_redaction(self):
        text = platform.redact("token=abcdefgh12345 bearer abcdefgh12345 sk-abcdefgh12345")
        self.assertNotIn("abcdefgh12345", text)
        self.assertEqual(text.count("REDACTED"), 3)


if __name__ == "__main__":
    unittest.main()
