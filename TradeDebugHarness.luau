--!nocheck
--[[
================================================================================
  MM2-STYLE TRADE UI — OFFLINE SIMULATION HARNESS
================================================================================
  Purpose : Drive the existing Murder-Mystery-2 style Trade interface entirely
            client-side for UI/UX testing and video capture. No RemoteEvent /
            RemoteFunction traffic is generated: the whole backend is replaced
            by a local table (`_G.DebugTradeTable`) that mirrors the real MM2
            trade structure.

  Runs as : a single LocalScript body — paste into an executor / a LocalScript
            and run once. It is fully decoupled from any physical `script`
            parent: every UI reference resolves dynamically starting from
            `game.Players.LocalPlayer.PlayerGui`.

  Mirrors : Trade table shape taken 1:1 from the server DataModule:
              {
                Locked   = false,
                LastOffer= os.time(),
                Player1  = { Player = <Player>, Offer = { {ItemKey,Amount,Cat} }, Accepted = false },
                Player2  = { Player = <fake>,   Offer = { ... },                 Accepted = false },
              }
            Offer entry order matches the live game: [1]=ItemKey [2]=Amount [3]=Category.

  Panel   : A dark-slate "TradeDebugPanel" (Instance.new, UICorner) provides:
              • a TextBox to override the Player 2 profile name,
              • a button to prompt the native trade-request modal + open the trade,
              • a Player 1 / Player 2 mode toggle that redirects inventory clicks
                to the left or right side of the offer table,
              • a "Force P2 Accept" override that lights the remote acceptance flag,
              • a Terminate button that plays the close animation and wipes state.

  NOTE    : This script only manipulates the LOCAL PlayerGui. It fires nothing to
            the server, so it cannot affect real trades, other players, or data.
================================================================================
]]

--==============================================================================
-- 0. SERVICES / PLAYER
--==============================================================================
local Players       = game:GetService("Players")
local TweenService  = game:GetService("TweenService")
local RunService    = game:GetService("RunService")

local LocalPlayer   = Players.LocalPlayer
local PlayerGui     = LocalPlayer:WaitForChild("PlayerGui")

--==============================================================================
-- 1. IDEMPOTENCE — strict garbage collection of any previous cycle
--==============================================================================
-- Destroy a stale panel and tear down the previous runtime BEFORE building a
-- fresh one, so the harness can be re-run any number of times in one session.
do
	local Old = PlayerGui:FindFirstChild("TradeDebugPanel")
	if Old then Old:Destroy() end

	local Prev = _G.__TradeDebug
	if Prev then
		-- disconnect every connection captured by the previous run
		if Prev.Connections then
			for _, con in ipairs(Prev.Connections) do
				pcall(function() con:Disconnect() end)
			end
		end
		if Prev.RenderConnections then
			for _, con in ipairs(Prev.RenderConnections) do
				pcall(function() con:Disconnect() end)
			end
		end
	end
	_G.DebugTradeTable = nil
	_G.__TradeDebug    = nil
end

-- Runtime scratch space that a future re-run can clean up.
local Runtime = {
	Connections       = {}, -- panel / static UI connections
	RenderConnections = {}, -- connections created while (re)rendering offers/inventory
}
_G.__TradeDebug = Runtime

local function track(con)          table.insert(Runtime.Connections, con); return con end
local function trackRender(con)    table.insert(Runtime.RenderConnections, con); return con end
local function clearRenderConnections()
	for _, con in ipairs(Runtime.RenderConnections) do pcall(function() con:Disconnect() end) end
	Runtime.RenderConnections = {}
end

--==============================================================================
-- 2. TINY UTILITIES (path resolver + safe setters)
--==============================================================================
-- Resolve "A.B.C" from a root instance, tolerating missing nodes (returns nil).
local function resolve(root, path)
	if not root then return nil end
	local node = root
	for segment in string.gmatch(path, "[^%.]+") do
		if not node then return nil end
		node = node:FindFirstChild(segment)
	end
	return node
end

-- Set a property on an instance found by path, without erroring if absent.
local function setProp(root, path, prop, value)
	local node = resolve(root, path)
	if node then pcall(function() node[prop] = value end) end
	return node
end

local function setVisible(root, path, visible)
	return setProp(root, path, "Visible", visible)
end

--==============================================================================
-- 3. LOCAL "SYNCED DATA" — a compact offline Item / Pet / Rarity database
--==============================================================================
-- A representative slice of the real Sync.Item module so inventory slots and
-- offers render with authentic art, names and rarity colours while offline.
local AssetURL = "http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId="

