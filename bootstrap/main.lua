-- KR1ModLoader: this main.lua replaces the game's own (kept as modloader/game_main.lua).
-- The loader mounts mods from the Mods folder and hands control to the game.
-- A loader error must never stop the game from starting.

local ok, KF = pcall(require, "modloader.loader")
if ok then
	local started, err = pcall(KF.start)
	if not started then KF.error("loader failed: %s", tostring(err)) end
else
	print("[modloader] could not load modloader/loader.lua: " .. tostring(KF))
	KF = nil
end

local main_path = KF and KF.game_main_path() or "modloader/game_main.lua"
local chunk, load_err = love.filesystem.load(main_path)
if not chunk then
	error("KR1ModLoader: could not load " .. main_path .. ": " .. tostring(load_err))
end
chunk()

if KF then
	local attached, err = pcall(KF.attach)
	if not attached then KF.error("could not attach stages: %s", tostring(err)) end
end
