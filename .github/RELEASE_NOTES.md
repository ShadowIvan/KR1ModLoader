## Install

All three methods install the same thing: the mod loader inside your own `Kingdom Rush.exe`
plus a `Mods/` folder next to the game.

| File | What it is |
|---|---|
| `KR1ModLoader-Setup-x.x.x.zip` | `install.bat` + PowerShell + 3 Lua files. No binaries. Unzip, run `install.bat` (or drag `Kingdom Rush.exe` onto it). |
| `KR1ModLoader-Setup-x.x.x.exe` | **Recommended.** Single-file GUI installer. Unsigned builds may trigger antivirus false positives. |
| Source code | `py tools/modloader.py install` — for developers. |

Uninstall: `uninstall.bat` / the Remove button / `modloader.py uninstall`.
Re-run the installer after Steam verifies game files.

Mods are installed separately: drop a mod folder or zip into `Mods/`. See the README.
