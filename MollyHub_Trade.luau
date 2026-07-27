--!nocheck
--[[
================================================================================
  MollyHub — TRADE + EQUIP SPAWNER
================================================================================
  The full sandbox with a front end built for it: a Trade screen (partner,
  request, accept, overlay) and the Spawner screen, both on one page each.

  The engine is the harness, loaded headless — it builds its own menu but keeps
  it off screen and publishes _G.MH_API. Nothing here reimplements the trade or
  spawn logic; it only drives it. TradeDebugHarness.luau is otherwise untouched
  and still works on its own as a fallback.
================================================================================
]]

local BRANCH = "https://raw.githubusercontent.com/overdrivehubx/forclode/"
	.. "claude/trading-ui-offline-harness-vxuc86/"
local RUBIS = "https://api.rubis.app/v2/scrap/D9CpDTMz8Hh4v1wA/raw"

_G.MH_Headless = true

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
	return fail("could not download the harness — check your connection")
end
-- Point the harness at our interface. The url is escaped into a literal pattern:
-- "." and friends would otherwise be wildcards, and a replace that quietly
-- matched the wrong thing is worse than one that does not match.
local literal = RUBIS:gsub("(%W)", "%%%1")
local swapped, n = src:gsub(literal, (BRANCH .. "MollyUI.luau"):gsub("%%", "%%%%"), 1)
if n == 0 then
	warn("[MollyHub] menu swap did not apply — falling back to the bundled menu")
	swapped = src
end
-- the grey photo over everything is the harness's theme code painting BG_IMAGE
swapped = swapped:gsub('local BG_IMAGE = "rbxassetid://%d+"', 'local BG_IMAGE = ""', 1)
local engine, err = loadstring(swapped)
if not engine then return fail("the harness would not compile: " .. tostring(err)) end
local okRun, runErr = pcall(engine)
if not okRun then return fail("the harness errored: " .. tostring(runErr)) end

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
	Title = "MollyHub", SubTitle = "Murder Mystery 2  |  trade sandbox",
	Badge = "MM2", Front = true,
})

--== trade =====================================================================
local T = Win:Tab({ Title = "Trade" })

T:Section({ Title = "Partner" })
local partnerRow = T:Paragraph({ Title = "Player 2", Desc = tostring(API.partner and API.partner() or "Player2") })
local function showPartner()
	pcall(function() partnerRow:Set(tostring(API.partner())) end)
end

-- Picking who to trade with opens its own panel, listing the server.
T:Dropdown({
	Title = "Choose from the server", Values = API.players and API.players() or {},
	Callback = function(v)
		API.setPartner(tostring(v))
		showPartner()
		UI:Notify({ Title = "Partner", Content = tostring(v) })
	end,
})
T:Input({
	Title = "...or type a name", Placeholder = "name",
	Callback = function(v) API.setPartner(v) showPartner() end,
})

T:Section({ Title = "Request" })
T:Button({ Title = "Incoming request", Desc = "they send YOU one", Style = "primary",
	Callback = function() API.request(true) end })
T:Button({ Title = "Outgoing request", Desc = "you send one, and wait",
	Callback = function() API.request(false) end })

T:Section({ Title = "Accept" })
T:Toggle({ Title = "You accepted", Desc = "your side of the table",
	Callback = function(on) API.acceptP1(on) end })
T:Toggle({ Title = "They accepted", Desc = "the other side — this is the one you want",
	Callback = function(on) _G.MH_ForceP2Accept = on and true or false end })
T:Toggle({ Title = "Overlay on a real trade", Desc = "fake items on your side, visual only",
	Callback = function(on) API.overlay(on) end })

T:Section({ Title = "Danger" })
T:Button({ Title = "Terminate and wipe", Style = "danger", Callback = function() API.terminate() end })

--== spawner ===================================================================
local S = Win:Tab({ Title = "Spawner" })

local query, filter, picked, amount, toP2 = "", "All", nil, 1, false
local hero, listView

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
				out[#out + 1] = { key = it.key, name = it.name, image = d.Image,
					sub = (d.Rarity and (tostring(d.Rarity) .. "  |  ") or "") .. tostring(it.key),
					badges = badges }
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

S:Search({ Prefix = "find", Placeholder = "Search by name or original id...",
	Callback = function(v) query = v refresh() end })
S:Chips({ Values = { "All", "Guns", "Knives", "Chroma" }, Value = "All",
	Callback = function(v) filter = v refresh() end })
hero = S:Hero({})
listView = S:List({ Height = 260 })
listView:OnPick(function(it)
	picked = it
	local d = API.item(it.key) or {}
	hero:Set({ image = d.Image, name = it.name, tag = d.ItemType or "item",
		meta = "Original: " .. tostring(it.key),
		sub = table.concat({ tostring(d.Rarity or "?"), tostring(d.ItemType or "?"),
			tostring(d.Year or d.Event or "MM2") }, "  |  ") })
	listView:Select(it.key)
	refresh()
end)
S:Slider({ Title = "Amount", Min = 1, Max = 100, Default = 1,
	Callback = function(v) amount = v end })
S:Toggle({ Title = "Into their side", Desc = "spawn onto Player 2's offer instead",
	Callback = function(on) toP2 = on end })
S:Button({ Title = "Spawn selected", Style = "primary", Callback = function()
	if not picked then return UI:Notify({ Title = "Spawner", Content = "pick an item first" }) end
	API.spawn(picked.name, amount, toP2)
end })

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
K:Section({ Title = "Fixes" })
K:Toggle({ Title = "Keep the game's placement",
	Desc = "turn on if a weapon hangs wrong on your body",
	Callback = function(on)
		local n = MH_setPlacement(not on)
		UI:Notify({ Title = "Skins", Content = (on and "the game's own placement" or "the skin's placement")
			.. "  -  " .. tostring(n) .. " repainted" })
	end })

K:Section({ Title = "Undo" })
K:Button({ Title = "Remove skin", Style = "danger", Callback = function()
	UI:Notify({ Title = "Skins", Content = "restored " .. MH_restoreSkins() .. " mesh(es)" })
end })
K:Button({ Title = "Forget learned skins", Style = "danger", Callback = function()
	MH_restoreSkins()
	UI:Notify({ Title = "Skins", Content = "forgot " .. MH_forgetSkins() .. " entries" })
end })

--== go ========================================================================
refresh()
showPartner()

task.spawn(function()
	local seen = select(2, rows())
	for _ = 1, 12 do
		task.wait(1.5)
		local now = select(2, rows())
		if now ~= seen then seen = now refresh() end
	end
end)
