"""py -m unittest discover -s tests -v

Exercises the fused-exe writer on a synthetic archive: stub + zip, replace and
rename, raw copy of compressed data without recompression.
"""
import io
import os
import sys
import tempfile
import unittest
import zipfile
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
from fusedzip import FusedExe, FusedExeError, find_archive_start  # noqa: E402


def make_fused(stub=b"MZ" + b"\0" * 300, files=None):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for name, data, method in files or []:
            zf.writestr(name, data, compress_type=method)
    return stub + buf.getvalue()


class FusedZipTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "game.exe")
        self.files = [
            ("main.lua", b"print('game')\n" * 50, zipfile.ZIP_DEFLATED),
            ("conf.lua", b"function love.conf(t) end\n", zipfile.ZIP_DEFLATED),
            ("_assets/a.png", os.urandom(4096), zipfile.ZIP_STORED),
            ("all/game.lua", b"\x1bLJ\x01" + b"\0" * 100, zipfile.ZIP_DEFLATED),
        ]
        with open(self.path, "wb") as fh:
            fh.write(make_fused(files=self.files))

    def tearDown(self):
        self.tmp.cleanup()

    def test_open_and_read(self):
        exe = FusedExe.open(self.path)
        self.assertEqual(len(exe.stub), 302)
        self.assertEqual(sorted(exe.files), sorted(n for n, _, _ in self.files))
        for name, data, _ in self.files:
            self.assertEqual(exe.read(name), data)

    def test_roundtrip_keeps_raw_bytes(self):
        exe = FusedExe.open(self.path)
        out = os.path.join(self.tmp.name, "out.exe")
        exe.save(out)
        with open(out, "rb") as fh:
            blob = fh.read()
        start = find_archive_start(blob)
        self.assertEqual(blob[:start], exe.stub)
        zf = zipfile.ZipFile(io.BytesIO(blob[start:]))
        self.assertIsNone(zf.testzip())
        for name, data, method in self.files:
            self.assertEqual(zf.read(name), data)
            self.assertEqual(zf.getinfo(name).compress_type, method)

    def test_put_rename_remove(self):
        exe = FusedExe.open(self.path)
        exe.rename("main.lua", "modloader/game_main.lua")
        exe.put("main.lua", b"-- loader\n")
        exe.put("raw.bin", b"\x00\x01", compress=False)
        exe.remove("conf.lua")
        out = os.path.join(self.tmp.name, "out.exe")
        exe.save(out)
        zf = zipfile.ZipFile(out)  # zipfile finds the archive behind the stub by itself
        self.assertIsNone(zf.testzip())
        self.assertEqual(zf.read("main.lua"), b"-- loader\n")
        self.assertEqual(zf.read("modloader/game_main.lua"), self.files[0][1])
        self.assertEqual(zf.getinfo("raw.bin").compress_type, zipfile.ZIP_STORED)
        self.assertNotIn("conf.lua", zf.namelist())
        self.assertEqual(zf.getinfo("main.lua").CRC, zlib.crc32(b"-- loader\n"))

    def test_not_fused(self):
        bad = os.path.join(self.tmp.name, "bad.exe")
        with open(bad, "wb") as fh:
            fh.write(b"MZ" + b"\0" * 1000)
        with self.assertRaises(FusedExeError):
            FusedExe.open(bad)


if __name__ == "__main__":
    unittest.main()
