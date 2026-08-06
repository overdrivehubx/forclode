--!nocheck
--[[
================================================================================
  MollyHub - TRADE + EQUIP SPAWNER
================================================================================
  Everything in one script: an offline trade that runs inside MM2's OWN trade
  window, the item spawner, and the weapon skins.

  Two engines do the work and neither draws a menu:

    * MollyTrade opens the real TradeGUI, fills it with the game's own inventory
      renderer, and hooks the game's own Accept / Confirm / Cancel / Decline
      buttons. Untradable weapons are stripped out of the local inventory before
      the window is filled, so nothing shows up that a real trade would refuse.

    * MollySkins watches what the game writes down when you equip something and
      welds a rebuilt copy of that weapon over the real one - mesh, texture,
      scope, decals, particles, chroma.

  All of it is on your screen only. Rejoining puts everything back.
================================================================================
]]

local BRANCH = "https://raw.githubusercontent.com/overdrivehubx/forclode/"
	.. "claude/trading-ui-offline-harness-vxuc86/"

-- GitHub keeps a raw file in a cache for minutes at a time, so a script updated
-- just now can arrive as an older build with nothing on screen to say so. A
-- query string GitHub ignores misses that cache, and the executor's too.
local function raw(file)
	return BRANCH .. file .. "?nc=" .. tostring(os.time()) .. "-" .. tostring(math.random(1, 1000000000))
end

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

local function grab(file)
	local ok, body = pcall(function() return game:HttpGet(raw(file)) end)
	if not ok or type(body) ~= "string" or #body < 64 then return nil, "download failed" end
	local fn, err = loadstring(body)
	if not fn then return nil, "compile failed: " .. tostring(err) end
	local okRun, out = pcall(fn)
	if not okRun then return nil, "errored: " .. tostring(out) end
	return out
end

--== engines ===================================================================
-- The weapon data is a megabyte on its own, so it is a separate download and is
-- kept for the session: opening this twice does not fetch it twice.
_G.MH_MeshesURL = raw("MollyMeshes.luau")

local Skins, skinErr = grab("MollySkins.luau")
if type(Skins) ~= "table" then
	return fail("the skin engine could not be loaded - " .. tostring(skinErr))
end
if not Skins.ProfileData then
	return fail("could not reach the game's own inventory - are you in MM2?")
end
Skins.start()

local Trade, tradeErr = grab("MollyTrade.luau")
if type(Trade) ~= "table" then
	return fail("the trade engine could not be loaded - " .. tostring(tradeErr))
end

--== interface =================================================================
local UI, uiErr = grab("MollyUI.luau")
if type(UI) ~= "table" then return fail("the interface could not be downloaded - " .. tostring(uiErr)) end

local Players = game:GetService("Players")

Skins.Status = function(text) UI:Notify({ Title = "Skins", Content = tostring(text), Duration = 4 }) end
Trade.Status = function(text) UI:Notify({ Title = "Trade", Content = tostring(text), Duration = 4 }) end

local Win = UI:CreateWindow({
	Title = "MollyHub", SubTitle = "Murder Mystery 2  |  trade + spawner",
	Badge = "MM2", Front = true,
})

--== trade =====================================================================
-- One screen that reads like the table it drives: who you are with, one way in,
-- both sides of the deal, and the two ways to put something on the table. The
-- item tiles themselves are the game's, in the game's window.
local TT = Win:Tab({ Title = "Trade" })

