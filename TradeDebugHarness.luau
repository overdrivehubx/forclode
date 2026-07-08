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
	-- Destroy EVERY stale panel, wherever an executor may have parented it
	-- (PlayerGui and, for some executors, a protected CoreGui container).
	local scopes = { PlayerGui }
	pcall(function() table.insert(scopes, game:GetService("CoreGui")) end)
	pcall(function() if gethui then table.insert(scopes, gethui()) end end)
	for _, scope in ipairs(scopes) do
		for _, child in ipairs(scope:GetChildren()) do
			if child.Name == "TradeDebugPanel" or child.Name == "TradeDebugRequest" then
				pcall(function() child:Destroy() end)
			end
		end
	end

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

-- Walk UP from `inst` and force every ancestor GuiObject Visible = true (and the
-- owning ScreenGui Enabled = true). This is the fix for "a frame is set visible
-- but nothing shows because a parent tab/container is still hidden".
local function revealAncestors(inst)
	local node = inst
	while node and node.Parent do
		if node:IsA("ScreenGui") then
			pcall(function() node.Enabled = true end)
			break
		elseif node:IsA("GuiObject") then
			pcall(function() node.Visible = true end)
		end
		node = node.Parent
	end
end

-- Force `frame` and its whole subtree of GuiObjects visible (reveals the
-- buttons/labels inside a request panel regardless of the exact sub-structure).
local function revealSubtree(frame)
	if not frame then return end
	pcall(function() frame.Visible = true end)
	for _, d in ipairs(frame:GetDescendants()) do
		if d:IsA("GuiObject") then pcall(function() d.Visible = true end) end
	end
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
		if gui and gui:IsA("ScreenGui") and gui:FindFirstChild("Container") then return gui end
	end
	-- Sniff any ScreenGui that owns the tell-tale Container.Trade.Offer1 path.
	for _, gui in ipairs(PlayerGui:GetDescendants()) do
		if gui:IsA("ScreenGui") and resolve(gui, "Container.Trade.Offer1") then
			return gui
		end
	end
	-- Last resort: find an "Offer1" frame anywhere and climb to its ScreenGui.
	local anyOffer = PlayerGui:FindFirstChild("Offer1", true)
	if anyOffer then
		local a = anyOffer
		while a and not a:IsA("ScreenGui") do a = a.Parent end
		if a then return a end
	end
	return nil
end

local TradeGUI = findTradeGui()
if not TradeGUI then
	warn("[TradeDebug] Could not find a Trade ScreenGui in PlayerGui. Aborting.\n" ..
		"[TradeDebug] ScreenGuis present: " .. (function()
			local names = {}
			for _, g in ipairs(PlayerGui:GetChildren()) do table.insert(names, g.Name) end
			return table.concat(names, ", ")
		end)())
	return
end

-- Resolve the key sub-frames (GUI2 "Container" layout). Prefer the exact path,
-- but fall back to a recursive by-name search so slightly different trees still
-- bind. Every downstream access is nil-guarded regardless.
local Offer1  = resolve(TradeGUI, "Container.Trade.Offer1") or TradeGUI:FindFirstChild("Offer1", true)
local Offer2  = resolve(TradeGUI, "Container.Trade.Offer2") or TradeGUI:FindFirstChild("Offer2", true)
local TradeRoot = (Offer1 and Offer1.Parent) or resolve(TradeGUI, "Container.Trade")   -- the trade panel
local Container = (TradeRoot and TradeRoot.Parent) or resolve(TradeGUI, "Container")
	or TradeGUI:FindFirstChild("Container")
local ItemsPicker = resolve(TradeGUI, "Container.Items")
	or (Container and Container:FindFirstChild("Items")) or TradeGUI:FindFirstChild("Items", true)
local InventoryFrame = resolve(TradeGUI, "Container.Items.Main.Weapons.Items.Container.Current.Container")
local PetsFrame      = resolve(TradeGUI, "Container.Items.Main.Pets.Items.Container.Current.Container")

