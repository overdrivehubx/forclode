--!nocheck
--[[
================================================================================
  MollyHub — EQUIP SPAWNER
================================================================================
  Weapons only, with a front end built for the job: search, a filter row, the
  selected item shown large with its picture, the list underneath, an amount and
  one action. Everything on one screen — no scrolling to find a button.

  There is no equip button. Equipping is done by clicking the item in the game's
  own inventory, which is where you would look for it anyway.

  The engine is the harness, loaded headless: it builds its own menu but keeps it
  off screen and publishes _G.MH_API for this front end to drive. Spawning,
  equipping and the skin work all stay in one place rather than being written
  twice.
================================================================================
]]

local BRANCH = "https://raw.githubusercontent.com/overdrivehubx/forclode/"
	.. "claude/trading-ui-offline-harness-vxuc86/"
local RUBIS = "https://api.rubis.app/v2/scrap/D9CpDTMz8Hh4v1wA/raw"

_G.MH_Headless = true          -- the engine's own window stays hidden
_G.MH_SpawnerOnly = true

local function fail(msg)
	warn("[MollyHub] " .. msg)
	pcall(function()
		local gui = Instance.new("ScreenGui")
		gui.Name = "MollyHubError"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true
		gui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
		local f = Instance.new("TextLabel")
		f.Size = UDim2.fromOffset(460, 110); f.Position = UDim2.new(0.5, -230, 0, 60)
		f.BackgroundColor3 = Color3.fromRGB(24, 16, 20); f.BorderSizePixel = 0
		f.TextColor3 = Color3.fromRGB(255, 170, 170); f.Font = Enum.Font.Code
		f.TextSize = 14; f.TextWrapped = true; f.Text = "  [MollyHub] " .. msg
		f.Parent = gui
		Instance.new("UICorner", f).CornerRadius = UDim.new(0, 10)
	end)
end

--== engine ====================================================================
local okSrc, src = pcall(function() return game:HttpGet(BRANCH .. "TradeDebugHarness.luau") end)
if not okSrc or type(src) ~= "string" or #src < 1024 then
	return fail("could not download the engine — check your connection")
end
local literal = RUBIS:gsub("(%W)", "%%%1")
local swapped = src:gsub(literal, (BRANCH .. "MollyUI.luau"):gsub("%%", "%%%%"), 1)
-- the grey photo over everything is the engine's theme code painting BG_IMAGE
swapped = swapped:gsub('local BG_IMAGE = "rbxassetid://%d+"', 'local BG_IMAGE = ""', 1)
local engine, err = loadstring(swapped)
if not engine then return fail("the engine would not compile: " .. tostring(err)) end
local okRun, runErr = pcall(engine)
if not okRun then return fail("the engine errored: " .. tostring(runErr)) end

-- The engine builds its menu inside a task.spawn that downloads the interface
-- first, so the API lands a moment AFTER the chunk returns. Reading it straight
-- away found nothing and reported the engine as broken when it was merely still
-- starting. Wait for it, and only give up after a real timeout.
local API
for _ = 1, 300 do
	API = _G.MH_API
	if type(API) == "table" and type(API.spawn) == "function" then break end
	API = nil
	task.wait(0.1)
end
if not API then
	return fail("the engine never finished starting — its menu library may not have downloaded")
end

--== interface =================================================================
local okUI, UI = pcall(function() return loadstring(game:HttpGet(BRANCH .. "MollyUI.luau"))() end)
if not okUI or type(UI) ~= "table" then return fail("the interface could not be downloaded") end

local Win = UI:CreateWindow({
	Title = "Item Spawner", SubTitle = "Murder Mystery 2", Badge = "MM2", Front = true,
})

--== spawner ===================================================================
local S = Win:Tab({ Title = "Spawner" })

local query, filter, picked, amount = "", "All", nil, 1
local hero, listView

-- Chroma is a flavour rather than a slot, so it gets a chip of its own.
local function passes(it)
	if filter == "All" then return true end
	local d = API.item(it.key)
	local kind = d and d.ItemType or nil
	if filter == "Guns" then return kind == "Gun" end
	if filter == "Knives" then return kind == "Knife" end
	if filter == "Chroma" then
		return tostring(it.name):lower():find("chroma", 1, true) ~= nil or (d and d.Chroma ~= nil)
	end
	return true
end