local function serverNames()
	local out = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= Players.LocalPlayer then out[#out + 1] = p.Name end
	end
	return out
end

local partnerCard = TT:Player({
	Value = Trade.Partner,
	Desc = "tap to pick who you are trading with",
	Values = serverNames,
	Callback = function(v)
		Trade.setPartner(v)
		UI:Notify({ Title = "Trading with", Content = tostring(v) })
	end,
})

TT:Button({ Title = "Open the trade window", Style = "primary",
	Desc = "the game's own window, as if they had invited you",
	Callback = function()
		if not Trade.start() then
			UI:Notify({ Title = "Trade", Content = "already open - close it first" })
		end
	end })

TT:Section({ Title = "The deal" })
local deal = TT:Deal({})

-- Read what the table actually holds rather than what we last pressed. The
-- engine calls OnChange itself, so this is a repaint and not a poll.
local function paint(s)
	s = s or Trade.state()
	deal:Set({
		partner = s.partner, yours = #s.yours, theirs = #s.theirs,
		youAccepted = s.youAccepted, theyAccepted = s.theyAccepted,
	})
	pcall(function() partnerCard:Set(s.partner) end)
end
Trade.OnChange = function(s) pcall(paint, s) end

deal:OnYou(function(on) Trade.acceptYou(on) end)
deal:OnThem(function(on) Trade.acceptThem(on) end)

--== what goes on the table ====================================================
local giveAmount = 1

local function catalogRows()
	local out = {}
	for _, it in ipairs(Trade.Catalog) do
		out[#out + 1] = { value = it.key, text = it.name, image = it.image,
			sub = tostring(it.rarity) .. "   " .. tostring(it.type) }
	end
	return out
end

local function mineRows()
	local out = {}
	for _, e in ipairs(Trade.mine()) do
		out[#out + 1] = { value = e.key, text = e.name, image = e.image,
			sub = "x" .. tostring(e.count) .. "   " .. tostring(e.rarity) }
	end
	return out
end

local function addMine()
	local rows = mineRows()
	if #rows == 0 then
		return UI:Notify({ Title = "Your items", Content = "nothing tradable in your inventory yet" })
	end
	TT:Pick({ Title = "Your items", Values = rows, Noun = "item", Callback = function(v)
		for _ = 1, giveAmount do Trade.offer(v) end
		UI:Notify({ Title = "On your side", Content = tostring(v) .. "  x" .. tostring(giveAmount) })
	end })
end

local function giveThem()
	TT:Pick({ Title = "Give them", Values = catalogRows(), Noun = "item", Callback = function(v)
		local ok = false
		for _ = 1, giveAmount do ok = Trade.offerTheirs(v) or ok end
		UI:Notify({ Title = ok and "On their side" or "No room",
			Content = ok and (tostring(v) .. "  x" .. tostring(giveAmount))
				or "four stacks a side is the limit, same as the game" })
	end })
end

TT:Actions({ Items = {
	{ Title = "Add your items", Desc = "from your real inventory", Callback = addMine },
	{ Title = "Give them an item", Desc = "anything tradable in the game", Callback = giveThem },
} })
TT:Slider({ Title = "How many", Min = 1, Max = 100, Default = 1,
	Callback = function(v) giveAmount = v end })

TT:Actions({ Height = 40, Items = {
	{ Title = "Skip the wait", Desc = "the six seconds before Accept works",
		Callback = function()
			Trade.skipCooldown()
			UI:Notify({ Title = "Trade", Content = "you can accept now" })
		end },
	{ Title = "Clear their side", Callback = function()
		Trade.removeTheirs(nil)
		UI:Notify({ Title = "Trade", Content = "their side emptied" })
	end },
	{ Title = "Close", Style = "danger", Callback = function() Trade.decline() end },
} })

TT:Section({ Title = "What a real trade would refuse" })
local tradable, refused = Trade.counts()
TT:Paragraph({
	Title = "Untradables are removed, not hidden",
	Desc = tradable .. " weapons can be traded and " .. refused .. " cannot. The four Evo "
		.. "gamepass families are untradable at every stage, Unique rarity is untradable "
		.. "except Corrupt, and anything with no entry in the weapon database is what the "
		.. "game draws as \"???\". They are taken out of your local inventory before the "
		.. "window fills, so no tile is ever built for one.",
})
TT:Button({ Title = "Clean my inventory now",
	Desc = "does what opening the window does, on its own",
	Callback = function()
		local n = Trade.purge()
		UI:Notify({ Title = "Trade", Duration = 7,
			Content = (n == 0) and "nothing to remove - your inventory is already tradable"
				or ("removed " .. n .. " item" .. (n == 1 and "" or "s") .. " a real trade would refuse") })
	end })

--== spawner ===================================================================
local S = Win:Tab({ Title = "Spawner" })

local all = Skins.list()
local query, filter, picked, amount = "", "All", nil, 1
local hero, listView

local function passes(it)
	if filter == "All" then return true end
	if filter == "Guns" then return it.type == "Gun" end
	if filter == "Knives" then return it.type == "Knife" end
	if filter == "Chroma" then return tostring(it.name):lower():find("chroma", 1, true) ~= nil end
	if filter == "Wearable" then return it.skin end
	if filter == "Tradable" then return Trade.ByKey[it.key] ~= nil end
	return true
end

local function rows()
	local q = tostring(query):lower()
	local out, total = {}, 0
	for _, it in ipairs(all) do
		local hit = (q == "")
			or tostring(it.name):lower():find(q, 1, true) ~= nil
			or tostring(it.key):lower():find(q, 1, true) ~= nil
		if hit and passes(it) then
			total = total + 1
			if #out < 120 then
				local badges = { it.type }
				if not it.skin then badges[#badges + 1] = "no skin" end
				if Trade.Blocked[it.key] then badges[#badges + 1] = "untradable" end
				out[#out + 1] = {
					key = it.key, name = it.name, image = it.image,
					sub = tostring(it.rarity) .. "  |  " .. tostring(it.key),
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
	local info = Skins.WeaponDB and Skins.WeaponDB[it.key] or {}
	local why = Trade.Blocked[it.key]
	hero:Set({
		image = it.image, name = it.name, tag = info.ItemType or "item",
		meta = "Original: " .. tostring(it.key),
		sub = table.concat({ tostring(info.Rarity or "?"),
			Skins.has(it.key) and "wearable" or "no skin data",
			why and ("untradable - " .. why) or "tradable" }, "  |  "),
	})
	listView:Select(it.key)
	refresh()
end

S:Search({ Prefix = "find", Placeholder = "Search by name or original id...",
	Callback = function(v) query = v refresh() end })
S:Chips({ Values = { "All", "Guns", "Knives", "Chroma", "Wearable", "Tradable" }, Value = "All",
	Callback = function(v) filter = v refresh() end })
hero = S:Hero({})
listView = S:List({ Height = 280, Fill = true, Min = 150, Max = 440 })
listView:OnPick(function(it) choose(it) end)
S:Slider({ Title = "Amount", Min = 1, Max = 100, Default = 1,
	Callback = function(v) amount = v end })

local function spawnPicked()
	if not picked then return UI:Notify({ Title = "Spawner", Content = "pick an item first" }) end
	Skins.spawn(picked.key, amount)
	UI:Notify({ Title = "Spawned", Content = picked.name .. "  x" .. tostring(amount)
		.. "  -  equip it from the game's inventory" })
end
local function wearPicked()
	if not picked then return UI:Notify({ Title = "Spawner", Content = "pick an item first" }) end
	Skins.spawn(picked.key, 1)
	Skins.equip(picked.key)
end
local function offerPicked()
	if not picked then return UI:Notify({ Title = "Spawner", Content = "pick an item first" }) end
	if Trade.Blocked[picked.key] then
		return UI:Notify({ Title = "Trade", Duration = 7,
			Content = picked.name .. " cannot be traded - " .. Trade.Blocked[picked.key] })
	end
	for _ = 1, amount do Trade.offerTheirs(picked.key) end
	UI:Notify({ Title = "On their side", Content = picked.name .. "  x" .. tostring(amount) })
end

S:Button({ Title = "Spawn selected", Style = "primary", Callback = spawnPicked })
S:Actions({ Items = {
	{ Title = "Spawn and wear it", Desc = "equips it for you", Callback = wearPicked },
	{ Title = "Put it on their side", Desc = "into the open trade", Callback = offerPicked },
} })

--== skins =====================================================================
local K = Win:Tab({ Title = "Skins" })
local known, full = Skins.counts()

K:Paragraph({
	Title = "How this works",
	Desc = "Every weapon here is built the way the game builds it - mesh, texture, "
		.. "scope, decals, particles, chroma - and welded over the real one, which "
		.. "is hidden for you only. Equipping from the game's own inventory is "
		.. "noticed by watching what it writes down, not by waiting for it to "
		.. "announce anything, which is why it does not miss.",
})
K:Section({ Title = "What is known" })
K:Button({ Title = "Count the weapons I can wear",
	Callback = function()
		local n, f = Skins.counts()
		UI:Notify({ Title = "Skins", Duration = 8,
			Content = n .. " weapons, " .. f .. " of them whole models" })
	end })
K:Button({ Title = "Check the selected item",
	Callback = function()
		if not picked then return UI:Notify({ Title = "Skins", Content = "pick an item first" }) end
		UI:Notify({ Title = "Skins", Duration = 8,
			Content = picked.name .. ": " .. (Skins.has(picked.key)
				and "wearable" or "no skin data for this one") })
	end })

K:Section({ Title = "Undo" })
K:Toggle({ Title = "Hide the real weapon", Value = true,
	Desc = "off = the copy sits over the top of it",
	Callback = function(on) Skins.HideOriginal = on Skins.clearAll() end })
K:Actions({ Height = 40, Items = {
	{ Title = "Take the skin off", Callback = function()
		Skins.clearAll()
		UI:Notify({ Title = "Skins", Content = "back to what you really have on" })
	end },
	{ Title = "Stop the engine", Style = "danger", Callback = function()
		Skins.stop()
		UI:Notify({ Title = "Skins", Content = "stopped - re-run the script to start it again" })
	end },
} })

--== binds =====================================================================
-- Every action worth a key, in one place. Tap a chip, press a key; Escape or
-- Backspace while it is listening clears the bind. Presses are ignored while
-- you are typing in a box.
local B = Win:Tab({ Title = "Binds" })
B:Section({ Title = "Menu and trade" })
B:Keybind({ Title = "Show or hide the menu", Default = "RightShift",
	OnPress = function() Win:Toggle() end })
B:Keybind({ Title = "Open the trade window", Default = "F",
	OnPress = function() Trade.start() end })
B:Keybind({ Title = "They accept", Default = "G",
	OnPress = function() Trade.acceptThem(true) end })
B:Keybind({ Title = "You accept", Default = "H",
	OnPress = function() Trade.acceptYou(true) end })
B:Keybind({ Title = "Skip the wait", OnPress = function() Trade.skipCooldown() end })
B:Keybind({ Title = "Add your items", OnPress = addMine })
B:Keybind({ Title = "Give them an item", OnPress = giveThem })
B:Keybind({ Title = "Clear their side", Default = "J",
	OnPress = function() Trade.removeTheirs(nil) end })
B:Keybind({ Title = "Close the trade", OnPress = function() Trade.decline() end })

B:Section({ Title = "Spawner and skins" })
B:Keybind({ Title = "Spawn the selected item", Default = "K", OnPress = spawnPicked })
B:Keybind({ Title = "Spawn and wear it", Default = "L", OnPress = wearPicked })
B:Keybind({ Title = "Take the skin off", OnPress = function() Skins.clearAll() end })

--== go ========================================================================
refresh()
paint()
UI:Notify({ Title = "MollyHub", Duration = 7,
	Content = known .. " weapons ready, " .. full .. " of them whole models, "
		.. tradable .. " tradable" })