local Rarity = {
	["Classic"]   = Color3.fromRGB(255, 255, 255),
	["Common"]    = Color3.fromRGB(106, 106, 106),
	["Uncommon"]  = Color3.fromRGB(0, 170, 0),
	["Rare"]      = Color3.fromRGB(0, 112, 221),
	["Legendary"] = Color3.fromRGB(163, 53, 238),
	["Godly"]     = Color3.fromRGB(255, 128, 0),
	["Ancient"]   = Color3.fromRGB(255, 0, 76),
	["Divine"]    = Color3.fromRGB(255, 0, 128),
	["Victim"]    = Color3.fromRGB(0, 255, 255),
	["Unique"]    = Color3.fromRGB(255, 255, 0),
	["Christmas"] = Color3.fromRGB(255, 0, 0),
	["Halloween"] = Color3.fromRGB(255, 128, 0),
}

local RarityValue = {
	Classic=1, Common=2, Uncommon=3, Rare=4, Legendary=5,
	Godly=6, Divine=6.6, Ancient=6.5, Victim=7, Unique=11,
	Christmas=1.6, Halloween=1.5,
}

local ItemDB = {
	DefaultKnife = { ItemName="Default Knife", Image="http://www.roblox.com/asset/?id=584555920", ItemType="Knife", Rarity="Common" },
	DefaultGun   = { ItemName="Default Gun",   Image="http://www.roblox.com/asset/?id=197518111", ItemType="Gun",   Rarity="Common" },
	Whiteout     = { ItemName="Whiteout",      Image="http://www.roblox.com/asset/?id=191788694", ItemType="Knife", Rarity="Common" },
	["Bloxy Cola"]= { ItemName="Bloxy Cola",   Image="http://www.roblox.com/asset/?id=10042429263", ItemType="Knife", Rarity="Uncommon" },
	Cyber        = { ItemName="Cyber",         Image="http://www.roblox.com/asset/?id=10042430931", ItemType="Knife", Rarity="Uncommon" },
	Summerween   = { ItemName="Summerween",    Image="http://www.roblox.com/asset/?id=10042433636", ItemType="Knife", Rarity="Rare" },
	["Retro Sunset"]= { ItemName="Retro Sunset", Image="http://www.roblox.com/asset/?id=10042436051", ItemType="Knife", Rarity="Legendary" },
	Nebula       = { ItemName="Nebula",        Image=AssetURL.."6598123521", ItemType="Knife", Rarity="Godly" },
	Prismatic    = { ItemName="Prismatic",     Image="http://www.roblox.com/asset/?id=5645266804", ItemType="Knife", Rarity="Godly" },
	["Galaxy Blade"]= { ItemName="Universe",   Image=AssetURL.."10367060757", ItemType="Knife", Rarity="Godly" },
	Harvester    = { ItemName="Harvester",     Image=AssetURL.."7800847534", ItemType="Gun",   Rarity="Ancient", Holidays=true, Halloween=true, Year="2021", YearTagHW=true },
	Logchopper   = { ItemName="Logchopper",    Image="http://www.roblox.com/asset/?id=4528268775", ItemType="Knife", Rarity="Ancient" },
	["Chroma Pixel Gun"] = { ItemName="Pixel", Image="http://www.roblox.com/asset/?id=10324764035", ItemType="Gun", Rarity="Godly", Chroma=true },
	SharkSeeker  = { ItemName="SharkSeeker",   Image="http://www.roblox.com/asset/?id=7171844373", ItemType="Gun", Rarity="Victim" },
	["Chroma Corrupt"] = { ItemName="Corrupt", Image="http://www.roblox.com/asset/?id=10029093063", ItemType="Knife", Rarity="Victim", Chroma=true },
}

local PetDB = {
	Corgi   = { Name="Corgi",   Image=AssetURL.."1329450961", Rarity="Common" },
	Bunny   = { Name="Bunny",   Image=AssetURL.."1329450961", Rarity="Uncommon" },
	Dragon  = { Name="Dragon",  Image=AssetURL.."1329450961", Rarity="Legendary" },
	Dogey   = { Name="Dogey",   Image=AssetURL.."1329450961", Rarity="Godly", Chroma=true },
}

local Database = { Weapons = ItemDB, Pets = PetDB }

-- Offline "owned" inventory for the local player (mirrors DataDefaults.Weapons.Owned).
local OwnedWeapons = {
	DefaultKnife=1, DefaultGun=1, Whiteout=3, ["Bloxy Cola"]=1, Cyber=12,
	Summerween=2, ["Retro Sunset"]=1, Nebula=1, Prismatic=1, ["Galaxy Blade"]=1,
	Harvester=1, Logchopper=4, ["Chroma Pixel Gun"]=1, SharkSeeker=1, ["Chroma Corrupt"]=1,
}
local OwnedPets = { Corgi=5, Bunny=2, Dragon=1, Dogey=1 }

