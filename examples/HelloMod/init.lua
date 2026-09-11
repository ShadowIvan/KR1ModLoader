-- Mod entry point. Runs at the stage from mod.json (default: boot -- inside
-- love.load after main:set_locale(), when love.graphics, i18n and the game
-- globals KR_GAME/KR_PATH_* exist). An error here goes to modloader.log and does
-- not stop the game from starting.

modloader.log("Hello Mod: stage %s, game in %s", modloader.stage, modloader.game_dir)

-- Other mods are visible by the id from their mod.json.
if modloader.has_mod("othermod") then
	modloader.log("Hello Mod: othermod is installed, version %s", modloader.get_mod("othermod").version)
end

-- Any file next to init.lua is visible to the game at the same path, as if it
-- were in the archive: hello/greeting.lua -> require("hello.greeting").
local greeting = require("hello.greeting")

-- Wrapping a game function: the original comes in as the first argument.
modloader.wrap(love, "keypressed", function(orig, key, ...)
	if key == "f9" then
		modloader.log("Hello Mod: %s", greeting.text())
		return
	end
	if orig then return orig(key, ...) end
end)

-- The loaded stage comes after the game's love.load has finished.
modloader.on("loaded", function()
	modloader.log("Hello Mod: game loaded, screen handler: %s", tostring(main and main.handler))
end)