-- The request modal lives on the main leaderboard GUI, not the Trade GUI.
-- A recursive search for anything named "TradeRequest" is the most robust find
-- across the PC / Phone / Xbox / legacy layouts.
local function findRequestFrame()
	-- Explicit known paths first (fast, unambiguous).
	for _, gui in ipairs(PlayerGui:GetChildren()) do
		local rf = resolve(gui, "Leaderboard.Container.TradeRequest")
			or resolve(gui, "Game.Leaderboard.Container.TradeRequest")
			or resolve(gui, "Lobby.Screens.Waiting.Leaderboard.Container.OverlayMenu.TradeRequest")
		if rf then return rf end
	end
	-- Recursive fallback: any descendant literally named "TradeRequest".
	return PlayerGui:FindFirstChild("TradeRequest", true)
end
local RequestFrame = findRequestFrame()

-- Phone layout? (TradeGUI_Phone, or the request lives under the Lobby "Waiting"
-- screen). On phone the native flow is: a "!" badge appears on the leaderboard
-- "+" button, and the request only shows once the leaderboard tab is opened.
local IsPhone = (TradeGUI.Name == "TradeGUI_Phone")
	or (RequestFrame ~= nil and RequestFrame:FindFirstAncestor("Waiting") ~= nil)

-- Find the "+" leaderboard button's notification badge (phone only).
local function findPlusBadge()
	if not RequestFrame then return nil end
	local waiting = RequestFrame:FindFirstAncestor("Waiting")
	local scope = waiting or (TradeGUI:IsA("ScreenGui") and TradeGUI) or PlayerGui
	local leaderBar = scope:FindFirstChild("LeaderBar", true)
	if leaderBar then
		return resolve(leaderBar, "Main.Plus") or leaderBar:FindFirstChild("Plus", true)
	end
	return nil
end

-- Diagnostic dump so the runtime tree is visible in the console if anything is
-- missing. Share this line if a frame fails to bind.
local function fn(inst) return inst and inst:GetFullName() or "nil" end
print("[TradeDebug] Discovery:")
print("  TradeGUI      = " .. fn(TradeGUI))
print("  Container     = " .. fn(Container))
print("  TradeRoot     = " .. fn(TradeRoot))
print("  Offer1/Offer2 = " .. fn(Offer1) .. "  |  " .. fn(Offer2))
print("  ItemsPicker   = " .. fn(ItemsPicker))
print("  RequestFrame  = " .. fn(RequestFrame) .. (RequestFrame and "" or "  (NOT FOUND — request cannot show)"))

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

-- Full re-render of the trade panel CONTENT from the local state table.
-- NOTE: this must NOT toggle panel visibility (Enabled / Container.Trade /
-- Items) — that is owned by startTrade / openItemsPicker / closeItemsPicker.
-- Otherwise adding an item from the picker would flip back to the Trade panel.
function RenderTrade()
	clearRenderConnections()

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

-- Configure the request frame's "Accepting" variant with the P2 name (shared by
-- both layouts). Does NOT force ancestors visible — the caller decides that.
local function configureRequest(player2Name)
	if not RequestFrame then return end
	local accepting = RequestFrame:FindFirstChild("Accepting")
	local sending   = RequestFrame:FindFirstChild("Sending")
	if sending then sending.Visible = false end
	if accepting then revealSubtree(accepting) else revealSubtree(RequestFrame) end
	local uName = RequestFrame:FindFirstChild("Username", true)
	if uName then pcall(function() uName.Text = player2Name end) end
	local title = RequestFrame:FindFirstChild("Title", true)
	if title then pcall(function() title.Text = player2Name .. " wants to trade." end) end
	RequestFrame.Visible = true
	setProp(TradeRoot, "Offer2.Username", "Text", "(" .. player2Name .. ")")
end

-- Show the request. PC: reveal it directly in the leaderboard tab. Phone: light
-- the "!" badge on the "+" button and prime the request so it shows once the
-- player opens the leaderboard (the native mobile flow, per the source).
local function showRequestModal(player2Name)
	PendingP2Name = player2Name
	if not RequestFrame then
		warn("[TradeDebug] TradeRequest frame not found in PlayerGui — cannot show request.")
		return
	end
	configureRequest(player2Name)
	if IsPhone then
		local badge = findPlusBadge()
		if badge then pcall(function() badge.Visible = true end) end
		-- Do NOT reveal ancestors: the request appears when the leaderboard opens.
	else
		revealAncestors(RequestFrame)
	end
end

