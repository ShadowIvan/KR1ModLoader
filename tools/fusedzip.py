"""Read and rebuild a fused LÖVE executable: [PE stub][zip archive with the game].

Python's zipfile can read such files (it finds the EOCD record and accounts for
the archive offset) but cannot write already-compressed data without
recompressing. This is a small zip writer that copies compressed bytes as they
are -- rebuilding a 360 MB exe takes seconds, not minutes.

    from fusedzip import FusedExe
    exe = FusedExe.open("Kingdom Rush.exe")
    exe.put("main.lua", b"...")          # replace or add a file
    exe.rename("main.lua", "modloader/game_main.lua")
    exe.save("Kingdom Rush.modded.exe")
"""
from __future__ import annotations

import struct
import zipfile
import zlib
from dataclasses import dataclass
from pathlib import Path

LOCAL_SIG = b"PK\x03\x04"
CENTRAL_SIG = b"PK\x01\x02"
EOCD_SIG = b"PK\x05\x06"


class FusedExeError(RuntimeError):
    pass


def find_archive_start(data: bytes) -> int:
    """Offset of the zip inside the exe, from the EOCD record (no PE parsing)."""
    tail = max(0, len(data) - (22 + 0xFFFF))
    eocd = data.rfind(EOCD_SIG, tail)
    if eocd < 0:
        raise FusedExeError("no zip archive found: not a fused LÖVE executable")
    (_sig, _d, _cd, _n, _total, cd_size, cd_offset, _clen) = struct.unpack("<4sHHHHIIH", data[eocd:eocd + 22])
    if cd_size == 0xFFFFFFFF or cd_offset == 0xFFFFFFFF:
        raise FusedExeError("ZIP64 is not supported")
    start = eocd - cd_size - cd_offset
    if start < 0 or data[start:start + 4] != LOCAL_SIG:
        raise FusedExeError("could not locate the archive start")
    return start


@dataclass
class Entry:
    name: str
    method: int          # 0 = stored, 8 = deflate
    crc: int
    csize: int
    usize: int
    dostime: int
    dosdate: int
    raw: bytes           # already compressed bytes
    is_dir: bool = False


class FusedExe:
    def __init__(self, stub: bytes, entries: list[Entry]):
        self.stub = stub
        self.entries: dict[str, Entry] = {}
        for e in entries:
            self.entries[e.name] = e

    # ------------------------------------------------------------------ read
    @classmethod
    def open(cls, path: str | Path) -> "FusedExe":
        data = Path(path).read_bytes()
        start = find_archive_start(data)
        stub = data[:start]
        archive = memoryview(data)[start:]
        zf = zipfile.ZipFile(_Bytes(archive))
        entries = []
        for info in zf.infolist():
            ho = info.header_offset
            if archive[ho:ho + 4] != LOCAL_SIG:
                raise FusedExeError(f"corrupt local header: {info.filename}")
            name_len, extra_len = struct.unpack("<HH", archive[ho + 26:ho + 30])
            data_off = ho + 30 + name_len + extra_len
            raw = bytes(archive[data_off:data_off + info.compress_size])
            entries.append(Entry(
                name=info.filename, method=info.compress_type, crc=info.CRC,
                csize=info.compress_size, usize=info.file_size,
                dostime=_dostime(info.date_time), dosdate=_dosdate(info.date_time),
                raw=raw, is_dir=info.filename.endswith("/"),
            ))
        return cls(stub, entries)

    @property
    def files(self) -> list[str]:
        return [n for n, e in self.entries.items() if not e.is_dir]

    def has(self, name: str) -> bool:
        return name in self.entries and not self.entries[name].is_dir

    def read(self, name: str) -> bytes:
        e = self.entries[name]
        if e.method == 0:
            return e.raw
        if e.method == 8:
            return zlib.decompress(e.raw, -15)
        raise FusedExeError(f"unknown compression method {e.method}: {name}")

    # ------------------------------------------------------------------ edit
    def put(self, name: str, content: bytes, compress: bool = True) -> None:
        old = self.entries.get(name)
        dostime, dosdate = (old.dostime, old.dosdate) if old else (0, 0x21)
        if compress:
            c = zlib.compressobj(9, zlib.DEFLATED, -15)
            raw = c.compress(content) + c.flush()
            method = 8
        else:
            raw, method = content, 0
        self.entries[name] = Entry(name=name, method=method, crc=zlib.crc32(content) & 0xFFFFFFFF,
                                   csize=len(raw), usize=len(content), dostime=dostime,
                                   dosdate=dosdate, raw=raw)

    def rename(self, src: str, dst: str) -> None:
        e = self.entries.pop(src)
        e.name = dst
        self.entries[dst] = e

    def remove(self, name: str) -> None:
        self.entries.pop(name, None)

    # ------------------------------------------------------------------ write
    def archive_bytes(self) -> bytes:
        out = bytearray()
        central = bytearray()
        for e in self.entries.values():
            name = e.name.encode("utf-8")
            flags = 0x800  # UTF-8 names
            offset = len(out)
            out += struct.pack("<4sHHHHHIIIHH", LOCAL_SIG, 20, flags, e.method, e.dostime, e.dosdate,
                               e.crc, e.csize, e.usize, len(name), 0)
            out += name
            out += e.raw
            ext_attr = 0x10 if e.is_dir else 0
            central += struct.pack("<4sHHHHHHIIIHHHHHII", CENTRAL_SIG, 20, 20, flags, e.method,
                                   e.dostime, e.dosdate, e.crc, e.csize, e.usize, len(name),
                                   0, 0, 0, 0, ext_attr, offset)
            central += name
        n = len(self.entries)
        if n > 0xFFFF or len(out) + len(central) > 0xFFFFFFFF:
            raise FusedExeError("archive too large for zip without ZIP64")
        eocd = struct.pack("<4sHHHHIIH", EOCD_SIG, 0, 0, n, n, len(central), len(out), 0)
        return bytes(out + central + eocd)

    def save(self, path: str | Path) -> int:
        blob = self.stub + self.archive_bytes()
        Path(path).write_bytes(blob)
        return len(blob)


class _Bytes:
    """File-like wrapper over a memoryview for zipfile.ZipFile."""

    def __init__(self, view: memoryview):
        self._v = view
        self._p = 0

    def read(self, n: int = -1) -> bytes:
        if n is None or n < 0:
            n = len(self._v) - self._p
        chunk = bytes(self._v[self._p:self._p + n])
        self._p += len(chunk)
        return chunk

    def seek(self, off: int, whence: int = 0) -> int:
        if whence == 0:
            self._p = off
        elif whence == 1:
            self._p += off
        else:
            self._p = len(self._v) + off
        self._p = max(0, min(self._p, len(self._v)))
        return self._p

    def tell(self) -> int:
        return self._p

    def seekable(self) -> bool:
        return True


def _dostime(dt) -> int:
    return (dt[3] << 11) | (dt[4] << 5) | (dt[5] // 2)


def _dosdate(dt) -> int:
    return ((max(dt[0], 1980) - 1980) << 9) | (dt[1] << 5) | dt[2]
