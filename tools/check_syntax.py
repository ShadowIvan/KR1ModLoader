"""Syntax-check Lua files with LuaJIT 2.0 -- the VM the game runs.

    py -m pip install lupa
    py tools/check_syntax.py [folder ...]      # default: bootstrap and examples
"""
import glob
import os
import sys

from lupa.luajit20 import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
targets = sys.argv[1:] or [os.path.join(ROOT, "bootstrap"), os.path.join(ROOT, "examples")]

lua = LuaRuntime(unpack_returned_tuples=True)
check = lua.eval("""function(src, name)
  local f, e = loadstring(src, name)
  if f then return 'OK' else return tostring(e) end
end""")

files = []
for target in targets:
    files += sorted(glob.glob(os.path.join(target, "**", "*.lua"), recursive=True))
if not files:
    print("no Lua files found")
    sys.exit(1)

bad = 0
for path in files:
    rel = os.path.relpath(path, ROOT).replace("\\", "/")
    with open(path, "rb") as handle:
        source = handle.read()
    try:
        result = check(source.decode("utf-8"), rel)
    except UnicodeDecodeError:
        result = "not UTF-8"
    if result != "OK":
        bad += 1
    print("%-44s %s" % (rel, result))

print("\n%d file(s) checked, %d failed" % (len(files), bad))
sys.exit(1 if bad else 0)