--==============================================================================
-- 4. LOCATE THE TRADE GUI (dynamic resolution from PlayerGui)
--==============================================================================
-- The live game ships several layouts (GUI2/MainPC, GUI2/MainMobile "phone",
-- Xbox, legacy GUI). We locate whichever Trade ScreenGui exists and detect its
-- flavour from the frame tree, so the same harness drives any of them.

local function findTradeGui()
	-- Preferred explicit names, newest first.
	for _, name in ipairs({ "Trade", "TradeGUI_Phone" }) do
		local gui = PlayerGui:FindFirstChild(name)
		if gui then return gui end
	end
	-- Fallback: sniff any ScreenGui that owns the tell-tale Container.Trade path.
	for _, gui in ipairs(PlayerGui:GetChildren()) do
		if gui:IsA("ScreenGui") and resolve(gui, "Container.Trade.Offer1") then
			return gui
		end
	end
	return nil
end

local TradeGUI = findTradeGui()
if not TradeGUI then
	warn("[TradeDebug] Could not find a Trade ScreenGui in PlayerGui. Aborting.")
	return
end

-- Resolve the key sub-frames (GUI2 "Container" layout). Some may be nil on
-- other layouts; every access below is guarded.
local TradeRoot   = resolve(TradeGUI, "Container.Trade")               -- the trade panel
local Offer1       = resolve(TradeGUI, "Container.Trade.Offer1")
local Offer2       = resolve(TradeGUI, "Container.Trade.Offer2")
local ItemsPicker  = resolve(TradeGUI, "Container.Items")             -- inventory picker
local InventoryFrame = resolve(TradeGUI, "Container.Items.Main.Weapons.Items.Container.Current.Container")
local PetsFrame      = resolve(TradeGUI, "Container.Items.Main.Pets.Items.Container.Current.Container")

-- The request modal lives on the main leaderboard GUI, not the Trade GUI.
local function findRequestFrame()
	for _, gui in ipairs(PlayerGui:GetChildren()) do
		local rf = resolve(gui, "Leaderboard.Container.TradeRequest")
			or resolve(gui, "Game.Leaderboard.Container.TradeRequest")
			or resolve(gui, "Lobby.Screens.Waiting.Leaderboard.Container.OverlayMenu.TradeRequest")
		if rf then return rf end
	end
	return nil
end
local RequestFrame = findRequestFrame()

--==============================================================================
-- 5. THE LOCAL TRADE STATE  (replaces the entire server backend)
--==============================================================================
-- A fake stand-in "player" object for the second participant. Only the fields
-- the UI reads (.Name) matter; it is a plain table, never sent anywhere.
local FakePlayer2 = { Name = "Player2", __fake = true }

local DebugTradeTable = {
	Locked    = false,
	LastOffer = os.time(),
	Player1   = { Player = LocalPlayer, Offer = {}, Accepted = false },
	Player2   = { Player = FakePlayer2, Offer = {}, Accepted = false },
}
_G.DebugTradeTable = DebugTradeTable

-- Which side receives the next inventory click. "Player1" = left, "Player2" = right.
local OfferMode = "Player1"

-- Name captured when the request modal is shown; consumed when the native
-- green Accept button is clicked (mirrors AcceptRequest -> StartTrade).
local PendingP2Name = "Player2"

--==============================================================================
-- 6. TEMPLATE EXTRACTION  (capture the native slot framework before clearing)
--==============================================================================
-- Inventory frames start empty. Before we clear the active canvas we try to
-- capture a real slot template from the UI tree (or storage), so cloned slots
-- keep the game's exact styling. Fallbacks degrade gracefully.
local SlotTemplate      -- template for inventory item slots
local GridLayoutTemplate -- optional UIGridLayout used inside the inventory frame

