--!nocheck
--[[
================================================================================
  MollyHub — LOADER
================================================================================
  Pick which script to run. Nothing is fetched until you press Launch, so
  opening this costs one small download.

    loadstring(game:HttpGet("<raw url>/MollyHub_Loader.luau"))()

  Each entry below is fetched from the same branch this loader came from, so a
  loader you have pinned keeps loading the versions it was built against.
================================================================================
]]

local BRANCH = "https://raw.githubusercontent.com/overdrivehubx/forclode/"
	.. "claude/trading-ui-offline-harness-vxuc86/"

-- GitHub serves a raw file from a cache for several minutes, and some executors
-- keep their own copy on top of that — so a script updated a minute ago can be
-- downloaded as yesterday's build, with nothing on screen to say so. A query
-- string GitHub ignores is enough to miss both caches, so every fetch below is
-- genuinely the file that is on the branch right now.
local function raw(file)
	return BRANCH .. file .. "?nc=" .. tostring(os.time()) .. "-" .. tostring(math.random(1, 1000000000))
end

local SCRIPTS = {
	{
		name = "Trade + Equip Spawner",
		file = "MollyHub_Trade.luau",
		desc = "The full sandbox: offline fake trades over the real trade GUI, "
			.. "the item spawner, and client-side weapon skins.",
		tag = "FULL",
	},
	{
		name = "Equip Spawner",
		file = "MollyHub_Spawner.luau",
		desc = "Weapons only — spawn an item and wear its real skin, on your "
			.. "body and in your hand. No trade tabs.",
		tag = "LIGHT",
	},
	{
		name = "MollyHub",
		file = "MollyHub_MM2.luau",
		desc = "The whole game: roles, sheriff and murderer tools, ESP, farming, "
			.. "teleports, player tweaks and trolling.",
		tag = "HUB",
	},
}

local function fetch(url)
	local ok, body = pcall(function() return game:HttpGet(url) end)
	if not ok or type(body) ~= "string" or #body < 64 then
		return nil, "download failed"
	end
	local fn, err = loadstring(body)
	if not fn then return nil, "compile failed: " .. tostring(err) end
	return fn
end

local okUI, UI = pcall(function()
	return loadstring(game:HttpGet(raw("MollyUI.luau")))()
end)
if not okUI or type(UI) ~= "table" then
	warn("[MollyHub] the interface could not be downloaded — check your connection")
	return
end

local Win = UI:CreateWindow({
	Title = "MollyHub", SubTitle = "Murder Mystery 2  |  loader", Badge = "MH",
	Compact = true,
})
local Tab = Win:Tab({ Title = "Scripts" })
Tab:Section({ Title = "Choose one" })

local busy = false
for _, s in ipairs(SCRIPTS) do
	Tab:Button({
		Title = s.name,
		Desc = s.desc,
		Style = "primary",
		Callback = function()
			if busy then return end
			busy = true
			UI:Notify({ Title = "MollyHub", Content = "loading " .. s.name .. "..." })
			local fn, err = fetch(raw(s.file))
			if not fn then
				busy = false
				UI:Notify({ Title = "Failed", Content = tostring(err), Duration = 8 })
				return
			end
			-- the loader steps aside so two menus never share the screen
			pcall(function() Win:Destroy() end)
			local okRun, runErr = pcall(fn)
			if not okRun then
				busy = false
				warn("[MollyHub] " .. s.file .. " errored: " .. tostring(runErr))
				UI:Notify({ Title = "Script error", Content = tostring(runErr), Duration = 10 })
			end
		end,
	})
end

UI:Notify({ Title = "MollyHub", Content = "pick a script to launch" })
