"""KR1ModLoader -- build and install the Kingdom Rush mod loader.

    py tools/modloader.py build   --game "<...>\\Kingdom Rush.exe" --out "<...>\\Kingdom Rush.modded.exe"
    py tools/modloader.py install [--game-dir "<game folder>"] [--from "<clean original exe>"]
    py tools/modloader.py uninstall [--game-dir ...]
    py tools/modloader.py status [--game-dir ...]
    py tools/modloader.py release        -> dist/KR1ModLoader-Setup-<version>.zip for players

`build` takes the game's fused exe and puts the loader (bootstrap/) into its
archive: the original main.lua is renamed to modloader/game_main.lua and ours
takes its place. Nothing else in the archive changes -- everything else is
done by the mods in the Mods folder at run time.

`install` does the same directly in the game folder and creates a Mods folder
next to it. Steam launches "Kingdom Rush.exe", so it launches the loader.
`uninstall` reverses the change inside the exe: main.lua goes back and the
loader files are removed. No backup copy of the exe is made.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from fusedzip import FusedExe, FusedExeError  # noqa: E402

for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parent.parent
BOOTSTRAP = ROOT / "bootstrap"
EXE_NAME = "Kingdom Rush.exe"
LOADER_MARK = "modloader/loader.lua"
GAME_MAIN = "modloader/game_main.lua"

DEFAULT_GAME_DIRS = [
    r"C:\Program Files (x86)\Steam\steamapps\common\Kingdom Rush",
    r"C:\Program Files\Steam\steamapps\common\Kingdom Rush",
]


def find_game_dir(explicit: str | None) -> Path:
    if explicit:
        p = Path(explicit)
        if not (p / EXE_NAME).is_file():
            raise SystemExit(f"no {EXE_NAME} in {p}")
        return p
    for d in DEFAULT_GAME_DIRS:
        if (Path(d) / EXE_NAME).is_file():
            return Path(d)
    # Steam libraryfolders.vdf
    vdf = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "Steam" / "steamapps" / "libraryfolders.vdf"
    if vdf.is_file():
        import re
        for m in re.finditer(r'"path"\s+"([^"]+)"', vdf.read_text(encoding="utf-8", errors="ignore")):
            lib = Path(m.group(1).replace("\\\\", "\\")) / "steamapps" / "common" / "Kingdom Rush"
            if (lib / EXE_NAME).is_file():
                return lib
    raise SystemExit("game folder not found, pass --game-dir")


def describe_exe(exe: FusedExe) -> dict:
    """What the archive is: game version and whether the loader is already inside."""
    info = {"forked": exe.has(LOADER_MARK), "version": "?"}
    if exe.has("version.lua"):
        import re
        m = re.search(rb"kr1-desktop-([0-9.]+)", exe.read("version.lua"))
        if m:
            info["version"] = m.group(1).decode()
    return info


def yes_no(v: bool) -> str:
    return "yes" if v else "no"


def remove_loader(exe: FusedExe) -> None:
    if not exe.has(LOADER_MARK):
        raise FusedExeError("the loader is not installed in this exe")
    exe.remove("main.lua")
    exe.rename(GAME_MAIN, "main.lua")
    for name in [n for n in exe.entries if n.startswith("modloader/")]:
        exe.remove(name)


def inject_loader(exe: FusedExe) -> None:
    if not exe.has(LOADER_MARK):
        if not exe.has("main.lua"):
            raise FusedExeError("no main.lua in the archive")
        exe.rename("main.lua", GAME_MAIN)
    for path in sorted(BOOTSTRAP.rglob("*.lua")):
        rel = path.relative_to(BOOTSTRAP).as_posix()
        exe.put(rel, path.read_bytes())


def cmd_build(args) -> int:
    src = Path(args.game)
    out = Path(args.out) if args.out else src.with_name(src.stem + ".modded.exe")
    print(f"reading {src} ...")
    exe = FusedExe.open(src)
    info = describe_exe(exe)
    print(f"  game version: {info['version']}; loader: {'already inside' if info['forked'] else 'no'}")
    inject_loader(exe)
    size = exe.save(out)
    print(f"built: {out} ({size:,} bytes)")
    return 0


def cmd_install(args) -> int:
    game_dir = find_game_dir(args.game_dir)
    target = game_dir / EXE_NAME
    source = Path(args.source) if args.source else None

    current = FusedExe.open(target)
    cur_info = describe_exe(current)
    print(f"game folder: {game_dir}")
    print(f"  {EXE_NAME}: version {cur_info['version']}, loader: {yes_no(cur_info['forked'])}")

    if source is None:
        base = current
        if cur_info["forked"]:
            print("  loader already installed -- updating it")
    else:
        base = FusedExe.open(source)
        src_info = describe_exe(base)
        print(f"  base exe: {source} (version {src_info['version']})")

    inject_loader(base)
    tmp = target.with_suffix(".exe.tmp")
    base.save(tmp)
    os.replace(tmp, target)
    (game_dir / "Mods").mkdir(exist_ok=True)
    print(f"installed: {target}")
    print(f"put mods into: {game_dir / 'Mods'}")
    print(f"loader log: {game_dir / 'modloader.log'}")
    return 0


def cmd_uninstall(args) -> int:
    game_dir = find_game_dir(args.game_dir)
    target = game_dir / EXE_NAME
    exe = FusedExe.open(target)
    remove_loader(exe)
    tmp = target.with_suffix(".exe.tmp")
    exe.save(tmp)
    os.replace(tmp, target)
    print(f"loader removed: {target} (the Mods folder is left in place)")
    return 0


def cmd_status(args) -> int:
    game_dir = find_game_dir(args.game_dir)
    exe = FusedExe.open(game_dir / EXE_NAME)
    info = describe_exe(exe)
    print(f"game folder: {game_dir}")
    print(f"  version: {info['version']}; loader: {yes_no(info['forked'])}")
    mods = game_dir / "Mods"
    if mods.is_dir():
        items = sorted(mods.iterdir())
        print(f"  Mods ({len(items)}):")
        for it in items:
            kind = "folder" if it.is_dir() else ("zip" if it.suffix == ".zip" else "file")
            has_manifest = (it / "mod.json").is_file() if it.is_dir() else "?"
            print(f"    {it.name:30s} {kind}  mod.json: {has_manifest}")
    else:
        print("  Mods: no folder")
    log = game_dir / "modloader.log"
    if log.is_file():
        print("  modloader.log (last run):")
        for line in log.read_text(encoding="utf-8", errors="replace").splitlines()[-25:]:
            print("    " + line)
    return 0


SETUP_README = r"""KR1ModLoader -- mod loader for Kingdom Rush (Steam)
=============================================

