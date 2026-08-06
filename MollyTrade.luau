--!nocheck
--[[
================================================================================
  MollyTrade - an offline trade that uses the game's own trade window
================================================================================
  Ported from a build that works. The difference from what we had is the whole
  point: this does not draw a trade of its own. It opens MM2's REAL TradeGUI,
  fills it with MM2's own inventory renderer, and hooks MM2's own Accept,
  Confirm, Cancel and Decline buttons. So it looks like a trade because it IS
  the trade window - only the partner and their side of it are ours.

  Three things it gets right that a hand-drawn copy cannot:

    * the item tiles are built by InventoryModule.GenerateInventory and
      ItemModule.DisplayItem, so every icon, name, rarity colour and amount is
      the game's own;
    * the accept flow is the game's, cooldown included, so it behaves the way
      the muscle memory expects;
    * untradable weapons are stripped out of the local inventory BEFORE the
      window is filled, so nothing appears that the real trade would refuse -
      Unique rarity (Corrupt excepted), the four Evo gamepass families at every
      stage, and anything with no entry in the weapon database, which is exactly
      what the game renders as "???".

  Everything is written to the local copy of ProfileData. Nobody else sees any
  of it and rejoining puts it all back.
================================================================================
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer       = Players.LocalPlayer

local T = {}
T.Partner = "Player2"
T.Status = nil               -- function(text) to hear about it
T.MaxOffer = 4               -- the game's own limit

local function say(text)
	if type(T.Status) == "function" then pcall(T.Status, tostring(text)) end
end

--== the game's own modules ====================================================
local ProfileData, InventoryModule, ItemModule, Sync, ItemPopupService
local TradeGUI, TheirOffer, YourOffer, InvDataChanged

pcall(function() if setthreadidentity then setthreadidentity(2) end end)
pcall(function() ProfileData = require(ReplicatedStorage.Modules.ProfileData) end)
pcall(function() InventoryModule = require(ReplicatedStorage.Modules.InventoryModule) end)
pcall(function() ItemModule = require(ReplicatedStorage.Modules.ItemModule) end)
pcall(function() Sync = require(ReplicatedStorage.Database.Sync) end)
pcall(function() ItemPopupService = require(ReplicatedStorage.ClientServices.ItemPopupService) end)
pcall(function() if setthreadidentity then setthreadidentity(8) end end)
pcall(function()
	InvDataChanged = ReplicatedStorage.Remotes.Inventory.InventoryDataChanged
end)
pcall(function()
	TradeGUI = LocalPlayer.PlayerGui:WaitForChild("TradeGUI", 10)
	TheirOffer = TradeGUI.Container.Trade.TheirOffer
	YourOffer = TradeGUI.Container.Trade.YourOffer
end)

T.ProfileData, T.Sync, T.TradeGUI = ProfileData, Sync, TradeGUI
T.Ready = (ProfileData ~= nil and InventoryModule ~= nil and TradeGUI ~= nil)

--== what the real trade would refuse ==========================================
local UntradableRarities = { Unique = true }
local UntradableRarityExceptions = { corrupt = true }
-- the four Evo gamepass weapons are untradable at EVERY stage, so they are
-- matched by family name rather than by rarity
local UntradableFamilies = { "reaver", "gingerscythe", "icecrusher", "synthwave" }
local EvoPrefixes = {
	Blue = true, Bronze = true, Silver = true, Gold = true, Platinum = true,
	Diamond = true, Emerald = true, Ruby = true, Obsidian = true, Crystal = true,
}

local function flatten(s)
	return (string.gsub(string.lower(tostring(s or "")), "[^%a%d]", ""))
end

local function isEvo(name, data)
	if type(data) == "table" then
		if data.Evo == true or data.Evolution == true then return true end
		if data.IsEvo == true or data.EvoTier ~= nil then return true end
		if type(data.MaxStack) == "number" and data.MaxStack <= 1 then return true end
		if type(data.MaxAmount) == "number" and data.MaxAmount <= 1 then return true end
	end
	local first = name and string.match(tostring(name), "^(%S+)")
	return first ~= nil and EvoPrefixes[first] == true
end

local function saysTradable(data)
	if type(data) ~= "table" then return false end
	if data.Tradable == false or data.CanTrade == false then return false end
	if data.Untradable == true or data.NonTradable == true then return false end
	if data.Locked == true then return false end
	return true
end

-- nil when the weapon is fine, otherwise why it is not
function T.blockReason(name, rarity, data)
	local flat = flatten(name)
	if flat == "" or string.find(tostring(name or ""), "?", 1, true) then
		return "unreleased placeholder"
	end
	for _, family in ipairs(UntradableFamilies) do
		if string.find(flat, family, 1, true) then
			return "Evo gamepass weapon, untradable at every stage"
		end
	end
	if UntradableRarities[rarity] and not UntradableRarityExceptions[flat] then
		return "untradable " .. tostring(rarity)
	end
	if not saysTradable(data) then return "the game data says untradable" end
	if isEvo(name, data) then return "Evo or leaderboard variant" end
	return nil
end

local Blocked, Catalog, ByKey = {}, {}, {}
do
	local source = (Sync and (Sync.Weapons or Sync.Item)) or {}
	local RARE = { Godly = true, Ancient = true, Unique = true, Chroma = true,
		Legendary = true, Classic = true }
	for key, data in pairs(source) do
		if type(data) == "table" and (data.ItemType == "Knife" or data.ItemType == "Gun") then
			local rarity = data.Rarity or "Common"
			local name = data.ItemName or key
			local why = T.blockReason(name, rarity, data)
			if why then
				Blocked[key] = why
			else
				local entry = {
					key = key, name = name, type = data.ItemType,
					rarity = (data.Chroma == true) and "Chroma" or rarity,
					chroma = data.Chroma == true, image = data.Image,
					rare = RARE[(data.Chroma == true) and "Chroma" or rarity] == true,
				}
				Catalog[#Catalog + 1] = entry
				ByKey[key] = entry
			end
		end
	end
	local order = { Chroma = 1, Godly = 2, Ancient = 3, Unique = 4, Legendary = 5,
		Classic = 6, Vintage = 7, Rare = 8, Uncommon = 9, Common = 10 }
	table.sort(Catalog, function(a, b)
		local ra, rb = order[a.rarity] or 99, order[b.rarity] or 99
		if ra ~= rb then return ra < rb end
		if a.type ~= b.type then return a.type < b.type end
		return a.name < b.name
	end)
end
T.Catalog, T.Blocked, T.ByKey = Catalog, Blocked, ByKey

--== the inventory =============================================================
-- Owned is not always a plain name -> amount map, so read whichever shape it is
local function ownedEntry(k, v)
	if type(k) == "string" and type(v) == "number" then return k, v end
	if type(v) == "table" then
		local key = v.ItemID or v.Id or v.Name or v.Item
		if key then return key, v.Amount or v.Count or 1 end
	end
	if type(v) == "string" then return v, 1 end
	return nil
end

-- Strips out of the LOCAL copy anything the real trade would refuse, so it can
-- never appear in the window or be put into an offer. Rejoining restores it.
function T.purge()
	local removed = 0
	pcall(function()
		local owned = ProfileData.Weapons.Owned
		if type(owned) ~= "table" then return end
		local kill = {}
		for k, v in pairs(owned) do
			local key = ownedEntry(k, v)
			if key then
				local data = Sync and Sync.Weapons and Sync.Weapons[key]
				local name = (type(data) == "table" and data.ItemName) or tostring(key)
				local why = (type(data) ~= "table")
					and "no entry in the weapon database, the game shows it as ???"
					or T.blockReason(name, data.Rarity or "Common", data)
				if why then kill[#kill + 1] = k end
			end
		end
		for _, k in ipairs(kill) do
			owned[k] = nil
			removed = removed + 1
		end
	end)
	if removed > 0 then pcall(function() InvDataChanged:Fire() end) end
	return removed
end

function T.spawn(name, amount, itemType)
	amount = amount or 1
	itemType = itemType or "Weapons"
	if itemType == "Weapons" and Blocked[name] then
		say("the real trade would refuse " .. tostring(name) .. ": " .. Blocked[name])
		return false
	end
	local ok = pcall(function()
		local owned = ProfileData[itemType].Owned
		owned[name] = (owned[name] or 0) + amount
		InvDataChanged:Fire()
	end)
	return ok
end

local function giveItem(name, amount, itemType)
	pcall(function()
		local owned = ProfileData[itemType].Owned
		owned[name] = (owned[name] or 0) + amount
		if ItemPopupService then ItemPopupService.ItemReceived:Fire(name, itemType) end
		InvDataChanged:Fire()
	end)
end

local function takeItem(name, amount, itemType)
	pcall(function()
		local owned = ProfileData[itemType].Owned[name]
		if not owned then return end
		if owned - amount > 0 then
			ProfileData[itemType].Owned[name] = owned - amount
		else
			ProfileData[itemType].Owned[name] = nil
		end
		InvDataChanged:Fire()
	end)
end

local function haveItem(name, itemType)
	local owned = ProfileData and ProfileData[itemType] and ProfileData[itemType].Owned
	if type(owned) ~= "table" then return false, 0 end
	for k, v in pairs(owned) do
		if k == name then return true, v end
		if v == name then return true, 1 end
	end
	return false, 0
end

--== the trade itself ==========================================================
local Trade, tileConns, conns, inTrade = nil, {}, {}, false
local TradeInventory, searchConn
local acceptStage, acceptAt, cooldown, counting = "Accept", 0, 6, false

local function blank(partner)
	return {
		LastOffer = os.time(),
		Locked = false,
		Player1 = { Player = LocalPlayer, Accepted = false, Offer = {} },
		Player2 = { Player = partner or T.Partner, Accepted = false, Offer = {} },
	}
end
Trade = blank()
T.Table = Trade

function T.state()
	return {
		open = inTrade,
		partner = tostring(Trade.Player2.Player),
		yours = Trade.Player1.Offer,
		theirs = Trade.Player2.Offer,
		youAccepted = Trade.Player1.Accepted,
		theyAccepted = Trade.Player2.Accepted,
		locked = Trade.Locked,
	}
end

local function hideRows(frame)
	for _, f in pairs(frame:GetChildren()) do
		if f:IsA("Frame") then
			f.Visible = false
			if tileConns[f] then tileConns[f]:Disconnect() tileConns[f] = nil end
		end
	end
end

-- Draw one side's offer with the game's own item renderer, so a tile in the
-- trade looks exactly like a tile anywhere else in MM2.
local function drawOffer(side, offer, mine)
	for i, item in pairs(offer) do
		local key = item[1] or item.ItemID
		local amount = item[2] or item.Amount
		local itemType = item[3] or item.ItemType
		local slot = side.Container["NewItem" .. i]
		if slot then
			pcall(function()
				if Sync[itemType] and Sync[itemType][key] then
					local copy = {}
					for k, v in pairs(Sync[itemType][key]) do copy[k] = v end
					copy.DataType = itemType
					copy.Amount = amount
					ItemModule.DisplayItem(slot, copy)
				end
			end)
			pcall(function()
				if tileConns[slot] then tileConns[slot]:Disconnect() end
				if slot.Container and slot.Container:FindFirstChild("ActionButton") then
					tileConns[slot] = slot.Container.ActionButton.MouseButton1Click:Connect(function()
						if mine then T.removeYours(key, itemType) else T.removeTheirs(key, itemType) end
					end)
				end
			end)
			slot.Visible = true
		end
	end
end

local function resetCooldown(skip)
	pcall(function()
		local box = TradeGUI.Container.Trade.Actions.Accept.Cooldown
		if skip then
			box.Visible = false
			cooldown = 0
			counting = false
			return
		end
		box.Visible = true
		cooldown = 6
		box.Title.Text = " Please wait (" .. cooldown .. ") before accepting."
		if counting then return end
		counting = true
		task.spawn(function()
			repeat
				task.wait(1)
				cooldown = cooldown - 1
				pcall(function()
					box.Title.Text = " Please wait (" .. cooldown .. ") before accepting."
				end)
			until cooldown <= 0
			counting = false
			pcall(function() box.Visible = false end)
		end)
	end)
end

-- grey out what is already in your offer, the way the game does
local function updateInventoryCounts()
	pcall(function()
		if not TradeInventory or not TradeInventory.Data then return end
		local offer = Trade.Player1.Offer
		for itemType, group in pairs(TradeInventory.Data) do
			for _, bucket in pairs(group) do
				for key, entry in pairs(bucket) do
					local frame, left = entry.Frame, entry.Amount
					for _, item in pairs(offer) do
						if (item[1] or item.ItemID) == key
							and (item[3] or item.ItemType) == itemType then
							left = left - (item[2] or item.Amount)
						end
					end
					if left == 1 then
						frame.Container.Amount.Text = ""
						frame.Visible = true
					elseif left > 1 then
						frame.Container.Amount.Text = "x" .. left
						frame.Visible = true
					else
						frame.Visible = false
					end
				end
			end
		end
	end)
end

function T.refresh()
	pcall(function()
		hideRows(YourOffer.Container)
		hideRows(TheirOffer.Container)
		drawOffer(YourOffer, Trade.Player1.Offer, true)
		drawOffer(TheirOffer, Trade.Player2.Offer, false)
		acceptStage = "Accept"
		TradeGUI.Container.Trade.Actions.Accept.Confirm.Visible = false
		TradeGUI.Container.Trade.Actions.Accept.Cancel.Visible = false
		YourOffer.Accepted.Visible = Trade.Player1.Accepted
		TheirOffer.Accepted.Visible = Trade.Player2.Accepted
		local empty = (#Trade.Player1.Offer < 1) and (#Trade.Player2.Offer < 1)
		TradeGUI.Container.Trade.Actions.Accept.AddItem.Visible = empty
		updateInventoryCounts()
		resetCooldown(empty)
	end)
	if type(T.OnChange) == "function" then pcall(T.OnChange, T.state()) end
end

-- The game makes you wait six seconds before accepting. In a trade with nobody
-- that is just six seconds, so it can be skipped.
function T.skipCooldown()
	resetCooldown(true)
end

--== offers ====================================================================
function T.offer(key, itemType)
	itemType = itemType or "Weapons"
	if Trade.Locked then return false end
	local already = 0
	for _, item in pairs(Trade.Player1.Offer) do
		if item[1] == key and item[3] == itemType then already = item[2] end
	end
	local have, amount = haveItem(key, itemType)
	if have and amount - already > 0 then
		if already == 0 then
			if #Trade.Player1.Offer < T.MaxOffer then
				table.insert(Trade.Player1.Offer, { key, 1, itemType })
			end
		else
			for i, item in pairs(Trade.Player1.Offer) do
				if item[1] == key then
					Trade.Player1.Offer[i][2] = Trade.Player1.Offer[i][2] + 1
					break
				end
			end
		end
	end
	Trade.LastOffer = os.time()
	Trade.Player1.Accepted, Trade.Player2.Accepted = false, false
	T.refresh()
	return true
end

function T.removeYours(key, itemType)
	itemType = itemType or "Weapons"
	if Trade.Locked or Trade.Player1.Accepted then return false end
	Trade.LastOffer = os.time()
	Trade.Player1.Accepted, Trade.Player2.Accepted = false, false
	for i, item in pairs(Trade.Player1.Offer) do
		if item[1] == key and item[3] == itemType then
			item[2] = item[2] - 1
			if item[2] <= 0 then table.remove(Trade.Player1.Offer, i) end
			break
		end
	end
	T.refresh()
	return true
end

-- their side is ours to make up: anything in the database can go on it
function T.offerTheirs(key, itemType)
	itemType = itemType or "Weapons"
	if Trade.Locked then return false end
	if not (Sync and Sync[itemType] and Sync[itemType][key]) then
		say("no such item: " .. tostring(key))
		return false
	end
	-- their side is made up, but a made-up side that holds something the real
	-- trade would never show is a giveaway
	if itemType == "Weapons" and Blocked[key] then
		say("the real trade would refuse " .. tostring(key) .. ": " .. Blocked[key])
		return false
	end
	local found = false
	for _, item in pairs(Trade.Player2.Offer) do
		if item[1] == key and item[3] == itemType then
			item[2] = item[2] + 1
			found = true
			break
		end
	end
	if not found then
		if #Trade.Player2.Offer >= T.MaxOffer then return false end
		table.insert(Trade.Player2.Offer, { key, 1, itemType })
	end
	Trade.LastOffer = os.time()
	Trade.Player1.Accepted, Trade.Player2.Accepted = false, false
	T.refresh()
	return true
end

function T.removeTheirs(key, itemType)
	if Trade.Locked then return false end
	if key == nil then
		Trade.Player2.Offer = {}
	else
		for i, item in pairs(Trade.Player2.Offer) do
			if item[1] == key and item[3] == (itemType or "Weapons") then
				item[2] = item[2] - 1
				if item[2] <= 0 then table.remove(Trade.Player2.Offer, i) end
				break
			end
		end
	end
	Trade.Player1.Accepted, Trade.Player2.Accepted = false, false
	T.refresh()
	return true
end

function T.acceptThem(on)
	Trade.Player2.Accepted = (on ~= false)
	T.refresh()
	T.settle()
end

-- Your own accept normally comes from the game's Accept then Confirm buttons,
-- which are hooked. This is the same thing from a menu, for a keybind.
function T.acceptYou(on)
	Trade.Player1.Accepted = (on ~= false)
	acceptStage = (on ~= false) and "Waiting" or "Accept"
	T.refresh()
	T.settle()
end

-- What you really own, tradable only, newest rarity first - for a picker.
function T.mine()
	local out = {}
	pcall(function()
		local owned = ProfileData.Weapons.Owned
		if type(owned) ~= "table" then return end
		for k, v in pairs(owned) do
			local key, amount = ownedEntry(k, v)
			if key and ByKey[key] then
				local e = ByKey[key]
				out[#out + 1] = { key = key, name = e.name, count = amount or 1,
					rarity = e.rarity, type = e.type, image = e.image }
			end
		end
	end)
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

--== settling ==================================================================
-- Both sides accepted: what you offered leaves your inventory, what they
-- offered arrives in it, with the game's own "You got..." popup.
function T.settle()
	if not Trade then return end
	if not (Trade.Player1.Accepted and Trade.Player2.Accepted) then return end
	Trade.Locked = true
	task.wait(0.2)
	for _, item in pairs(Trade.Player1.Offer) do
		takeItem(item[1], item[2], item[3])
	end
	for _, item in pairs(Trade.Player2.Offer) do
		giveItem(item[1], item[2], item[3])
		pcall(function()
			if _G.NewItem then _G.NewItem(item[1], "You Got...", nil, item[3], item[2]) end
		end)
	end
	pcall(function() TradeGUI.Enabled = false end)
	local partner = Trade.Player2.Player
	Trade = blank(partner)
	T.Table = Trade
	inTrade = false
	say("traded")
	if type(T.OnChange) == "function" then pcall(T.OnChange, T.state()) end
end

--== the game's own buttons ====================================================
local function unhook()
	for _, c in pairs(conns) do pcall(function() c:Disconnect() end) end
	conns = {}
end

local function hookTiles(inv)
	pcall(function()
		if not (inv and inv.Data) then return end
		for itemType, group in pairs(inv.Data) do
			for _, bucket in pairs(group) do
				for key, entry in pairs(bucket) do
					local frame = entry.Frame
					if frame then
						conns[#conns + 1] = frame.Container.ActionButton.MouseButton1Click:Connect(function()
							T.offer(key, itemType)
						end)
					end
				end
			end
		end
	end)
end

local function hookButtons()
	local acts
	pcall(function() acts = TradeGUI.Container.Trade.Actions end)
	if not acts then return end
	pcall(function()
		conns[#conns + 1] = acts.Accept.ActionButton.MouseButton1Click:Connect(function()
			if cooldown <= 0 and acceptStage == "Accept" then
				acceptStage = "Confirm"
				acceptAt = os.clock()
				acts.Accept.Confirm.Visible = true
			end
		end)
		conns[#conns + 1] = acts.Accept.Confirm.ActionButton.MouseButton1Click:Connect(function()
			if cooldown <= 0 and os.clock() - acceptAt >= 0.4 and acceptStage == "Confirm" then
				acceptStage = "Waiting"
				YourOffer.Accepted.Visible = true
				acts.Accept.Cancel.Visible = true
				Trade.Player1.Accepted = true
				if type(T.OnChange) == "function" then pcall(T.OnChange, T.state()) end
				T.settle()
			end
		end)
		conns[#conns + 1] = acts.Accept.Cancel.ActionButton.MouseButton1Click:Connect(function()
			Trade.LastOffer = os.time()
			Trade.Player1.Accepted, Trade.Player2.Accepted = false, false
			T.refresh()
		end)
		conns[#conns + 1] = acts.Decline.ActionButton.MouseButton1Click:Connect(function()
			T.decline()
		end)
	end)
end

--== opening and closing =======================================================
function T.start(partner)
	if inTrade then return false end
	if not T.Ready then
		say("the game's trade window is not there - are you in MM2?")
		return false
	end
	inTrade = true
	Trade = blank(partner or T.Partner)
	T.Table = Trade

	-- before the window is filled, or blocked items get tiles built for them
	T.purge()

	pcall(function()
		for _, kind in pairs({ "Weapons", "Pets" }) do
			for bucket in pairs(InventoryModule.CreateBlankTradeInventoryTable()[kind]) do
				TradeGUI.Container.Items.Main:FindFirstChild(kind).Items.Container
					:FindFirstChild(bucket).Container:ClearAllChildren()
			end
		end
	end)
	pcall(function()
		TradeInventory = InventoryModule.GenerateInventory(TradeGUI.Container.Items,
			ProfileData, "Trading")
	end)
	unhook()
	hookTiles(TradeInventory)
	hookButtons()
	T.refresh()
	pcall(function()
		TheirOffer.Username.Text = "(" .. tostring(Trade.Player2.Player) .. ")"
	end)
	pcall(function() TradeGUI.Enabled = true end)

	-- the game's own search box, wired to its own tiles
	pcall(function()
		if searchConn then searchConn:Disconnect() end
		local box = TradeGUI.Container.Items.Tabs.Search.Container.SearchText
		searchConn = box:GetPropertyChangedSignal("Text"):Connect(function()
			local text = string.lower(tostring(box.Text or ""))
			for _, group in pairs(TradeInventory.Data) do
				for _, entry in pairs(group.Current or {}) do
					entry.Frame.Visible = (text == "")
						or string.find(string.lower(entry.Name), text, 1, true) ~= nil
				end
			end
		end)
	end)
	say("trading with " .. tostring(Trade.Player2.Player))
	if type(T.OnChange) == "function" then pcall(T.OnChange, T.state()) end
	return true
end

function T.decline()
	pcall(function() TradeGUI.Enabled = false end)
	local partner = Trade and Trade.Player2 and Trade.Player2.Player
	Trade = blank(partner)
	T.Table = Trade
	inTrade = false
	unhook()
	say("declined")
	if type(T.OnChange) == "function" then pcall(T.OnChange, T.state()) end
end

T.stop = T.decline

function T.setPartner(name)
	T.Partner = tostring(name or "Player2")
	if Trade then Trade.Player2.Player = T.Partner end
	pcall(function() TheirOffer.Username.Text = "(" .. T.Partner .. ")" end)
	if type(T.OnChange) == "function" then pcall(T.OnChange, T.state()) end
end

function T.counts()
	local n, blocked = #Catalog, 0
	for _ in pairs(Blocked) do blocked = blocked + 1 end
	return n, blocked
end

return T
