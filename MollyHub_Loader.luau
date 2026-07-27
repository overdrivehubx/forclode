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
	return loadstring(game:HttpGet(BRANCH .. "MollyUI.luau"))()
end)
if not okUI or type(UI) ~= "table" then
	warn("[MollyHub] the interface could not be downloaded — check your connection")
	return
end

local Win = UI:CreateWindow({
	Title = "MollyHub", SubTitle = "Murder Mystery 2  |  loader", Badge = "MH",
})
local Tab = Win:Tab({ Title = "Scripts" })
Tab:Section({ Title = "Choose one" })

local busy = false
for _, s in ipairs(SCRIPTS) do
	Tab:Paragraph({ Title = s.name .. "   [" .. s.tag .. "]", Desc = s.desc })
	Tab:Button({
		Title = "Launch " .. s.name,
		Desc = s.file,
		Callback = function()
			if busy then return end
			busy = true
			UI:Notify({ Title = "MollyHub", Content = "loading " .. s.name .. "..." })
			local fn, err = fetch(BRANCH .. s.file)
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