-- Open the inventory picker (Items) and hide the Trade panel — the native flow.
-- Having BOTH visible makes the Trade panel overlay the picker and swallow item
-- clicks, which is why items couldn't be added; so they are mutually exclusive.
local function openItemsPicker()
	if ItemsPicker then
		revealAncestors(ItemsPicker)
		ItemsPicker.Visible = true
	end
	if TradeRoot then TradeRoot.Visible = false end
	-- Default to the Weapons tab and make its scroll frame + content visible.
	setVisible(TradeGUI, "Container.Items.Main.Weapons", true)
	setVisible(TradeGUI, "Container.Items.Main.Pets", false)
	if InventoryFrame then revealAncestors(InventoryFrame) end
	renderInventory()
end

-- Close the picker and return to the Trade panel.
local function closeItemsPicker()
	if ItemsPicker then ItemsPicker.Visible = false end
	if TradeRoot then
		revealAncestors(TradeRoot)
		TradeRoot.Visible = true
	end
	RenderTrade()
end

-- Complete the trade once BOTH sides are accepted: show Processing then close.
local function completeTradeIfBothAccepted()
	if DebugTradeTable.Player1.Accepted and DebugTradeTable.Player2.Accepted then
		local processing = resolve(TradeGUI, "Container.Processing")
			or (Container and Container:FindFirstChild("Processing"))
		if processing then revealAncestors(processing); processing.Visible = true end
		task.delay(2, function()
			if processing then processing.Visible = false end
			if TradeGUI:IsA("ScreenGui") then TradeGUI.Enabled = false end
			if Container then Container.Visible = false end
		end)
	end
end

-- Begin the offline trade: hide the request, reset offers, open the Trade panel.
-- Invoked by the native MM2 Accept button, mirroring the real
-- AcceptRequest -> StartTrade -> UpdateTrade lifecycle.
local function startTrade(player2Name)
	DebugTradeTable.Player2.Player = { Name = player2Name, __fake = true }
	DebugTradeTable.Player1.Offer = {}
	DebugTradeTable.Player2.Offer = {}
	DebugTradeTable.Player1.Accepted = false
	DebugTradeTable.Player2.Accepted = false
	if RequestFrame then RequestFrame.Visible = false end
	if IsPhone then local b = findPlusBadge(); if b then pcall(function() b.Visible = false end) end end

	-- Open the Trade panel (Items hidden — native default). Bring the trade
	-- ScreenGui + ancestor chain on-screen so the layout pops on.
	if TradeGUI:IsA("ScreenGui") then TradeGUI.Enabled = true end
	revealAncestors(Offer1 or TradeRoot or Container)
	if Container then Container.Visible = true end
	if TradeRoot then TradeRoot.Visible = true end
	if ItemsPicker then ItemsPicker.Visible = false end

	RenderTrade()
	renderInventory()  -- pre-populate so the picker is ready when opened
end

-- Light the remote client's green acceptance flag (Player2 accepted), and
-- complete the trade if the local side has already accepted too.
local function forceRemoteAccept()
	DebugTradeTable.Player2.Accepted = true
	setVisible(TradeRoot, "Offer2.Accepted", true)
	revealSubtree(resolve(TradeRoot, "Offer2.Accepted"))
	completeTradeIfBothAccepted()
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
Window.Size = UDim2.new(0, 250, 0, 470)
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

-- (c) Reliable inventory toggle — opens/closes the item picker regardless of
--     whether the native Add-Items / Close buttons resolve. This is the robust
--     way to add items (the picker and Trade panel are mutually exclusive).
local ItemsOpen = false
local ItemsBtn = makeButton("▤  Open Item Picker", 5)
track(ItemsBtn.MouseButton1Click:Connect(function()
	ItemsOpen = not ItemsOpen
	if ItemsOpen then openItemsPicker(); ItemsBtn.Text = "▤  Close Item Picker"
	else closeItemsPicker(); ItemsBtn.Text = "▤  Open Item Picker" end
end))

-- (d) Mode toggle — redirect inventory clicks to the left/right offer.
local ModeBtn = makeButton("Mode: Player 1  (left)", 6)
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

-- (e) Accept as Player 1 (your green flag) — completes if P2 also accepted.
local AcceptP1Btn = makeButton("✔  Accept as P1", 7, SLATE_GREEN)
track(AcceptP1Btn.MouseButton1Click:Connect(function()
	DebugTradeTable.Player1.Accepted = true
	setVisible(TradeRoot, "Offer1.Accepted", true)
	revealSubtree(resolve(TradeRoot, "Offer1.Accepted"))
	completeTradeIfBothAccepted()
end))

