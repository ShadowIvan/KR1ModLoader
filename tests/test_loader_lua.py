"""py -m unittest discover -s tests -v

Loader logic without the game: json.lua, mod ordering by priority, stages and
handlers. Lua runs in LuaJIT 2.0 through lupa (py -m pip install lupa) with a
love.filesystem stub over a temporary Mods folder.
"""
import os
import sys
import tempfile
import unittest

try:
    from lupa.luajit20 import LuaRuntime
except ImportError:  # pragma: no cover
    LuaRuntime = None

ROOT = os.path.join(os.path.dirname(__file__), "..")
BOOT = os.path.join(ROOT, "bootstrap")

# love.filesystem stub over a real folder: mount(base) just remembers the root,
# mount(mod) records the order, files are read from disk.
FAKE_LOVE = r"""
local base
love = { filesystem = {} }
local fs = love.filesystem
fs.mounted = {}
local function real(path)
  return base .. "/" .. path
end
function fs.getSourceBaseDirectory() return base end
function fs.getSource() return base .. "/Kingdom Rush.exe" end
function fs.getRealDirectory(p) return fs.getSource() end
function fs.mount(archive, mp, append)
  if archive == base then return true end
  if archive:match("%.zip$") then return false end
  fs.mounted[#fs.mounted + 1] = archive
  return true
end
function fs.unmount() return true end
function fs.isDirectory(p)
  local ok = os.rename(real(p), real(p))
  if not ok then return false end
  local f = io.open(real(p), "rb")
  if f then
    local d = f:read(1)
    f:close()
    return d == nil  -- directories open but cannot be read
  end
  return true
end
function fs.isFile(p)
  local f = io.open(real(p), "rb")
  if not f then return false end
  local d = f:read(1)
  f:close()
  return d ~= nil
end
function fs.read(p)
  local f = io.open(real(p), "rb")
  if not f then return nil, "no file" end
  local d = f:read("*a") f:close() return d
end
function fs.getDirectoryItems(p)
  local out = {}
  local h = io.popen('dir /b "' .. (real(p):gsub("/", "\\")) .. '" 2>nul')
  for line in h:lines() do out[#out + 1] = line end
  h:close()
  return out
end
return function(b) base = b end
"""


@unittest.skipIf(LuaRuntime is None, "lupa is not installed")
class LoaderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = self.tmp.name.replace("\\", "/")
        os.mkdir(os.path.join(self.tmp.name, "Mods"))
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        set_base = self.lua.execute(FAKE_LOVE)
        set_base(self.base)
        self.lua.execute('package.path = "%s/?.lua;" .. package.path' % BOOT.replace("\\", "/"))
        self.lua.execute("function print() end")

    def tearDown(self):
        self.tmp.cleanup()

    def mod(self, folder, manifest=None, init=None):
        d = os.path.join(self.tmp.name, "Mods", folder)
        os.makedirs(d, exist_ok=True)
        if manifest is not None:
            with open(os.path.join(d, "mod.json"), "w", encoding="utf-8") as fh:
                fh.write(manifest)
        if init is not None:
            with open(os.path.join(d, "init.lua"), "w", encoding="utf-8") as fh:
                fh.write(init)

    def start(self):
        KF = self.lua.require("modloader.loader")
        KF.start()
        return KF

    def test_priority_order_and_skips(self):
        self.mod("Zeta", '{"id":"zeta","priority":10}')
        self.mod("Alpha", '{"id":"alpha","priority":90}')
        self.mod("Mid", '{"id":"mid"}')
        self.mod("Off.disabled", '{"id":"off"}')
        self.mod("Broken", '{"id":')
        self.mod("Hidden", '{"id":"hidden","enabled":false}')
        KF = self.start()
        ids = [m.id for m in KF.mods.values()]
        self.assertEqual(ids, ["zeta", "mid", "alpha"])
        mounted = list(self.lua.globals().love.filesystem.mounted.values())
        self.assertEqual(mounted, ["Mods/Zeta", "Mods/Mid", "Mods/Alpha"])
        reasons = {s.name: s.reason for s in KF.skipped.values()}
        self.assertIn("Off.disabled", reasons)
        self.assertIn("mod.json", reasons["Broken"])
        self.assertIn("Hidden", reasons)

    def test_stages_and_handlers(self):
        self.mod("A", '{"id":"a","stage":"preload"}',
                 'ORDER = ORDER or {}; ORDER[#ORDER+1] = "a-preload"; '
                 'modloader.on("loaded", function() ORDER[#ORDER+1] = "a-loaded" end)')
        self.mod("B", '{"id":"b"}', 'ORDER[#ORDER+1] = "b-boot"; error("boom")')
        self.mod("C", None, 'ORDER[#ORDER+1] = "c-boot"')  # no mod.json
        KF = self.start()
        self.assertEqual(list(self.lua.globals().ORDER.values()), ["a-preload"])
        # emulate the game: main.set_locale and love.load
        self.lua.execute('main = { set_locale = function() end }; '
                         'love.load = function() ORDER[#ORDER+1] = "game-load" end')
        KF.attach()
        self.lua.execute('main:set_locale("en"); love.load()')
        self.assertEqual(list(self.lua.globals().ORDER.values()),
                         ["a-preload", "b-boot", "c-boot", "game-load", "a-loaded"])
        self.assertEqual(KF.errors, 1)  # "boom" from mod B did not break the others
        self.assertTrue(KF.has_mod("C"))
        self.assertEqual(KF.get_mod("C").folder, "C")

    def test_requires_warning_logged(self):
        self.mod("Dep", '{"id":"dep","requires":["base"]}')
        self.start()
        with open(os.path.join(self.tmp.name, "modloader.log"), encoding="utf-8") as fh:
            log = fh.read()
        self.assertIn("requires 'base'", log)


if __name__ == "__main__":
    unittest.main()