local function captureTemplates()
	-- (a) An existing populated slot inside the inventory frame is the ideal source.
	if InventoryFrame then
		for _, child in ipairs(InventoryFrame:GetChildren()) do
			if child:IsA("Frame") and resolve(child, "Container.Icon") then
				SlotTemplate = child:Clone()
				break
			elseif child:IsA("UIGridLayout") then
				GridLayoutTemplate = child:Clone()
			end
		end
	end
	-- (b) Otherwise borrow the shape of a trade offer slot ("NewItem1").
	if not SlotTemplate and Offer1 then
		local example = resolve(Offer1, "Container.NewItem1") or resolve(Offer1, "Container.NewItem")
		if example and example:IsA("Frame") then
			SlotTemplate = example:Clone()
		end
	end
	-- (c) Otherwise scan storage for a LocalScript that still carries an "Item" child.
	if not SlotTemplate then
		local storage = game:GetService("ReplicatedStorage")
		for _, desc in ipairs(storage:GetDescendants()) do
			if desc.Name == "Item" and desc:IsA("Frame") then
				SlotTemplate = desc:Clone()
				break
			end
		end
	end
	-- (d) Last resort — synthesize a minimal but faithful slot with Instance.new.
	if not SlotTemplate then
		local slot = Instance.new("Frame")
		slot.Name = "Item"
		slot.Size = UDim2.new(0, 92, 0, 92)
		slot.BackgroundColor3 = Color3.fromRGB(40, 44, 52)
		local sc = Instance.new("UICorner", slot); sc.CornerRadius = UDim.new(0, 6)

		local container = Instance.new("Frame")
		container.Name = "Container"
		container.Size = UDim2.new(1, 0, 1, 0)
		container.BackgroundTransparency = 1
		container.Parent = slot

		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.Size = UDim2.new(1, -8, 1, -24)
		icon.Position = UDim2.new(0, 4, 0, 4)
		icon.BackgroundTransparency = 1
		icon.Parent = container

		local amount = Instance.new("TextLabel")
		amount.Name = "Amount"
		amount.Size = UDim2.new(1, 0, 0, 16)
		amount.Position = UDim2.new(0, 0, 1, -18)
		amount.BackgroundTransparency = 1
		amount.TextColor3 = Color3.new(1, 1, 1)
		amount.Font = Enum.Font.SourceSansBold
		amount.TextScaled = true
		amount.Text = ""
		amount.Parent = container

		local button = Instance.new("TextButton")
		button.Name = "Button"
		button.Size = UDim2.new(1, 0, 1, 0)
		button.BackgroundTransparency = 1
		button.Text = ""
		button.Parent = container

		local nameHolder = Instance.new("Frame")
		nameHolder.Name = "ItemName"
		nameHolder.Size = UDim2.new(1, 0, 0, 20)
		nameHolder.Position = UDim2.new(0, 0, 1, 0)
		nameHolder.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.Size = UDim2.new(1, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Font = Enum.Font.SourceSans
		label.TextScaled = true
		label.Text = ""
		label.Parent = nameHolder
		nameHolder.Parent = slot

		SlotTemplate = slot
	end
	-- Neutralize the captured template so it never renders on its own.
	if SlotTemplate then
		SlotTemplate.Visible = false
		SlotTemplate.Name = "__SlotTemplate"
	end
end
captureTemplates()

-- Clone a fresh slot from the captured template.
local function newSlot()
	local slot = SlotTemplate:Clone()
	slot.Name = "Slot"
	slot.Visible = true
	return slot
end

--==============================================================================
-- 7. RENDERING  (drives the real frames from DebugTradeTable — no server)
--==============================================================================

-- Render one side's offer (Player1 -> Offer1 frame, Player2 -> Offer2 frame).
local function renderOffer(sideKey, offerFrame)
	if not offerFrame then return end
	local offers = DebugTradeTable[sideKey].Offer

	-- Wipe the existing NewItem slots (exactly like the live UpdateTrade).
	for _, frame in ipairs(offerFrame.Container:GetChildren()) do
		if frame:IsA("Frame") then
			setProp(frame, "Container.Icon", "Image", "")
			setProp(frame, "ItemName.Label", "Text", "")
			setProp(frame, "Container.Amount", "Text", "")
			setVisible(frame, "ItemName", false)
			setProp(frame, "Tags.Chroma", "Visible", false)
			frame.Visible = false
		end
	end

	for i, entry in ipairs(offers) do
		local itemKey, amount, category = entry[1], entry[2], entry[3]
		local db = Database[category] or ItemDB
		local data = db[itemKey]
		local slot = offerFrame.Container:FindFirstChild("NewItem" .. i)
		if slot and data then
			slot.Visible = true
			setProp(slot, "Container.Icon", "Image", data.Image)
			local displayName = data.ItemName or data.Name
			setProp(slot, "ItemName.Label", "Text", displayName)
			setProp(slot, "ItemName.Label", "TextColor3", Rarity[data.Rarity] or Color3.new(1,1,1))
			setProp(slot, "ItemName.RarityBar", "BackgroundColor3", Rarity[data.Rarity] or Color3.new(1,1,1))
			setProp(slot, "ItemName", "BackgroundColor3", Rarity[data.Rarity] or Color3.new(1,1,1))
			setVisible(slot, "ItemName", true)
			setProp(slot, "Container.Amount", "Text", (amount and amount > 1) and ("x" .. amount) or "")
			setProp(slot, "Tags.Chroma", "Visible", data.Chroma ~= nil)

			-- Clicking a slot in your own offer removes it (local, no server).
			local removeBtn = resolve(slot, "Container.ActionButton")
			if removeBtn and sideKey == "Player1" then
				trackRender(removeBtn.MouseButton1Click:Connect(function()
					table.remove(DebugTradeTable[sideKey].Offer, i)
					DebugTradeTable.Player1.Accepted = false
					DebugTradeTable.Player2.Accepted = false
					RenderTrade()  -- forward-declared below
				end))
			end
		end
	end
end

-- Full re-render of the trade panel from the local state table.
function RenderTrade()
	clearRenderConnections()
	if TradeGUI:IsA("ScreenGui") then TradeGUI.Enabled = true end
	setVisible(TradeGUI, "Container.Trade", true)

	-- Second participant's display name.
	setProp(TradeRoot, "Offer2.Username", "Text", "(" .. DebugTradeTable.Player2.Player.Name .. ")")

	-- Acceptance flags -> the green "Accepted" badges.
	setVisible(TradeRoot, "Offer1.Accepted", DebugTradeTable.Player1.Accepted)
	setVisible(TradeRoot, "Offer2.Accepted", DebugTradeTable.Player2.Accepted)

	renderOffer("Player1", Offer1)
	renderOffer("Player2", Offer2)
end

-- Offer an item into whichever side OfferMode currently targets.
local function offerItemLocal(itemKey, category)
	if itemKey == "DefaultKnife" or itemKey == "DefaultGun" then return end
	local side = DebugTradeTable[OfferMode]
	if #side.Offer >= 4 then return end -- live cap: 4 stacks per side

	-- Stack onto an existing entry or add a new one (mirrors Module.Trade.OfferItem).
	local existing
	for _, e in ipairs(side.Offer) do
		if e[1] == itemKey and e[3] == category then existing = e break end
	end
	if existing then
		existing[2] = existing[2] + 1
	else
		table.insert(side.Offer, { itemKey, 1, category })
	end

	-- Any change to the table resets both acceptance flags, like the server does.
	DebugTradeTable.LastOffer = os.time()
	DebugTradeTable.Player1.Accepted = false
	DebugTradeTable.Player2.Accepted = false

	-- Editing an offer also collapses the "confirm" step, matching the live UI.
	setVisible(TradeRoot, "Actions.Accept.Confirm", false)
	RenderTrade()
end

-- Sorting helper reused for both inventory panes.
local function sortedInventory(owned, db)
	local list = {}
	for name, amount in pairs(owned) do
		table.insert(list, { ItemName = name, Amount = amount })
	end
	table.sort(list, function(a, b)
		if a.ItemName == "DefaultKnife" then return true elseif b.ItemName == "DefaultKnife" then return false
		elseif a.ItemName == "DefaultGun" then return true elseif b.ItemName == "DefaultGun" then return false end
		local ra = RarityValue[(db[a.ItemName] or {}).Rarity or "Common"] or 0
		local rb = RarityValue[(db[b.ItemName] or {}).Rarity or "Common"] or 0
		if ra ~= rb then return ra > rb end
		return a.Amount > b.Amount
	end)
	return list
end

-- Populate an inventory pane (weapons or pets) with clickable slots.
local function renderInventoryPane(frame, owned, db, category)
	if not frame then return end
	frame:ClearAllChildren()
	if GridLayoutTemplate then GridLayoutTemplate:Clone().Parent = frame end

	for _, entry in ipairs(sortedInventory(owned, db)) do
		local itemKey = entry.ItemName
		local amount  = entry.Amount
		local data    = db[itemKey]
		if data then
			local slot = newSlot()
			slot.Parent = frame
			slot.Name = data.ItemName or data.Name or itemKey
			setProp(slot, "Container.Icon", "Image", data.Image)
			setProp(slot, "ItemName.Label", "Text", data.ItemName or data.Name)
			setProp(slot, "ItemName", "BackgroundColor3", Rarity[data.Rarity] or Color3.new(1,1,1))
			setProp(slot, "Tags.Chroma", "Visible", data.Chroma ~= nil)
			setProp(slot, "Container.Amount", "Text", (amount > 1) and ("x" .. amount) or "")

			local button = resolve(slot, "Container.Button") or resolve(slot, "Container.ActionButton")
			if button then
				trackRender(button.MouseButton1Click:Connect(function()
					offerItemLocal(itemKey, category)
				end))
			end
		end
	end
end

local function renderInventory()
	renderInventoryPane(InventoryFrame, OwnedWeapons, ItemDB, "Weapons")
	renderInventoryPane(PetsFrame, OwnedPets, PetDB, "Pets")
end

--==============================================================================
-- 8. REQUEST MODAL + TRADE LIFECYCLE  (local stand-ins for the Remote chain)
--==============================================================================

-- Show the native "trade request" modal (accepting variant) with the P2 name.
-- This ONLY reveals the modal — the main trade panels stay hidden until the
-- game's built-in green Accept button is clicked (see the hook in section 10).
local function showRequestModal(player2Name)
	PendingP2Name = player2Name
	if not RequestFrame then
		warn("[TradeDebug] Request modal frame (Leaderboard...TradeRequest) not found.")
		return
	end
	setVisible(RequestFrame, "Accepting", true)
	setVisible(RequestFrame, "Sending", false)
	setProp(RequestFrame, "Accepting.Username", "Text", player2Name)
	setProp(TradeRoot, "Offer2.Username", "Text", "(" .. player2Name .. ")")
	RequestFrame.Visible = true
end

-- Begin the offline trade: hide the modal, reset offers, open the panels, render.
-- Invoked by the native MM2 Accept button (not directly by the debug button),
-- mirroring the real AcceptRequest -> StartTrade -> UpdateTrade lifecycle.
local function startTrade(player2Name)
	DebugTradeTable.Player2.Player = { Name = player2Name, __fake = true }
	DebugTradeTable.Player1.Offer = {}
	DebugTradeTable.Player2.Offer = {}
	DebugTradeTable.Player1.Accepted = false
	DebugTradeTable.Player2.Accepted = false
	if RequestFrame then RequestFrame.Visible = false end

	-- Open the actual game panels now that the native Accept was clicked.
	-- Set every screen explicitly so the interface pops on instantly.
	if TradeGUI:IsA("ScreenGui") then TradeGUI.Enabled = true end
	setVisible(TradeGUI, "Container", true)
	setVisible(TradeGUI, "Container.Trade", true)
	setVisible(TradeGUI, "Container.Items", true)

	RenderTrade()
	renderInventory()
end

-- Light the remote client's green acceptance flag (Player2 accepted).
local function forceRemoteAccept()
	DebugTradeTable.Player2.Accepted = true
	setVisible(TradeRoot, "Offer2.Accepted", true)
end

-- Clean close: play the fade, wipe the tables, drop the panel.
local function terminate(panel)
	-- Fade the trade panel out if it's a GuiObject we can tween.
	local container = resolve(TradeGUI, "Container")
	if container and container:IsA("GuiObject") then
		pcall(function()
			local t = TweenService:Create(container, TweenInfo.new(0.3), { BackgroundTransparency = 1 })
			t:Play()
		end)
	end
	task.delay(0.35, function()
		if TradeGUI:IsA("ScreenGui") then TradeGUI.Enabled = false end
		setVisible(TradeGUI, "Container.Trade", false)
		setVisible(TradeGUI, "Container.Items", false)
	end)

	-- Wipe environment tables.
	clearRenderConnections()
	for _, con in ipairs(Runtime.Connections) do pcall(function() con:Disconnect() end) end
	Runtime.Connections = {}
	_G.DebugTradeTable = nil
	_G.__TradeDebug = nil

	if panel then
		local fade = TweenService:Create(panel, TweenInfo.new(0.25), { BackgroundTransparency = 1 })
		fade:Play()
		task.delay(0.3, function() if panel then panel:Destroy() end end)
	end
	print("[TradeDebug] Environment wiped.")
end

--==============================================================================
-- 9. THE DEBUG CONTROLLER PANEL  (Instance.new, dark-slate, UICorner)
--==============================================================================
local SLATE_BG     = Color3.fromRGB(24, 27, 34)
local SLATE_PANEL  = Color3.fromRGB(33, 38, 47)
local SLATE_BTN    = Color3.fromRGB(46, 53, 66)
local SLATE_ACCENT = Color3.fromRGB(64, 132, 214)
local SLATE_GREEN  = Color3.fromRGB(46, 160, 87)
local SLATE_RED    = Color3.fromRGB(190, 60, 60)
local TEXT_LIGHT   = Color3.fromRGB(228, 232, 240)
local TEXT_DIM     = Color3.fromRGB(150, 158, 172)

local function corner(inst, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = inst
	return c
end

local function pad(inst, px)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, px); p.PaddingBottom = UDim.new(0, px)
	p.PaddingLeft = UDim.new(0, px); p.PaddingRight = UDim.new(0, px)
	p.Parent = inst
	return p
end

local Panel = Instance.new("ScreenGui")
Panel.Name = "TradeDebugPanel"
Panel.ResetOnSpawn = false
Panel.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
Panel.DisplayOrder = 1000
Panel.Parent = PlayerGui

local Window = Instance.new("Frame")
Window.Name = "Window"
Window.Size = UDim2.new(0, 250, 0, 320)
Window.Position = UDim2.new(0, 20, 0.5, -160)
Window.BackgroundColor3 = SLATE_BG
Window.BorderSizePixel = 0
Window.Active = true
Window.Draggable = true               -- lets you reposition it off-camera for capture
Window.Parent = Panel
corner(Window, 12)

local Stroke = Instance.new("UIStroke")
Stroke.Color = Color3.fromRGB(60, 68, 84)
Stroke.Thickness = 1
Stroke.Parent = Window

local Layout = Instance.new("UIListLayout")
Layout.Padding = UDim.new(0, 8)
Layout.SortOrder = Enum.SortOrder.LayoutOrder
Layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
Layout.Parent = Window
pad(Window, 12)

-- Header
local Header = Instance.new("TextLabel")
Header.Name = "Header"
Header.Size = UDim2.new(1, 0, 0, 26)
Header.BackgroundTransparency = 1
Header.Text = "TRADE DEBUG HARNESS"
Header.TextColor3 = TEXT_LIGHT
Header.Font = Enum.Font.GothamBold
Header.TextSize = 15
Header.TextXAlignment = Enum.TextXAlignment.Left
Header.LayoutOrder = 1
Header.Parent = Window

local Sub = Instance.new("TextLabel")
Sub.Size = UDim2.new(1, 0, 0, 14)
Sub.BackgroundTransparency = 1
Sub.Text = "offline • no server calls"
Sub.TextColor3 = TEXT_DIM
Sub.Font = Enum.Font.Gotham
Sub.TextSize = 11
Sub.TextXAlignment = Enum.TextXAlignment.Left
Sub.LayoutOrder = 2
Sub.Parent = Window

-- Reusable styled button factory.
local function makeButton(text, order, color)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 0, 34)
	btn.BackgroundColor3 = color or SLATE_BTN
	btn.AutoButtonColor = true
	btn.Text = text
	btn.TextColor3 = TEXT_LIGHT
	btn.Font = Enum.Font.GothamMedium
	btn.TextSize = 13
	btn.BorderSizePixel = 0
	btn.LayoutOrder = order
	btn.Parent = Window
	corner(btn, 8)
	return btn