local function rows()
	local out, total = {}, 0
	for _, it in ipairs(API.rank(query) or {}) do
		if passes(it) then
			total = total + 1
			if #out < 60 then
				local d = API.item(it.key) or {}
				local badges = {}
				if d.ItemType then badges[#badges + 1] = d.ItemType end
				out[#out + 1] = {
					key = it.key, name = it.name, image = d.Image,
					sub = (d.Rarity and (tostring(d.Rarity) .. "  |  ") or "") .. tostring(it.key),
					badges = badges,
				}
			end
		end
	end
	return out, total
end

local function refresh()
	local items, total = rows()
	listView:Set(items, total .. " item" .. (total == 1 and "" or "s")
		.. " in " .. string.lower(filter) .. (total > #items and ("  -  showing " .. #items) or ""))
end

local function choose(it)
	picked = it
	local d = API.item(it.key) or {}
	hero:Set({
		image = d.Image, name = it.name, tag = d.ItemType or "item",
		meta = "Original: " .. tostring(it.key),
		sub = table.concat({ tostring(d.Rarity or "?"), tostring(d.ItemType or "?"),
			tostring(d.Year or d.Event or "MM2") }, "  |  "),
	})
	listView:Select(it.key)
	refresh()
end

S:Search({ Prefix = "find", Placeholder = "Search by name or original id...",
	Callback = function(v) query = v refresh() end })
S:Chips({ Values = { "All", "Guns", "Knives", "Chroma" }, Value = "All",
	Callback = function(v) filter = v refresh() end })
hero = S:Hero({})
listView = S:List({ Height = 300, Fill = true, Min = 150, Max = 460 })
listView:OnPick(function(it) choose(it) end)
S:Slider({ Title = "Amount", Min = 1, Max = 100, Default = 1,
	Callback = function(v) amount = v end })
local function spawnPicked()
	if not picked then return UI:Notify({ Title = "Spawner", Content = "pick an item first" }) end
	API.spawn(picked.name, amount, false)
	UI:Notify({ Title = "Spawned", Content = picked.name .. "  x" .. tostring(amount) })
end
S:Button({ Title = "Spawn selected", Style = "primary", Callback = spawnPicked })
--== skins =====================================================================
local K = Win:Tab({ Title = "Skins" })
local function learnNearby()
	task.spawn(function()
		local learned, total = MH_learnMeshes()
		UI:Notify({ Title = "Skins", Content = "+" .. learned .. " learned, " .. total .. " known" })
	end)
end
local function dropSkin()
	UI:Notify({ Title = "Skins", Content = "restored " .. MH_restoreSkins() .. " mesh(es)" })
end

K:Section({ Title = "Where skins come from" })
K:Button({ Title = "Learn from players nearby", Style = "primary", Callback = learnNearby })
K:Button({ Title = "Learn my whole inventory", Desc = "equips each item you own, takes minutes",
	Callback = function()
		task.spawn(function()
			UI:Notify({ Title = "Skins", Content = "walking your inventory..." })
			local ok, a, b, c, d, why = pcall(MH_learnOwned, function(l, t, tot)
				UI:Notify({ Title = "Skins", Content = l .. " learned / " .. t .. " of " .. tot })
			end)
			UI:Notify({ Title = "Skins", Duration = 9,
				Content = ok and ("+" .. tostring(a) .. " of " .. tostring(b)
					.. " (refused " .. tostring(c) .. ", no display " .. tostring(d) .. ")"
					.. ((tostring(why) ~= "ok") and ("  -  " .. tostring(why)) or ""))
					or ("failed: " .. tostring(a)) })
		end)
	end })
K:Toggle({ Title = "Keep the game's placement",
	Desc = "turn on if a weapon hangs wrong on your body",
	Callback = function(on)
		local n = MH_setPlacement(not on)
		UI:Notify({ Title = "Skins", Content = (on and "the game's own placement" or "the skin's placement")
			.. "  -  " .. tostring(n) .. " repainted" })
	end })

K:Section({ Title = "Undo" })
K:Actions({ Height = 40, Items = {
	{ Title = "Remove skin", Callback = dropSkin },
	{ Title = "Forget them all", Style = "danger", Callback = function()
		MH_restoreSkins()
		UI:Notify({ Title = "Skins", Content = "forgot " .. MH_forgetSkins() .. " entries" })
	end },
} })

--== binds =====================================================================
-- Tap a chip, press a key, and that key runs the action. Escape or Backspace
-- while it is listening clears the bind, and typing in a box never fires one.
local B = Win:Tab({ Title = "Binds" })
B:Section({ Title = "Everything with a key" })
B:Keybind({ Title = "Show or hide the menu", Default = "RightShift",
	OnPress = function() Win:Toggle() end })
B:Keybind({ Title = "Spawn the selected item", Default = "K", OnPress = spawnPicked })
B:Keybind({ Title = "Learn skins nearby", Default = "L", OnPress = learnNearby })
B:Keybind({ Title = "Remove skin", OnPress = dropSkin })
B:Keybind({ Title = "Copy the skin map", OnPress = function()
	local txt = "{}"
	pcall(function() txt = game:GetService("HttpService"):JSONEncode(_G.MH_MeshMap or {}) end)
	pcall(function() setclipboard(txt) end)
	UI:Notify({ Title = "Skins", Content = "copied to clipboard" })
end })

--== go ========================================================================
refresh()

-- the live catalog lands a moment after the engine starts, so fill in when it does
task.spawn(function()
	local seen = select(2, rows())
	for _ = 1, 12 do
		task.wait(1.5)
		local now = select(2, rows())
		if now ~= seen then seen = now refresh() end
	end
end)
