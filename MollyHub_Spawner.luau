--!nocheck
--[[
================================================================================
  MollyHub — EQUIP SPAWNER
================================================================================
  Weapons only, with a front end built for the job: search, a filter row, the
  selected item shown large with its picture, the list underneath, an amount and
  one action. Everything on one screen — no scrolling to find a button.

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

local API = _G.MH_API
if type(API) ~= "table" then return fail("the engine did not publish its API") end

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
listView = S:List({ Height = 208 })
listView:OnPick(function(it) choose(it) end)
S:Slider({ Title = "Amount", Min = 1, Max = 100, Default = 1,
	Callback = function(v) amount = v end })
S:Button({
	Title = "Spawn selected", Style = "primary",
	Callback = function()
		if not picked then return UI:Notify({ Title = "Spawner", Content = "pick an item first" }) end
		API.spawn(picked.name, amount, false)
		UI:Notify({ Title = "Spawned", Content = picked.name .. "  x" .. tostring(amount) })
	end,
})
S:Button({
	Title = "Equip selected", Desc = "wear its skin, if one is known",
	Callback = function()
		if not picked then return UI:Notify({ Title = "Equip", Content = "pick an item first" }) end
		task.spawn(function()
			API.spawn(picked.name, 1, false)
			local ok, detail, how = API.equip(picked.key, picked.name)
			pcall(function() setclipboard("MH EQUIP: " .. tostring(detail)) end)
			UI:Notify({ Title = picked.name,
				Content = ok and ("worn  [" .. tostring(how) .. "]") or "no skin known yet" })
		end)
	end,
})

--== skins =====================================================================
local K = Win:Tab({ Title = "Skins" })
K:Section({ Title = "Where skins come from" })
K:Button({ Title = "Learn from players nearby", Style = "primary", Callback = function()
	task.spawn(function()
		local learned, total = MH_learnMeshes()
		UI:Notify({ Title = "Skins", Content = "+" .. learned .. " learned, " .. total .. " known" })
	end)
end })
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
K:Section({ Title = "Undo" })
K:Button({ Title = "Remove skin", Style = "danger", Callback = function()
	UI:Notify({ Title = "Skins", Content = "restored " .. MH_restoreSkins() .. " mesh(es)" })
end })
K:Button({ Title = "Forget learned skins", Style = "danger", Callback = function()
	MH_restoreSkins()
	UI:Notify({ Title = "Skins", Content = "forgot " .. MH_forgetSkins() .. " entries" })
end })
K:Button({ Title = "Copy skin map", Callback = function()
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