-- (f) Force the remote (Player 2) acceptance flag green — completes if P1 too.
local AcceptBtn = makeButton("✔  Accept as P2 (remote)", 8, SLATE_GREEN)
track(AcceptBtn.MouseButton1Click:Connect(forceRemoteAccept))

-- (g) Terminate — close animation + wipe.
local KillBtn = makeButton("✖  Terminate + Wipe", 9, SLATE_RED)
track(KillBtn.MouseButton1Click:Connect(function()
	terminate(Panel)
end))

-- On-screen bind status (no console needed). Shows which frames resolved so a
-- missing path is visible at a glance: OK = bound, nil = NOT found.
local Status = Instance.new("TextLabel")
Status.Size = UDim2.new(1, 0, 0, 66)
Status.BackgroundTransparency = 1
local function ok(x) return x and "OK" or "nil" end
Status.Text = ("layout: %s\nReq %s | Trade %s | Cont %s\nItems %s | Inv %s | Pets %s"):format(
	TradeGUI.Name, ok(RequestFrame), ok(TradeRoot), ok(Container),
	ok(ItemsPicker), ok(InventoryFrame), ok(PetsFrame))
Status.TextColor3 = TEXT_DIM
Status.Font = Enum.Font.Gotham
Status.TextSize = 11
Status.TextWrapped = true
Status.TextYAlignment = Enum.TextYAlignment.Top
Status.TextXAlignment = Enum.TextXAlignment.Left
Status.LayoutOrder = 10
Status.Parent = Window

--==============================================================================
-- 10a. HOOK THE NATIVE MM2 "ACCEPT" BUTTON INSIDE THE REQUEST MODAL
--==============================================================================
-- Clicking the game's built-in green Accept button (not the debug button) is
-- what opens the real trade layout — mirroring AcceptRequest -> StartTrade.
-- Skipped entirely when there is no native RequestFrame.
if RequestFrame then
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
		track(addBtn.MouseButton1Click:Connect(openItemsPicker))
	end
	local closeBtn = resolve(ItemsPicker, "Tabs.Close.ActionButton")
	if closeBtn then
		track(closeBtn.MouseButton1Click:Connect(closeItemsPicker))
	end
	-- Weapons / Pets tab buttons in the picker.
	local weaponsTab = resolve(ItemsPicker, "Tabs.Weapons.View")
	if weaponsTab then
		track(weaponsTab.MouseButton1Click:Connect(function()
			setVisible(TradeGUI, "Container.Items.Main.Weapons", true)
			setVisible(TradeGUI, "Container.Items.Main.Pets", false)
			if InventoryFrame then revealAncestors(InventoryFrame) end
		end))
	end
	local petsTab = resolve(ItemsPicker, "Tabs.Pets.View")
	if petsTab then
		track(petsTab.MouseButton1Click:Connect(function()
			setVisible(TradeGUI, "Container.Items.Main.Weapons", false)
			setVisible(TradeGUI, "Container.Items.Main.Pets", true)
			if PetsFrame then revealAncestors(PetsFrame) end
		end))
	end
	-- Self-accept (Confirm) lights YOUR green flag and may complete the trade.
	local confirmBtn = resolve(TradeRoot, "Actions.Accept.Confirm.ActionButton")
	if confirmBtn then
		track(confirmBtn.MouseButton1Click:Connect(function()
			DebugTradeTable.Player1.Accepted = true
			setVisible(TradeRoot, "Offer1.Accepted", true)
			revealSubtree(resolve(TradeRoot, "Offer1.Accepted"))
			setVisible(TradeRoot, "Actions.Accept.Confirm", false)
			completeTradeIfBothAccepted()
		end))
	end
	local acceptBtn = resolve(TradeRoot, "Actions.Accept.ActionButton")
	if acceptBtn then
		track(acceptBtn.MouseButton1Click:Connect(function()
			revealSubtree(resolve(TradeRoot, "Actions.Accept.Confirm"))
			setVisible(TradeRoot, "Actions.Accept.Confirm", true)
		end))
	end
end

print("[TradeDebug] Harness loaded. Layout: " .. TradeGUI.Name ..
	" | Use the TradeDebugPanel to drive the offline trade.")