end

-- (a) Player 2 name override — TextBox.
local NameBox = Instance.new("TextBox")
NameBox.Size = UDim2.new(1, 0, 0, 34)
NameBox.BackgroundColor3 = SLATE_PANEL
NameBox.Text = "Player2"
NameBox.PlaceholderText = "Player 2 name…"
NameBox.PlaceholderColor3 = TEXT_DIM
NameBox.TextColor3 = TEXT_LIGHT
NameBox.Font = Enum.Font.Gotham
NameBox.TextSize = 13
NameBox.ClearTextOnFocus = false
NameBox.BorderSizePixel = 0
NameBox.LayoutOrder = 3
NameBox.Parent = Window
corner(NameBox, 8)
pad(NameBox, 8)

-- Capture the raw TextBox contents verbatim. NO whitespace stripping,
-- truncation, or length limits — only substitute a default when the box is
-- genuinely empty so a valid typed name is never overwritten.
local function currentName()
	local n = tostring(NameBox.Text)
	if n == "" then n = "Player2" end
	return n
end

-- (b) Prompt the native request modal ONLY. The main trade panels stay hidden;
--     they open when the game's built-in green Accept button is clicked.
local RequestBtn = makeButton("▶  Prompt Trade Request", 4, SLATE_ACCENT)
track(RequestBtn.MouseButton1Click:Connect(function()
	-- Explicitly snapshot exactly what is typed at the moment of the click.
	local typedName = tostring(NameBox.Text)
	if typedName == "" then typedName = "Player2" end
	showRequestModal(typedName)
end))

