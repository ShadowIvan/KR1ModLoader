-- KR1ModLoader -- mod loader for Kingdom Rush.
--
-- Lives inside the game archive and starts from the replaced main.lua (the
-- original is kept as modloader/game_main.lua). One job: everything in the Mods
-- folder next to the exe must work without installers and without patching
-- the archive.
--
-- How:
--   1. The game folder is mounted into love.filesystem as the root with the
--      lowest priority (mount accepts getSourceBaseDirectory() for exactly
--      this; the game itself mounts external .dat files the same way). After
--      that Mods/ is visible through love.filesystem.
--   2. Every mod (a folder or a .zip in Mods/) is mounted at the root on top of
--      the game archive: a mod file at the same path replaces the game's file,
--      new files simply appear. Order comes from priority in mod.json: higher
--      is mounted later and wins.
--   3. A mod's entry point (init.lua) runs at the chosen stage:
--        preload -- before the game's main.lua (only love and modloader exist);
--        boot    -- inside love.load right after main:set_locale() -- the same
--                   point the old all-desktop/data/font_subst.lua patches used;
--        loaded  -- after the game's love.load has returned.
--
-- Everything a mod does is wrapped in pcall: a broken mod is a line in
-- modloader.log, not a game that fails to start.

local KF = {}

KF.VERSION = "1.0.0"
KF.MODS_DIR = "Mods"
KF.LOG_NAME = "modloader.log"
KF.mods = {}            -- loaded mods in mount order
KF.skipped = {}         -- { name=, reason= }
KF.stage = "init"
KF.errors = 0
KF.current_mod = nil    -- the mod whose code is running right now

local STAGES = { preload = 1, boot = 2, loaded = 3 }
local listeners = { preload = {}, boot = {}, loaded = {} }
local done = {}

--------------------------------------------------------------------- log

local log_path
local log_lines = {}

