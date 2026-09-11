# KR1ModLoader — a `Mods` folder for Kingdom Rush

[Releases](../../releases) · MIT

A mod loader built into the original Kingdom Rush (Steam, `kr1-desktop-6.4.46`).
Install once; from then on mods are just folders (or zip files) dropped into `Mods/`
next to `Kingdom Rush.exe` and picked up on launch. No per-mod installers, no zip
patching, no rewriting the game exe for every mod.

Verified on the real game with several existing mods converted to the folder format,
including a full content pack and a mod that hooks the game's UI.

## How it works

The game is a fused LÖVE 0.10 build: `[PE stub][zip with the game]`. KR1ModLoader changes
exactly one file in that zip: `main.lua` is renamed to `modloader/game_main.lua` and
replaced by [bootstrap/main.lua](bootstrap/main.lua), which:

1. mounts the game folder into `love.filesystem` (the engine allows this for
   `getSourceBaseDirectory()`; the game itself uses it for external `.dat` files);
2. finds folders and `.zip` files in `Mods/`, reads their `mod.json`, sorts by `priority`;
3. mounts every mod **at the root, on top of the game archive** — a mod file at the same
   path replaces the game's file, new files simply appear (`require`, `love.graphics.newImage`,
   `love.filesystem.read` all work as if the files were in the archive);
4. runs the game's original `main.lua` and executes mod entry points at the right stage.

Loader logic: [bootstrap/modloader/loader.lua](bootstrap/modloader/loader.lua).
Every launch is logged to `modloader.log` next to the exe.

## Installation (the loader only)

Players: grab a release from [Releases](../../releases). All three methods install the same thing:

| Method | File | For whom |
|---|---|---|
| **Script** (recommended) | `KR1ModLoader-Setup-X.Y.Z.zip` → unzip → `install.bat` (or drag `Kingdom Rush.exe` onto it) | everyone: only `.bat`, a PowerShell script and 3 Lua files inside (the `.bat` files are generated at release time), no binaries — nothing for antivirus engines to score |
| **GUI** | `KR1ModLoader-Setup-X.Y.Z.exe` — single file, Install/Remove buttons; also works from a console: `KR1ModLoader-Setup.exe install ["…\Kingdom Rush.exe"]` | people who dislike scripts; an unsigned build may trigger AV false positives |
| **From source** | `py tools/modloader.py install [--game-dir …] [--from <clean exe>]` | developers; also `status`, `uninstall`, `build`, `release` |

All three locate the game via the Steam registry key / `libraryfolders.vdf`, rewrite only
the zip part of the exe (the PE code is untouched byte for byte) and create `Mods/`. No
backup copy of the exe is made. Uninstall — `uninstall.bat` / the Remove button /
`modloader.py uninstall` — reverses the change inside the exe: `main.lua` goes back, the
loader files are removed; `Mods/` stays. Steam's "verify integrity" also restores the
stock exe — re-run the installer afterwards.

Install KR1ModLoader into a **clean** exe. If an old-style mod already patched your exe,
restore the original through Steam first and put that mod into `Mods/` as a folder.

Building a release locally: `py tools/modloader.py release` (zip) and
`powershell -File tools/build_setup.ps1` (exe; `-CertFile`/`-CertThumbprint` to sign).
[release.yml](.github/workflows/release.yml) does the same on GitHub for a `vX.Y.Z`
tag matching `VERSION.txt`; the `KR1ML_CERT_FILE` (base64 pfx) and
`KR1ML_CERT_PASSWORD` secrets enable exe signing.

## Mod format

```
Mods/
  MyMod/                 <- a folder, or MyMod.zip with the same contents
    mod.json             <- optional; without it the mod is an overlay with id = folder name
    init.lua             <- entry point (optional)
    kr1/data/...         <- any game file at the same path -> replaces the original
    mymod/*.lua          <- your own modules: require("mymod.x")
```

`mod.json`:

```json
{
  "id": "mymod",            // unique id (for requires/has_mod); defaults to the folder name
  "name": "My Mod",
  "version": "1.0.0",
  "priority": 50,           // higher = mounted later = its files win; default 50
  "entry": "init.lua",      // entry point; defaults to init.lua if present
  "stage": "boot",          // preload | boot | loaded; default boot
  "requires": ["othermod"], // logged warning if missing
  "conflicts": [],          // logged warning if present
  "enabled": true           // false = skip
}
```

Disable a mod without deleting it: rename the folder to `MyMod.disabled` (or prefix it with `_`).

Stages:

| stage | when | available |
|---|---|---|
| `preload` | before the game's `main.lua` | `love`, `modloader`; game modules cannot be required yet |
| `boot` | inside `love.load`, right after `main:set_locale()` | game globals (`main`, `KR_GAME`, `KR_PATH_*`), `i18n`, `love.graphics`; the director does not exist yet — the place to hook game modules |
| `loaded` | after the game's `love.load` returned | everything the game has on its first screen |

The `modloader` API (a global, available in `init.lua`):

```lua
modloader.VERSION, modloader.game_dir, modloader.stage, modloader.mods
modloader.log(fmt, ...)            -- to modloader.log
modloader.on(stage, fn)            -- run fn at a stage (immediately if it already passed)
modloader.has_mod(id), modloader.get_mod(id)
modloader.wrap(tbl, key, function(orig, ...) ... end)   -- wrap a function
modloader.file_exists(path)
```

Example: [examples/HelloMod](examples/HelloMod). A total conversion that ships its own
`main.lua` is fine too: the loader detects the override via `getRealDirectory` and runs
it instead of the original.

Converting an old-style mod (a patched exe) into a folder: everything the mod added or
changed in the archive goes into the mod folder at the same paths; a hook that used to
replace `all-desktop/data/font_subst.lua` becomes an `init.lua` making the same call at
the `boot` stage. An overlay cannot delete files, only replace them.

## Checks

```bash
py -m pip install lupa
py -m unittest discover -s tests -v      # fused-zip writer + loader logic in LuaJIT 2.0
py tools/check_syntax.py                 # syntax of bootstrap/ and examples/
```

[ci.yml](.github/workflows/ci.yml) runs the same on every push.

## Limitations

- LÖVE 0.10 has no `mountFullPath`, so the loader mounts the whole game folder (at the root,
  lowest priority) — files next to the exe become visible to the game by name. Harmless in practice.
- An overlay cannot **delete** game files, only replace them.
- Steam's "verify integrity" restores the original exe — re-run the installer (`Mods/` survives).
- The loader is built into whatever exe you give it; after a game update rebuild from the new original.

## Legal

This repository contains no game assets or game code. It only modifies the copy of the
game the user already owns, on the user's own machine, and can undo that change.
Kingdom Rush is a trademark of Ironhide Game Studio.