-- (c) Mode toggle — redirect inventory clicks to the left/right offer.
local ModeBtn = makeButton("Mode: Player 1  (left)", 5)
track(ModeBtn.MouseButton1Click:Connect(function()
	OfferMode = (OfferMode == "Player1") and "Player2" or "Player1"
	if OfferMode == "Player1" then
		ModeBtn.Text = "Mode: Player 1  (left)"
		ModeBtn.BackgroundColor3 = SLATE_BTN
	else
		ModeBtn.Text = "Mode: Player 2  (right)"
		ModeBtn.BackgroundColor3 = Color3.fromRGB(70, 58, 40)
	end
end))

-- (d) Force the remote acceptance flag green.
local AcceptBtn = makeButton("✔  Force P2 Accept (green)", 6, SLATE_GREEN)
track(AcceptBtn.MouseButton1Click:Connect(forceRemoteAccept))

-- (e) Terminate — close animation + wipe.
local KillBtn = makeButton("✖  Terminate + Wipe", 7, SLATE_RED)
track(KillBtn.MouseButton1Click:Connect(function()
	terminate(Panel)
end))

-- Small live status line.
local Status = Instance.new("TextLabel")
Status.Size = UDim2.new(1, 0, 0, 14)
Status.BackgroundTransparency = 1
Status.Text = "layout: " .. TradeGUI.Name
Status.TextColor3 = TEXT_DIM
Status.Font = Enum.Font.Gotham
Status.TextSize = 11
Status.TextXAlignment = Enum.TextXAlignment.Left
Status.LayoutOrder = 8
Status.Parent = Window