Install
  1. Close the game.
  2. Run install.bat (or drag your Kingdom Rush.exe onto it).
  3. A Mods folder appears next to the game -- put mods there (a folder or a zip):
     Mods\SomeMod, Mods\AnotherMod.zip, ...
  4. Launch the game as usual (through Steam).

Uninstall: uninstall.bat -- removes the loader from the exe. The Mods folder is left in place.
After Steam "verifies integrity of game files", run the installer again.
Loader log: modloader.log next to the game.

There are no programs inside: install.bat runs a PowerShell script
(tools\modloader_install.ps1) that changes one file in the zip part of
Kingdom Rush.exe and adds three Lua files from bootstrap\. The game's
executable code is not touched.
"""


# The batch files only exist inside the release zip: they call the PowerShell
# script with the execution policy bypassed and pass a dragged-and-dropped exe.
BAT = (
    "@echo off\r\n"
    "chcp 65001 >nul\r\n"
    'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\\modloader_install.ps1" {flags}-GameExe "%~1"\r\n'
    "echo.\r\n"
    "pause\r\n"
)


def cmd_release(args) -> int:
    import zipfile
    version = (ROOT / "VERSION.txt").read_text(encoding="utf-8").strip() if (ROOT / "VERSION.txt").is_file() else "dev"
    out = ROOT / "dist" / f"KR1ModLoader-Setup-{version}.zip"
    out.parent.mkdir(exist_ok=True)
    files = [ROOT / "tools" / "modloader_install.ps1"] + sorted(BOOTSTRAP.rglob("*.lua"))
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in files:
            zf.write(f, f.relative_to(ROOT).as_posix())
        zf.writestr("install.bat", BAT.format(flags=""))
        zf.writestr("uninstall.bat", BAT.format(flags="-Uninstall "))
        zf.writestr("README.txt", SETUP_README)
    print(f"built: {out} ({out.stat().st_size:,} bytes, {len(files) + 3} files, no binaries)")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="build a modded exe from an original exe")
    b.add_argument("--game", required=True, help="path to the original Kingdom Rush.exe")
    b.add_argument("--out", help="output path (default: next to the input, *.modded.exe)")
    b.set_defaults(fn=cmd_build)

    i = sub.add_parser("install", help="install the loader into the game folder")
    i.add_argument("--game-dir", help="folder with Kingdom Rush.exe (default: Steam auto-detect)")
    i.add_argument("--from", dest="source", help="use this exe instead of the one in the folder")
    i.set_defaults(fn=cmd_install)

    u = sub.add_parser("uninstall", help="restore the original exe")
    u.add_argument("--game-dir")
    u.set_defaults(fn=cmd_uninstall)

    s = sub.add_parser("status", help="what is installed and what is in Mods")
    s.add_argument("--game-dir")
    s.set_defaults(fn=cmd_status)

    r = sub.add_parser("release", help="build dist/KR1ModLoader-Setup-<version>.zip (bat + ps1 + bootstrap, no exe)")
    r.set_defaults(fn=cmd_release)

    args = ap.parse_args(argv)
    try:
        return args.fn(args)
    except FusedExeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