-- The file is opened per line: there are few lines, and this way the log does
-- not hold a handle for the whole game session and can be read or deleted
-- while the game runs.
local function append_log(line)
	if not log_path then
		log_lines[#log_lines + 1] = line
		return
	end
	local ok, h = pcall(io.open, log_path, "a")
	if ok and h then
		h:write(line, "\n")
		h:close()
	end
end

local function open_log(base_dir)
	local path = base_dir .. "/" .. KF.LOG_NAME
	local ok, h = pcall(io.open, path, "w")
	if not (ok and h) then return end
	h:close()
	log_path = path
	local pending = log_lines
	log_lines = {}
	for _, l in ipairs(pending) do append_log(l) end
end

function KF.log(fmt, ...)
	local line
	if select("#", ...) > 0 then
		local ok, s = pcall(string.format, fmt, ...)
		line = ok and s or tostring(fmt)
	else
		line = tostring(fmt)
	end
	line = os.date("%H:%M:%S ") .. line
	print("[modloader] " .. line)
	append_log(line)
end

function KF.error(fmt, ...)
	KF.errors = KF.errors + 1
	KF.log("ERROR: " .. fmt, ...)
end

--------------------------------------------------------------------- helpers

local fs = love.filesystem

function KF.file_exists(path)
	local ok, r = pcall(fs.isFile, path)
	return ok and r == true
end

local function is_dir(path)
	local ok, r = pcall(fs.isDirectory, path)
	return ok and r == true
end

local function read_text(path)
	local ok, data = pcall(fs.read, path)
	if ok and type(data) == "string" then return data end
	return nil
end

local function to_windows(p)
	return (p:gsub("/", "\\"))
end

-- Mods is created through WinAPI: love.filesystem only writes to the save
-- directory, and os.execute flashes a console window.
local function ensure_dir(path)
	return pcall(function()
		local ffi = require("ffi")
		pcall(ffi.cdef, "int CreateDirectoryA(const char* path, void* attrs);")
		ffi.C.CreateDirectoryA(to_windows(path), nil)
	end)
end

-- Wrap a function in a table: the wrapper receives the original first.
--   modloader.wrap(main, "set_locale", function(orig, self, locale) ... return orig(self, locale) end)
function KF.wrap(tbl, key, wrapper)
	local orig = tbl[key]
	tbl[key] = function(...)
		return wrapper(orig, ...)
	end
	return orig
end

function KF.has_mod(id)
	for _, m in ipairs(KF.mods) do
		if m.id == id then return true end
	end
	return false
end

function KF.get_mod(id)
	for _, m in ipairs(KF.mods) do
		if m.id == id then return m end
	end
	return nil
end

--------------------------------------------------------------------- stages

-- Subscribe to a stage. If the stage already passed, fn runs immediately.
function KF.on(stage, fn)
	if not STAGES[stage] then
		error("modloader.on: unknown stage '" .. tostring(stage) .. "'", 2)
	end
	if done[stage] then
		local mod = KF.current_mod
		local ok, err = pcall(fn)
		if not ok then
			KF.error("mod '%s', %s handler: %s", mod and mod.id or "?", stage, tostring(err))
		end
		return
	end
	table.insert(listeners[stage], { fn = fn, mod = KF.current_mod })
end

local function run_mod_entry(mod)
	if not mod.entry_src then return end
	local chunk, err = loadstring(mod.entry_src, "@" .. mod.entry_path)
	if not chunk then
		KF.error("mod '%s': %s does not compile: %s", mod.id, mod.entry, tostring(err))
		return
	end
	KF.current_mod = mod
	local ok, run_err = pcall(chunk)
	KF.current_mod = nil
	if ok then
		KF.log("mod '%s': %s done (stage %s)", mod.id, mod.entry, mod.stage)
	else
		KF.error("mod '%s': %s failed: %s", mod.id, mod.entry, tostring(run_err))
	end
end

function KF.run_stage(stage)
	if done[stage] then return end
	done[stage] = true
	KF.stage = stage
	KF.log("--- stage %s ---", stage)
	for _, mod in ipairs(KF.mods) do
		if mod.stage == stage then run_mod_entry(mod) end
	end
	local queue = listeners[stage]
	listeners[stage] = {}
	for _, l in ipairs(queue) do
		KF.current_mod = l.mod
		local ok, err = pcall(l.fn)
		KF.current_mod = nil
		if not ok then
			KF.error("mod '%s', %s handler: %s", l.mod and l.mod.id or "?", stage, tostring(err))
		end
	end
end

--------------------------------------------------------------------- mods

local JSON = require("modloader.json")

local function read_manifest(path)
	local text = read_text(path)
	if not text then return {} end
	local t, err = JSON.decode(text)
	if not t then return nil, err end
	if type(t) ~= "table" then return nil, "mod.json must be an object" end
	return t
end

local function list_field(t)
	if type(t) == "string" then return { t } end
	if type(t) == "table" then return t end
	return {}
end

-- Builds the mod record from a folder (or the temporary mount point of a zip).
local function describe(name, root, kind, archive)
	local manifest, err = read_manifest(root .. "/mod.json")
	if not manifest then
		return nil, "mod.json: " .. tostring(err)
	end
	if manifest.enabled == false then
		return nil, "disabled in mod.json"
	end
	local entry = manifest.entry
	if entry == nil then
		entry = KF.file_exists(root .. "/init.lua") and "init.lua" or false
	end
	local stage = manifest.stage or "boot"
	if not STAGES[stage] then
		return nil, "unknown stage '" .. tostring(stage) .. "' in mod.json"
	end
	local mod = {
		id = tostring(manifest.id or (name:gsub("%.zip$", ""))),
		name = manifest.name or name,
		version = tostring(manifest.version or "?"),
		priority = tonumber(manifest.priority) or 50,
		requires = list_field(manifest.requires),
		conflicts = list_field(manifest.conflicts),
		entry = entry or nil,
		stage = stage,
		kind = kind,
		archive = archive,
		dir = root,
		manifest = manifest,
		folder = name,
	}
	if entry then
		mod.entry_path = root .. "/" .. entry
		mod.entry_src = read_text(mod.entry_path)
		if not mod.entry_src then
			return nil, "entry point not found: " .. entry
		end
	end
	return mod
end

local function discover()
	local found = {}
	local ok, items = pcall(fs.getDirectoryItems, KF.MODS_DIR)
	if not ok or type(items) ~= "table" then return found end
	table.sort(items)
	for _, name in ipairs(items) do
		local path = KF.MODS_DIR .. "/" .. name
		local first = name:sub(1, 1)
		if first == "." or first == "_" or name:match("%.disabled$") then
			table.insert(KF.skipped, { name = name, reason = "disabled by name" })
		elseif is_dir(path) then
			local mod, err = describe(name, path, "dir", path)
			if mod then
				found[#found + 1] = mod
			else
				table.insert(KF.skipped, { name = name, reason = err })
			end
		elseif name:match("%.zip$") then
			-- A zip is mounted at a temporary point to read mod.json and init.lua
			-- from an unambiguous path; it is mounted at the root later, in order.
			local tmp = "modloader_tmp/" .. name
			if not fs.mount(path, tmp) then
				table.insert(KF.skipped, { name = name, reason = "zip cannot be mounted" })
			else
				local mod, err = describe(name, tmp, "zip", path)
				fs.unmount(path)
				if mod then
					mod.dir = nil -- invalid once remounted at the root
					found[#found + 1] = mod
				else
					table.insert(KF.skipped, { name = name, reason = err })
				end
			end
		end
	end
	-- ascending priority: the last mounted one has the highest precedence
	table.sort(found, function(a, b)
		if a.priority ~= b.priority then return a.priority < b.priority end
		return a.id:lower() < b.id:lower()
	end)
	return found
end

local function check_dependencies(mods)
	local present = {}
	for _, m in ipairs(mods) do present[m.id] = true end
	for _, m in ipairs(mods) do
		for _, req in ipairs(m.requires) do
			if not present[req] then
				KF.log("WARNING: mod '%s' requires '%s', which is not in Mods", m.id, req)
			end
		end
		for _, c in ipairs(m.conflicts) do
			if present[c] then
				KF.log("WARNING: mod '%s' conflicts with '%s' -- both are loaded", m.id, c)
			end
		end
	end
end

--------------------------------------------------------------------- start

function KF.start()
	local base_dir = fs.getSourceBaseDirectory()
	KF.game_dir = base_dir
	open_log(base_dir)

	KF.log("KR1ModLoader %s, game folder: %s", KF.VERSION, tostring(base_dir))

	-- Root = the exe's folder, lowest priority (after the game archive).
	if not fs.mount(base_dir, "/", true) then
		KF.error("could not mount the game folder; no mods will be loaded")
		return
	end
	if not is_dir(KF.MODS_DIR) then
		ensure_dir(base_dir .. "/" .. KF.MODS_DIR)
		if not is_dir(KF.MODS_DIR) then
			KF.log("no %s folder -- starting without mods", KF.MODS_DIR)
			return
		end
	end

	local mods = discover()
	for _, s in ipairs(KF.skipped) do
		KF.log("skipped %s: %s", s.name, s.reason)
	end
	if #mods == 0 then
		KF.log("no mods in %s", KF.MODS_DIR)
		return
	end

	for _, mod in ipairs(mods) do
		if fs.mount(mod.archive, "/", false) then
			KF.mods[#KF.mods + 1] = mod
			KF.log("mounted %s %s (%s, priority %d%s)", mod.id, mod.version, mod.folder,
				mod.priority, mod.entry and (", " .. mod.entry .. " @ " .. mod.stage) or "")
		else
			KF.error("could not mount %s", mod.archive)
		end
	end
	check_dependencies(KF.mods)

	KF.run_stage("preload")
end

-- Which main.lua to run after the loader: if a mod ships its own main.lua it is
-- already visible at the root above the archive; otherwise the saved original.
function KF.game_main_path()
	local ok, real = pcall(fs.getRealDirectory, "main.lua")
	local source = fs.getSource()
	if ok and real and real ~= source then
		KF.log("main.lua overridden by a mod (%s)", tostring(real))
		return "main.lua"
	end
	return "modloader/game_main.lua"
end

-- Hooks the boot/loaded stages once the game's main.lua has defined
-- main.set_locale and love.load.
function KF.attach()
	local m = rawget(_G, "main")
	local has_locale = type(m) == "table" and type(m.set_locale) == "function"
	if has_locale then
		KF.wrap(m, "set_locale", function(orig, self, locale)
			local r = orig(self, locale)
			KF.run_stage("boot")
			return r
		end)
	else
		KF.log("main.set_locale not found -- the boot stage runs before love.load")
	end
	local game_load = love.load
	love.load = function(...)
		if not has_locale then KF.run_stage("boot") end
		if game_load then game_load(...) end
		KF.run_stage("boot")
		KF.run_stage("loaded")
		KF.log("startup complete: %d mod(s), %d error(s)", #KF.mods, KF.errors)
	end
end

_G.modloader = KF
return KF