--==============================================================================
-- 10a. HOOK THE NATIVE MM2 "ACCEPT" BUTTON INSIDE THE REQUEST MODAL
--==============================================================================
-- Clicking the game's built-in green Accept button (not the debug button) is
-- what opens the real trade layout — mirroring AcceptRequest -> StartTrade.
do
	-- Return `inst` if it is a button, else the first GuiButton nested inside it.
	local function firstButtonIn(inst)
		if not inst then return nil end
		if inst:IsA("GuiButton") then return inst end
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("GuiButton") then return d end
		end
		return nil
	end

	-- The button's exact path differs per layout, so probe every known candidate
	-- and, as a last resort, recursively find a node literally named "Accept".
	local function findRequestAccept()
		if not RequestFrame then return nil end
		local candidates = {
			"Accepting.Container.Accept.ActionButton",
			"Accepting.Accept.ActionButton",
			"Accepting.Container.Accept",
			"Accepting.Accept",
		}
		for _, path in ipairs(candidates) do
			local btn = firstButtonIn(resolve(RequestFrame, path))
			if btn then return btn end
		end
		-- Fallback: recursive search for a descendant named "Accept" (or its button).
		local scope = resolve(RequestFrame, "Accepting") or RequestFrame
		return firstButtonIn(scope:FindFirstChild("Accept", true))
	end

	local acceptBtn = findRequestAccept()
	if acceptBtn then
		-- Fire on both signals so the hook triggers regardless of button class,
		-- guarding against a double-open with a short debounce.
		local lastOpen = 0
		local function onAccept()
			if os.clock() - lastOpen < 0.3 then return end
			lastOpen = os.clock()
			startTrade(PendingP2Name or currentName())
		end
		track(acceptBtn.MouseButton1Click:Connect(onAccept))
		track(acceptBtn.Activated:Connect(onAccept))
	else
		warn("[TradeDebug] Native request Accept button not found; " ..
			"could not wire the trade-open hook.")
	end

	-- Wire the native Decline button to simply hide the modal (native behaviour).
	local declineBtn = resolve(RequestFrame, "Accepting.Container.Decline.ActionButton")
		or resolve(RequestFrame, "Accepting.Decline.ActionButton")
		or resolve(RequestFrame, "Accepting.Decline")
	if declineBtn and declineBtn:IsA("GuiButton") then
		track(declineBtn.MouseButton1Click:Connect(function()
			if RequestFrame then RequestFrame.Visible = false end
		end))
	end
end

--==============================================================================
-- 10. OPTIONAL: wire the panel's Add-Items / tab / close buttons locally
--==============================================================================
-- Keep the in-panel navigation working without touching the server.
do
	local addBtn = resolve(TradeRoot, "Actions.AddItems.ActionButton")
	if addBtn then
		track(addBtn.MouseButton1Click:Connect(function()
			setVisible(TradeGUI, "Container.Trade", false)
			setVisible(TradeGUI, "Container.Items", true)
		end))
	end
	local closeBtn = resolve(ItemsPicker, "Tabs.Close.ActionButton")
	if closeBtn then
		track(closeBtn.MouseButton1Click:Connect(function()
			setVisible(TradeGUI, "Container.Items", false)
			setVisible(TradeGUI, "Container.Trade", true)
		end))
	end
	-- Self-accept (Confirm) simply lights YOUR green flag locally.
	local confirmBtn = resolve(TradeRoot, "Actions.Accept.Confirm.ActionButton")
	if confirmBtn then
		track(confirmBtn.MouseButton1Click:Connect(function()
			DebugTradeTable.Player1.Accepted = true
			setVisible(TradeRoot, "Offer1.Accepted", true)
			setVisible(TradeRoot, "Actions.Accept.Confirm", false)
		end))
	end
	local acceptBtn = resolve(TradeRoot, "Actions.Accept.ActionButton")
	if acceptBtn then
		track(acceptBtn.MouseButton1Click:Connect(function()
			setVisible(TradeRoot, "Actions.Accept.Confirm", true)
		end))
	end
end

print("[TradeDebug] Harness loaded. Layout: " .. TradeGUI.Name ..
	" | Use the TradeDebugPanel to drive the offline trade.")
