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
-- Timed WaitForChild so a device that loads GUIs in a different order can't
-- freeze the thread forever; fall back to a direct lookup if it times out.
local PlayerGui     = LocalPlayer:WaitForChild("PlayerGui", 5)
	or LocalPlayer:FindFirstChildOfClass("PlayerGui")
	or LocalPlayer:FindFirstChild("PlayerGui")
if not PlayerGui then
	warn("[TradeDebug] PlayerGui unavailable — aborting.")
	return
end

--==============================================================================
-- 1. IDEMPOTENCE — strict garbage collection of any previous cycle
--==============================================================================
-- Destroy a stale panel and tear down the previous runtime BEFORE building a
-- fresh one, so the harness can be re-run any number of times in one session.
do
	-- Destroy EVERY stale panel, wherever an executor may have parented it
	-- (PlayerGui and, for some executors, a protected CoreGui container).
	local scopes = { PlayerGui }
	-- CoreGui access throws a Security Exception on some clients; isolate it so
	-- it can never kill the thread before the panel is drawn.
	local success, coreGui = pcall(function() return game:GetService("CoreGui") end)
	if success and coreGui then table.insert(scopes, coreGui) end
	if gethui then pcall(function() table.insert(scopes, gethui()) end) end
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

-- Try to use the REAL game catalog (read-only data fetch, exactly what the
-- source scripts call) + your real inventory, so the picker looks like the game.
-- Falls back to the embedded sample data when unavailable.
-- Find the GetSyncData RemoteFunction (root child first, then anywhere).
local function findGetSync()
	local rs = game:GetService("ReplicatedStorage")
	return rs:FindFirstChild("GetSyncData") or rs:FindFirstChild("GetSyncData", true)
end
-- InvokeServer can yield forever if the server never answers, so race it against
-- a timeout; the leaked worker thread is harmless. Captures the failure reason.
local lastSyncError = nil
local function invokeWithTimeout(gsd, name, timeout)
	local done, result, err = false, nil, nil
	task.spawn(function()
		local ok, data = pcall(function() return gsd:InvokeServer(name) end)
		if ok then result = data else err = "error: " .. tostring(data) end
		done = true
	end)
	local t = 0
	while not done and t < timeout do task.wait(0.1); t = t + 0.1 end
	if not done then err = "timeout (>" .. timeout .. "s)" end
	if err then lastSyncError = err end
	if type(result) ~= "table" and not err then lastSyncError = "returned " .. typeof(result) end
	return result
end
local function tryGetSync(name)
	local gsd = findGetSync()
	if not gsd then lastSyncError = "GetSyncData not found"; return nil end
	local data = invokeWithTimeout(gsd, name, 10)
	if type(data) == "table" then return data end
	return nil
end

-- Set by the panel; called once real data loads. Also reports the catalog state.
local onCatalogLoaded
local CatalogStatus = "loading real catalog…"
local RealCatalog = false  -- true once GetSyncData returns the real catalog

local function countKeys(t)
	local n = 0; if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end; return n
end

-- Fetch the real catalog + inventory. This may YIELD on InvokeServer, so it MUST
-- run in a background thread (never at load time) or it will freeze the script
-- before the menu is drawn.
local function applyRealData()
	local realItems = tryGetSync("Item")
	local realPets  = tryGetSync("Pets")
	local realRar   = tryGetSync("Rarity")
	if realItems then ItemDB = realItems end
	if realPets  then PetDB  = realPets  end
	if realRar   then Rarity = realRar   end
	Database = { Weapons = ItemDB, Pets = PetDB }

	local pd = rawget(_G, "PlayerData")
	local function copyOwned(t)
		local c = {}; if type(t) == "table" then for k, v in pairs(t) do c[k] = v end end; return c
	end
	local havePD = (type(pd) == "table" and pd.Weapons and pd.Weapons.Owned) and true or false
	if havePD then
		OwnedWeapons = copyOwned(pd.Weapons.Owned)
		OwnedPets = copyOwned(pd.Pets and pd.Pets.Owned)
	elseif realItems then
		-- Real catalog but no player inventory exposed: start EMPTY so only the
		-- real items you spawn appear (no fake placeholders).
		OwnedWeapons = {}
		OwnedPets = {}
	end

	if realItems then
		RealCatalog = true
		CatalogStatus = ("real catalog: %d items, %d pets%s"):format(
			countKeys(ItemDB), countKeys(PetDB), havePD and " · your inventory" or " · spawn to fill")
	else
		RealCatalog = false
		CatalogStatus = "catalog: FALLBACK — using the game's own inventory"
	end
	if onCatalogLoaded then pcall(onCatalogLoaded) end
end

-- Resolve an item image; wrap a bare asset id in the thumbnail URL (per source).
local function getImage(img)
	if img == nil then return "" end
	if tonumber(img) then return AssetURL .. tostring(img) end
	return img
end

--==============================================================================
-- 4. LOCATE THE TRADE GUI (dynamic resolution from PlayerGui)
--==============================================================================
-- The live game ships several layouts (GUI2/MainPC, GUI2/MainMobile "phone",
-- Xbox, legacy GUI). Both "Trade" (PC) and "TradeGUI_Phone" can exist at once,
-- so we must pick the one that matches the current platform — otherwise we drive
-- an inactive GUI (frames resolve fine, but nothing shows on screen and a second
-- native panel appears). Touch (no mouse) => phone.

local UIS = game:GetService("UserInputService")
local IsTouch = UIS.TouchEnabled and not UIS.MouseEnabled

-- A ScreenGui "looks like" a trade GUI if it owns Container.Trade, or is named
-- Trade/…Phone with a Container. NOTE: we deliberately do NOT require Offer1 —
-- it may resolve on a different node, and requiring it made the GUI undetected.
local function looksLikeTrade(gui)
	if not gui:IsA("ScreenGui") then return false end
	if resolve(gui, "Container.Trade") then return true end
	local n = string.lower(gui.Name)
	if (string.find(n, "trade") or string.find(n, "phone")) and gui:FindFirstChild("Container") then
		return true
	end
	return false
end

local function findTradeGui()
	local candidates = {}
	for _, gui in ipairs(PlayerGui:GetChildren()) do
		if looksLikeTrade(gui) then table.insert(candidates, gui) end
	end
	if #candidates == 0 then
		for _, gui in ipairs(PlayerGui:GetDescendants()) do
			if looksLikeTrade(gui) then table.insert(candidates, gui) end
		end
	end

	local function isPhone(g) return string.find(string.lower(g.Name), "phone") ~= nil end

	-- Deterministic: the game only clones the platform's GUI, so if a *_Phone
	-- trade GUI exists at all we are on mobile — use it. Touch is a tiebreaker.
	for _, gui in ipairs(candidates) do
		if isPhone(gui) then return gui end
	end
	if IsTouch then
		-- touch but no phone-named GUI: still prefer an Enabled candidate.
		for _, gui in ipairs(candidates) do if gui.Enabled then return gui end end
	end
	-- Desktop / fallback: first non-phone, then Enabled, then first.
	for _, gui in ipairs(candidates) do
		if not isPhone(gui) then return gui end
	end
	for _, gui in ipairs(candidates) do
		if gui.Enabled then return gui end
	end
	if candidates[1] then return candidates[1] end

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
-- Do NOT abort if the trade GUI isn't found — the debug panel must still appear
-- (it's the only on-screen feedback). Everything below is nil-guarded.
if not TradeGUI then
	warn("[TradeDebug] Trade GUI not found — panel will still show with status.")
end

-- Resolve the key sub-frames (GUI2 "Container" layout). Prefer the exact path,
-- but fall back to a recursive by-name search so slightly different trees still
-- bind. Every downstream access is nil-guarded regardless.
local function ffc(root, name) return root and root:FindFirstChild(name, true) or nil end

-- This build renames the offer frames: YourOffer / TheirOffer (not Offer1/Offer2).
-- Keep both sets of candidates so the harness binds on either naming.
local OFFER_NAMES = {
	your  = { "Offer1", "YourOffer", "Your", "MyOffer" },
	their = { "Offer2", "TheirOffer", "Their", "OtherOffer" },
}
-- Find an offer frame by candidate names, direct child first then recursive.
local function findOffer(root, side)
	if not root then return nil end
	for _, nm in ipairs(OFFER_NAMES[side]) do
		local f = root:FindFirstChild(nm)
		if f and f:IsA("GuiObject") then return f end
	end
	for _, nm in ipairs(OFFER_NAMES[side]) do
		local f = root:FindFirstChild(nm, true)
		if f and f:IsA("GuiObject") then return f end
	end
	return nil
end

-- Anchor on Container.Trade, then read the two offer frames from it.
local TradeRoot = (TradeGUI and resolve(TradeGUI, "Container.Trade")) or nil
local Offer1 = findOffer(TradeRoot, "your")  or findOffer(TradeGUI, "your")
local Offer2 = findOffer(TradeRoot, "their") or findOffer(TradeGUI, "their")
if not TradeRoot and Offer1 then TradeRoot = Offer1.Parent end
local Container = (TradeRoot and TradeRoot.Parent) or (TradeGUI and resolve(TradeGUI, "Container")) or ffc(TradeGUI, "Container")
local ItemsPicker = (TradeGUI and resolve(TradeGUI, "Container.Items"))
	or (Container and Container:FindFirstChild("Items")) or ffc(TradeGUI, "Items")
local InventoryFrame = TradeGUI and resolve(TradeGUI, "Container.Items.Main.Weapons.Items.Container.Current.Container")
local PetsFrame      = TradeGUI and resolve(TradeGUI, "Container.Items.Main.Pets.Items.Container.Current.Container")

-- The request modal lives on the main leaderboard GUI, not the Trade GUI.
-- A recursive search for anything named "TradeRequest" is the most robust find
-- across the PC / Phone / Xbox / legacy layouts.
local function findRequestFrame()
	-- Collect every TradeRequest frame present (PC + phone can both exist).
	local found = {}
	for _, rf in ipairs(PlayerGui:GetDescendants()) do
		if rf.Name == "TradeRequest" then table.insert(found, rf) end
	end
	local function underWaiting(rf) return rf:FindFirstAncestor("Waiting") ~= nil end
	-- On touch prefer the phone request (under the Lobby "Waiting" screen),
	-- on desktop prefer the leaderboard one.
	for _, rf in ipairs(found) do
		if IsTouch and underWaiting(rf) then return rf end
		if (not IsTouch) and (not underWaiting(rf)) then return rf end
	end
	return found[1]
end
local RequestFrame = findRequestFrame()

-- Phone layout? (TradeGUI_Phone, touch device, or the request lives under the
-- Lobby "Waiting" screen). On phone the native flow is: a "!" badge appears on
-- the leaderboard "+" button, and the request shows once the tab is opened.
local IsPhone = IsTouch
	or (TradeGUI ~= nil and string.find(string.lower(TradeGUI.Name), "phone") ~= nil)
	or (RequestFrame ~= nil and RequestFrame:FindFirstAncestor("Waiting") ~= nil)

-- Find the "+" leaderboard button's notification badge (phone only).
local function findPlusBadge()
	if not RequestFrame then return nil end
	local waiting = RequestFrame:FindFirstAncestor("Waiting")
	local scope = waiting or (TradeGUI and TradeGUI:IsA("ScreenGui") and TradeGUI) or PlayerGui
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

-- Hooks run at the start of every new trade (used to reset panel toggles etc.).
local onNewTrade = {}
-- Token that invalidates a pending "trade complete" close if a new trade starts.
local completeToken = 0

-- 6-second accept cooldown that starts whenever an offer changes (native MM2).
local CooldownRunning = false
local Cooldown = 6
local cooldownToken = 0
local startAcceptCooldown  -- forward decl (used by renderOffer's remove handler)

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
		local visual = entry.visual  -- copied straight from the clicked real slot
		local db = Database[category] or ItemDB
		local data = db[itemKey]
		local slot = offerFrame.Container:FindFirstChild("NewItem" .. i)
		if slot and (data or visual) then
			local img  = (visual and visual.Image) or getImage(data and data.Image)
			local name = (visual and visual.Name) or (data and (data.ItemName or data.Name)) or itemKey
			local col  = (visual and visual.Color) or (data and Rarity[data.Rarity]) or Color3.new(1,1,1)
			local chroma = (visual and visual.Chroma) or (data and data.Chroma ~= nil) or false
			slot.Visible = true
			setProp(slot, "Container.Icon", "Image", img)
			setProp(slot, "ItemName.Label", "Text", name)
			setProp(slot, "ItemName.Label", "TextColor3", col)
			setProp(slot, "ItemName.RarityBar", "BackgroundColor3", col)
			setProp(slot, "ItemName", "BackgroundColor3", col)
			setVisible(slot, "ItemName", true)
			setProp(slot, "Container.Amount", "Text", (amount and amount > 1) and ("x" .. amount) or "")
			setProp(slot, "Tags.Chroma", "Visible", chroma and true or false)

			-- Clicking a slot in your own offer removes it (local, no server).
			local removeBtn = resolve(slot, "Container.ActionButton")
			if removeBtn and sideKey == "Player1" then
				trackRender(removeBtn.MouseButton1Click:Connect(function()
					table.remove(DebugTradeTable[sideKey].Offer, i)
					DebugTradeTable.Player1.Accepted = false
					DebugTradeTable.Player2.Accepted = false
					setVisible(TradeRoot, "Actions.Accept.Confirm", false)
					setVisible(TradeRoot, "Actions.Accept.Cancel", false)
					RenderTrade()  -- forward-declared below
					if startAcceptCooldown then startAcceptCooldown() end  -- 6s cd on offer change
				end))
			end
		end
	end
end

-- Iterate every offer frame of a side ("your"/"their") anywhere in PlayerGui,
-- matching this build's names (YourOffer/TheirOffer) as well as Offer1/Offer2.
local function isOfferName(name, side)
	for _, nm in ipairs(OFFER_NAMES[side]) do if nm == name then return true end end
	return false
end
local function eachOffer(side, fn)
	for _, d in ipairs(PlayerGui:GetDescendants()) do
		if d:IsA("GuiObject") and isOfferName(d.Name, side) then fn(d) end
	end
end

local function setLabelText(inst, text)
	if inst:IsA("TextLabel") or inst:IsA("TextButton") then pcall(function() inst.Text = text end) end
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextButton") then pcall(function() d.Text = text end) end
	end
end

-- side = "your" (you) or "their" (other). The accepted indicator: try the native
-- node ("Accepted"/"TradeAccepted"); if this build has none, inject our own
-- green overlay label so the "ACCEPTED" text always shows over the offer.
local function showAcceptedBadge(side, visible, message)
	eachOffer(side, function(offer)
		local native = offer:FindFirstChild("Accepted") or offer:FindFirstChild("Accepted", true)
			or offer:FindFirstChild("TradeAccepted", true)
		if visible then
			local acc = native
			if not acc then
				-- No native node on this build — inject our own green overlay label.
				acc = offer:FindFirstChild("__MHAccepted")
				if not acc then
					acc = Instance.new("TextLabel")
					acc.Name = "__MHAccepted"
					acc.Size = UDim2.new(1, 0, 1, 0)
					acc.BackgroundTransparency = 1
					acc.Font = Enum.Font.GothamBold
					acc.TextSize = 20
					acc.TextColor3 = Color3.fromRGB(60, 220, 90)
					acc.TextStrokeTransparency = 0.4
					acc.ZIndex = 50
					acc.Parent = offer
				end
			end
			revealSubtree(acc)
			if message then setLabelText(acc, message) end
		else
			if native then pcall(function() native.Visible = false end) end
			local inj = offer:FindFirstChild("__MHAccepted")
			if inj then inj.Visible = false end
		end
	end)
end

-- Stamp a player name onto every matching offer's Username label. Tries common
-- child names, then a fuzzy match on placeholder-looking text.
local function setOfferUsername(side, text)
	eachOffer(side, function(offer)
		local u = offer:FindFirstChild("Username") or offer:FindFirstChild("Username", true)
			or offer:FindFirstChild("PlayerName", true) or offer:FindFirstChild("Name", true)
		if not u then
			for _, d in ipairs(offer:GetDescendants()) do
				if d:IsA("TextLabel") then
					local t = tostring(d.Text)
					if t:find("haracter") or t:find("OnlyTw") or t:sub(1, 1) == "(" then u = d; break end
				end
			end
		end
		if u then setLabelText(u, text) end
	end)
end

-- Full re-render of the trade panel CONTENT from the local state table.
-- NOTE: this must NOT toggle panel visibility (Enabled / Container.Trade /
-- Items) — that is owned by startTrade / openItemsPicker / closeItemsPicker.
-- Otherwise adding an item from the picker would flip back to the Trade panel.
function RenderTrade()
	clearRenderConnections()

	-- Second participant's display name (swept across all offer frames).
	setOfferUsername("their", "(" .. DebugTradeTable.Player2.Player.Name .. ")")

	-- Acceptance flags -> the green "Accepted" badges.
	showAcceptedBadge("your", DebugTradeTable.Player1.Accepted, "YOU HAVE ACCEPTED.")
	showAcceptedBadge("their", DebugTradeTable.Player2.Accepted, "OTHER PLAYER HAS ACCEPTED.")

	renderOffer("Player1", Offer1)
	renderOffer("Player2", Offer2)
end

-- Start / restart the 6s "Please wait before accepting" cooldown, mirroring the
-- native ResetCooldown that runs on every offer change.
function startAcceptCooldown()
	Cooldown = 6
	local cdNode = resolve(TradeRoot, "Actions.Accept.Cooldown")
	local function setTitle()
		local txt = " Please wait (" .. Cooldown .. ") before accepting."
		setProp(TradeRoot, "Actions.Accept.Cooldown.Title", "Text", txt)
		if cdNode and cdNode:IsA("TextLabel") then pcall(function() cdNode.Text = txt end) end
	end
	setTitle()
	if not CooldownRunning then
		if cdNode then revealAncestors(cdNode) end
		setVisible(TradeRoot, "Actions.Accept.Cooldown", true)
		CooldownRunning = true
		cooldownToken = cooldownToken + 1
		local myToken = cooldownToken
		task.spawn(function()
			repeat
				task.wait(1)
				if myToken ~= cooldownToken then return end  -- aborted by a new trade
				Cooldown = Cooldown - 1
				setTitle()
			until Cooldown <= 0
			if myToken ~= cooldownToken then return end
			CooldownRunning = false
			setVisible(TradeRoot, "Actions.Accept.Cooldown", false)
		end)
	else
		Cooldown = 6  -- already running: just restart the countdown
	end
end

-- Force-stop the cooldown (on new trade / reset).
local function stopAcceptCooldown()
	cooldownToken = cooldownToken + 1
	CooldownRunning = false
	setVisible(TradeRoot, "Actions.Accept.Cooldown", false)
end

-- Offer an item into whichever side OfferMode currently targets. `visual` (from
-- a clicked real inventory slot) lets offers show real items with no catalog.
local function offerItemLocal(itemKey, category, visual)
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
		local e = { itemKey, 1, category }
		e.visual = visual
		table.insert(side.Offer, e)
	end

	-- Any change to the table resets both acceptance flags, like the server does.
	DebugTradeTable.LastOffer = os.time()
	DebugTradeTable.Player1.Accepted = false
	DebugTradeTable.Player2.Accepted = false

	-- Editing an offer collapses the confirm/cancel steps, matching the live UI.
	setVisible(TradeRoot, "Actions.Accept.Confirm", false)
	setVisible(TradeRoot, "Actions.Accept.Cancel", false)
	RenderTrade()
	startAcceptCooldown()  -- 6s "please wait before accepting"
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
			setProp(slot, "Container.Icon", "Image", getImage(data.Image))
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

-- Read an item slot's on-screen visuals (image / name / rarity colour) so an
-- offer can display the real item without any catalog lookup.
local function readSlotVisual(slot)
	local icon = resolve(slot, "Container.Icon") or slot:FindFirstChild("Icon", true)
	local nameLabel = resolve(slot, "ItemName.Label") or resolve(slot, "Container.ItemName")
		or (slot:FindFirstChild("ItemName") and slot.ItemName:FindFirstChildWhichIsA("TextLabel"))
		or slot:FindFirstChild("Label", true)
	local col = Color3.new(1, 1, 1)
	if nameLabel then
		col = (nameLabel:IsA("TextLabel") and nameLabel.TextColor3) or col
		local holder = nameLabel.Parent
		if holder and holder:IsA("GuiObject") and holder.BackgroundTransparency < 1 then col = holder.BackgroundColor3 end
	end
	return {
		Image = (icon and icon.Image) or "",
		Name  = (nameLabel and nameLabel.Text) or slot.Name,
		Color = col,
		Chroma = slot:FindFirstChild("Chroma", true) ~= nil,
	}
end

-- Hook the game's OWN inventory slots so a tap offers that item by copying its
-- visuals. Name-agnostic: scans the whole item picker for any frame that has
-- BOTH an icon and a button (a real slot), so it works on renamed builds.
local function hookAllInventorySlots()
	local scope = ItemsPicker or TradeGUI
	if not scope then return end
	for _, slot in ipairs(scope:GetDescendants()) do
		if slot:IsA("GuiObject") and not slot:GetAttribute("__MHHooked") then
			local icon = slot:FindFirstChild("Icon") or resolve(slot, "Container.Icon")
			local btn = resolve(slot, "Container.Button") or resolve(slot, "Container.ActionButton")
				or slot:FindFirstChild("Button")
			if icon and icon:IsA("ImageLabel") and btn and btn:IsA("GuiButton") then
				slot:SetAttribute("__MHHooked", true)
				local category = (slot:FindFirstAncestor("Pets") or slot:FindFirstAncestor("PetsFrame")) and "Pets" or "Weapons"
				trackRender(btn.MouseButton1Click:Connect(function()
					offerItemLocal(slot.Name, category, readSlotVisual(slot))
				end))
			end
		end
	end
end

-- Re-hook whenever the game adds new inventory slots.
if ItemsPicker then
	track(ItemsPicker.DescendantAdded:Connect(function()
		task.defer(hookAllInventorySlots)
	end))
end

local function renderInventory()
	if RealCatalog then
		-- We have the real catalog: render our own controlled inventory.
		renderInventoryPane(InventoryFrame, OwnedWeapons, ItemDB, "Weapons")
		renderInventoryPane(PetsFrame, OwnedPets, PetDB, "Pets")
	else
		-- No catalog: leave the game's real inventory in place and just hook it.
		hookAllInventorySlots()
	end
end

--==============================================================================
-- 8. REQUEST MODAL + TRADE LIFECYCLE  (local stand-ins for the Remote chain)
--==============================================================================

-- Configure the request frame for ONE direction only, so the two native
-- variants never stack on top of each other:
--   isIncoming = true  -> "Accepting" (someone sends YOU a request: Accept/Decline)
--   isIncoming = false -> "Sending"   (YOU send a request: waiting + Cancel)
-- Return the direct child of `root` that (recursively) contains a node named
-- `descName` — used to identify the request variants by their buttons rather
-- than by frame name (this build renames the frames).
local function variantContaining(root, descName)
	local node = root:FindFirstChild(descName, true)
	if not node then return nil end
	while node and node.Parent ~= root do node = node.Parent end
	return node
end

local function configureRequest(player2Name, isIncoming)
	if not RequestFrame then return end
	-- Identify the two variants robustly by the buttons they contain:
	--   incoming variant  = the one with an "Accept" button
	--   outgoing variant  = the one with a "Cancel" button
	local accepting = RequestFrame:FindFirstChild("Accepting")
		or variantContaining(RequestFrame, "Accept")
	local sending = RequestFrame:FindFirstChild("Sending")
		or variantContaining(RequestFrame, "Cancel")

	-- Exactly one variant visible; force the other hidden (fixes stacked frames).
	if isIncoming then
		if accepting then revealSubtree(accepting) end
		if sending and sending ~= accepting then sending.Visible = false end
	else
		if sending then revealSubtree(sending) end
		if accepting and accepting ~= sending then accepting.Visible = false end
	end
	if not accepting and not sending then revealSubtree(RequestFrame) end

	-- Name label(s): set the one inside the ACTIVE variant (falls back to any).
	local variant = (isIncoming and accepting) or (not isIncoming and sending) or RequestFrame
	local uName = (variant and variant:FindFirstChild("Username", true))
		or RequestFrame:FindFirstChild("Username", true)
	if uName then pcall(function() uName.Text = player2Name end) end
	local title = (variant and variant:FindFirstChild("Title", true))
		or RequestFrame:FindFirstChild("Title", true)
	if title then
		local msg = isIncoming and (player2Name .. " wants to trade.")
			or ("Waiting for " .. player2Name .. " to respond.")
		pcall(function() title.Text = msg end)
	end

	RequestFrame.Visible = true
	setOfferUsername("their", "(" .. player2Name .. ")")
end

-- Show the request in a chosen direction. PC: reveal it directly in the
-- leaderboard tab. Phone: light the "!" badge on the "+" button and prime the
-- request so it shows once the leaderboard opens (native mobile flow).
local function showRequestModal(player2Name, isIncoming)
	if isIncoming == nil then isIncoming = true end
	PendingP2Name = player2Name
	if not RequestFrame then
		warn("[TradeDebug] TradeRequest frame not found in PlayerGui — cannot show request.")
		return
	end
	-- Always bring the request on-screen so it actually appears (on phone this
	-- also un-hides the leaderboard/Waiting screen it lives in). Reveal ancestors
	-- FIRST, then configureRequest sets Visible + shows exactly one variant.
	revealAncestors(RequestFrame)
	configureRequest(player2Name, isIncoming)
	-- On phone additionally light the "+" notification badge.
	if IsPhone then
		local badge = findPlusBadge()
		if badge then pcall(function() badge.Visible = true end) end
	end
end

-- Open the inventory picker (Items) and hide the Trade panel — the native flow.
-- Having BOTH visible makes the Trade panel overlay the picker and swallow item
-- clicks, which is why items couldn't be added; so they are mutually exclusive.
local function openItemsPicker()
	if ItemsPicker then
		revealAncestors(ItemsPicker)
		revealSubtree(ItemsPicker)  -- show the real inventory regardless of renamed frames
		ItemsPicker.Visible = true
	end
	if TradeRoot then TradeRoot.Visible = false end
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
		completeToken = completeToken + 1
		local myToken = completeToken
		task.delay(2, function()
			-- Abort if a new trade started in the meantime.
			if myToken ~= completeToken then return end
			if processing then processing.Visible = false end
			if TradeGUI and TradeGUI:IsA("ScreenGui") then TradeGUI.Enabled = false end
			if Container then Container.Visible = false end
			-- Reset accepted state so the NEXT trade starts clean.
			DebugTradeTable.Player1.Accepted = false
			DebugTradeTable.Player2.Accepted = false
			showAcceptedBadge("your", false); showAcceptedBadge("their", false)
			for _, f in ipairs(onNewTrade) do pcall(f) end
		end)
	end
end

-- Drive the LOCAL (your) accept UI to match MM2: on accept the green button
-- turns into "Cancel" (Confirm hidden, Cancel shown); on cancel it reverts.
local function setYourAcceptedUI(accepted)
	DebugTradeTable.Player1.Accepted = accepted
	showAcceptedBadge("your", accepted, "YOU HAVE ACCEPTED.")
	setVisible(TradeRoot, "Actions.Accept.Confirm", false)
	setProp(TradeRoot, "Actions.Accept.Confirm", "Active", false)
	setVisible(TradeRoot, "Actions.Accept.Cancel", accepted)
	setProp(TradeRoot, "Actions.Accept.Cancel", "Active", accepted)
	if accepted then
		revealSubtree(resolve(TradeRoot, "Actions.Accept.Cancel"))
		completeTradeIfBothAccepted()
	end
end

-- Begin the offline trade: hide the request, reset offers, open the Trade panel.
-- Invoked by the native MM2 Accept button, mirroring the real
-- AcceptRequest -> StartTrade -> UpdateTrade lifecycle.
local function startTrade(player2Name)
	completeToken = completeToken + 1  -- cancel any pending "trade complete" close
	DebugTradeTable.Player2.Player = { Name = player2Name, __fake = true }
	DebugTradeTable.Player1.Offer = {}
	DebugTradeTable.Player2.Offer = {}
	DebugTradeTable.Player1.Accepted = false
	DebugTradeTable.Player2.Accepted = false
	if RequestFrame then RequestFrame.Visible = false end
	if IsPhone then local b = findPlusBadge(); if b then pcall(function() b.Visible = false end) end end
	-- Clear any leftover accepted badges + reset panel toggles for a fresh trade.
	showAcceptedBadge("your", false); showAcceptedBadge("their", false)
	stopAcceptCooldown()
	for _, f in ipairs(onNewTrade) do pcall(f) end

	-- Open the Trade panel (Items hidden — native default). Bring the trade
	-- ScreenGui + ancestor chain on-screen so the layout pops on.
	if TradeGUI and TradeGUI:IsA("ScreenGui") then TradeGUI.Enabled = true end
	revealAncestors(Offer1 or TradeRoot or Container)
	if Container then Container.Visible = true end
	if TradeRoot then TradeRoot.Visible = true end
	if ItemsPicker then ItemsPicker.Visible = false end

	-- Stamp usernames onto every offer frame (overrides "OnlyTwoChracter").
	setOfferUsername("their", "(" .. player2Name .. ")")
	setOfferUsername("your", "(" .. LocalPlayer.Name .. ")")

	RenderTrade()
	renderInventory()  -- pre-populate so the picker is ready when opened
end

-- Light the remote client's green acceptance flag (Player2 accepted), and
-- complete the trade if the local side has already accepted too.
local function forceRemoteAccept()
	DebugTradeTable.Player2.Accepted = true
	showAcceptedBadge("their", true, "OTHER PLAYER HAS ACCEPTED.")
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
		if TradeGUI and TradeGUI:IsA("ScreenGui") then TradeGUI.Enabled = false end
		setVisible(TradeGUI, "Container.Trade", false)
		setVisible(TradeGUI, "Container.Items", false)
	end)

	-- Wipe environment tables.
	clearRenderConnections()
	for _, con in ipairs(Runtime.Connections) do pcall(function() con:Disconnect() end) end
	Runtime.Connections = {}
	_G.DebugTradeTable = nil
	_G.__TradeDebug = nil

	-- Fade the window (a Frame, tweenable) then drop the whole ScreenGui.
	if panel then
		local win = panel:FindFirstChild("Window")
		if win then pcall(function()
			TweenService:Create(win, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play()
		end) end
		task.delay(0.25, function() pcall(function() panel:Destroy() end) end)
	end
	print("[TradeDebug] Environment wiped.")
end

--==============================================================================
-- 9. THE DEBUG CONTROLLER PANEL  —  "MollyHub"  (sidebar UI, grey-blue)
--==============================================================================
-- Background image: upload your image to Roblox, then paste its decal/image
-- asset id below (keep the "rbxassetid://" prefix). Leave 0 for no image.
local BG_IMAGE = "rbxassetid://0"

-- Grey-blue palette (with a soft blue neon accent, like the reference layout).
local C_BG     = Color3.fromRGB(22, 27, 38)    -- window base
local C_SIDE   = Color3.fromRGB(29, 35, 49)    -- sidebar
local C_ROW    = Color3.fromRGB(35, 43, 60)    -- row / input panel
local C_BTN    = Color3.fromRGB(52, 64, 88)    -- buttons
local C_ACCENT = Color3.fromRGB(108, 150, 210) -- blue neon accent
local C_GREEN  = Color3.fromRGB(60, 170, 115)
local C_RED    = Color3.fromRGB(198, 84, 84)
local C_TXT    = Color3.fromRGB(228, 234, 246)
local C_DIM    = Color3.fromRGB(150, 166, 198)

local function corner(inst, r)
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 8); c.Parent = inst; return c
end
local function pad(inst, px)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, px); p.PaddingBottom = UDim.new(0, px)
	p.PaddingLeft = UDim.new(0, px); p.PaddingRight = UDim.new(0, px)
	p.Parent = inst; return p
end

local Panel = Instance.new("ScreenGui")
Panel.Name = "TradeDebugPanel"
Panel.ResetOnSpawn = false
Panel.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
Panel.IgnoreGuiInset = true
Panel.DisplayOrder = 1000
Panel.Parent = PlayerGui

-- Floating OPEN button (always present) — toggles the window.
local OpenBtn = Instance.new("TextButton")
OpenBtn.Name = "OpenButton"
OpenBtn.Size = UDim2.new(0, 118, 0, 40)
OpenBtn.Position = UDim2.new(0, 16, 0, 90)
OpenBtn.BackgroundColor3 = C_SIDE
OpenBtn.Text = "☰  MollyHub"
OpenBtn.TextColor3 = C_TXT
OpenBtn.Font = Enum.Font.GothamBold
OpenBtn.TextSize = 14
OpenBtn.BorderSizePixel = 0
OpenBtn.Active = true
OpenBtn.Parent = Panel
corner(OpenBtn, 10)
local ObStroke = Instance.new("UIStroke")
ObStroke.Color = C_ACCENT; ObStroke.Thickness = 1.5; ObStroke.Transparency = 0.2; ObStroke.Parent = OpenBtn

local Window = Instance.new("Frame")
Window.Name = "Window"
Window.Size = UDim2.new(0, 430, 0, 300)
Window.Position = UDim2.new(0.5, -215, 0.5, -150)
Window.BackgroundColor3 = C_BG
Window.BorderSizePixel = 0
Window.ClipsDescendants = true
Window.Parent = Panel
corner(Window, 16)
local WStroke = Instance.new("UIStroke")
WStroke.Color = C_ACCENT; WStroke.Thickness = 1.5; WStroke.Transparency = 0.25; WStroke.Parent = Window

-- Background image + overlay for readability.
local Bg = Instance.new("ImageLabel")
Bg.Name = "Bg"; Bg.Size = UDim2.new(1, 0, 1, 0); Bg.BackgroundTransparency = 1
Bg.Image = BG_IMAGE; Bg.ScaleType = Enum.ScaleType.Crop
Bg.ImageTransparency = 0.74; Bg.ZIndex = 0; Bg.Parent = Window
local Overlay = Instance.new("Frame")
Overlay.Size = UDim2.new(1, 0, 1, 0); Overlay.BackgroundColor3 = C_BG
Overlay.BackgroundTransparency = 0.22; Overlay.BorderSizePixel = 0; Overlay.ZIndex = 0; Overlay.Parent = Window

-- Sidebar (left).
local Side = Instance.new("Frame")
Side.Name = "Sidebar"; Side.Size = UDim2.new(0, 122, 1, 0)
Side.BackgroundColor3 = C_SIDE; Side.BackgroundTransparency = 0.1
Side.BorderSizePixel = 0; Side.ZIndex = 2; Side.Parent = Window
local Brand = Instance.new("TextLabel")
Brand.Size = UDim2.new(1, -16, 0, 26); Brand.Position = UDim2.new(0, 12, 0, 12)
Brand.BackgroundTransparency = 1; Brand.Text = "MollyHub"; Brand.TextColor3 = C_TXT
Brand.Font = Enum.Font.GothamBold; Brand.TextSize = 18; Brand.TextXAlignment = Enum.TextXAlignment.Left
Brand.ZIndex = 3; Brand.Parent = Side
local BrandSub = Instance.new("TextLabel")
BrandSub.Size = UDim2.new(1, -16, 0, 12); BrandSub.Position = UDim2.new(0, 12, 0, 34)
BrandSub.BackgroundTransparency = 1; BrandSub.Text = "trade sandbox"; BrandSub.TextColor3 = C_DIM
BrandSub.Font = Enum.Font.Gotham; BrandSub.TextSize = 10; BrandSub.TextXAlignment = Enum.TextXAlignment.Left
BrandSub.ZIndex = 3; BrandSub.Parent = Side
local TabHolder = Instance.new("Frame")
TabHolder.Size = UDim2.new(1, -16, 1, -104); TabHolder.Position = UDim2.new(0, 8, 0, 56)
TabHolder.BackgroundTransparency = 1; TabHolder.ZIndex = 3; TabHolder.Parent = Side
local TabLayout = Instance.new("UIListLayout")
TabLayout.Padding = UDim.new(0, 6); TabLayout.SortOrder = Enum.SortOrder.LayoutOrder; TabLayout.Parent = TabHolder
-- Close button pinned to bottom of the sidebar.
local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(1, -16, 0, 32); CloseBtn.Position = UDim2.new(0, 8, 1, -40)
CloseBtn.BackgroundColor3 = C_ROW; CloseBtn.Text = "✕ Close"; CloseBtn.TextColor3 = C_DIM
CloseBtn.Font = Enum.Font.GothamMedium; CloseBtn.TextSize = 12; CloseBtn.BorderSizePixel = 0
CloseBtn.ZIndex = 3; CloseBtn.Parent = Side; corner(CloseBtn, 8)

-- Content area (right).
local Content = Instance.new("Frame")
Content.Name = "Content"; Content.Size = UDim2.new(1, -122, 1, 0); Content.Position = UDim2.new(0, 122, 0, 0)
Content.BackgroundTransparency = 1; Content.ZIndex = 2; Content.Parent = Window

-- Draggable via the sidebar brand area.
Side.Active = true
do
	local dragging, dragStart, startPos
	track(Side.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true; dragStart = input.Position; startPos = Window.Position
		end
	end))
	track(UIS.InputChanged:Connect(function(input)
		if dragging and Window.Parent and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			Window.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
				startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end))
	track(UIS.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
	end))
end

-- Open/close wiring.
track(OpenBtn.MouseButton1Click:Connect(function() Window.Visible = not Window.Visible end))
track(CloseBtn.MouseButton1Click:Connect(function() Window.Visible = false end))

--------------------------------------------------------------------------------
-- Tab + page system
--------------------------------------------------------------------------------
local pages, tabs = {}, {}
local tabOrder = 0
local function selectTab(name)
	for n, page in pairs(pages) do page.Visible = (n == name) end
	for n, btn in pairs(tabs) do
		btn.BackgroundColor3 = (n == name) and C_ACCENT or C_ROW
		btn.TextColor3 = (n == name) and Color3.fromRGB(255,255,255) or C_DIM
	end
end
local function makeTab(name)
	tabOrder = tabOrder + 1
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 0, 34); btn.BackgroundColor3 = C_ROW
	btn.Text = name; btn.TextColor3 = C_DIM; btn.Font = Enum.Font.GothamMedium; btn.TextSize = 13
	btn.BorderSizePixel = 0; btn.ZIndex = 3; btn.LayoutOrder = tabOrder; btn.Parent = TabHolder
	corner(btn, 8)
	local page = Instance.new("ScrollingFrame")
	page.Name = name; page.Size = UDim2.new(1, 0, 1, 0); page.BackgroundTransparency = 1
	page.BorderSizePixel = 0; page.ScrollBarThickness = 4; page.ScrollBarImageColor3 = C_ACCENT
	page.CanvasSize = UDim2.new(0,0,0,0); page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	page.ZIndex = 2; page.Visible = false; page.Parent = Content
	local ll = Instance.new("UIListLayout")
	ll.Padding = UDim.new(0, 8); ll.SortOrder = Enum.SortOrder.LayoutOrder
	ll.HorizontalAlignment = Enum.HorizontalAlignment.Center; ll.Parent = page
	pad(page, 12)
	pages[name] = page; tabs[name] = btn
	track(btn.MouseButton1Click:Connect(function() selectTab(name) end))
	return page
end

-- A settings-style row: title + description on the left, a control on the right.
local rowOrder = 0
local function makeRow(page, title, desc)
	rowOrder = rowOrder + 1
	local rowF = Instance.new("Frame")
	rowF.Size = UDim2.new(1, 0, 0, 52); rowF.BackgroundColor3 = C_ROW
	rowF.BorderSizePixel = 0; rowF.ZIndex = 2; rowF.LayoutOrder = rowOrder; rowF.Parent = page
	corner(rowF, 10)
	local t = Instance.new("TextLabel")
	t.Size = UDim2.new(1, -96, 0, 18); t.Position = UDim2.new(0, 12, 0, 8)
	t.BackgroundTransparency = 1; t.Text = title; t.TextColor3 = C_TXT
	t.Font = Enum.Font.GothamMedium; t.TextSize = 13; t.TextXAlignment = Enum.TextXAlignment.Left
	t.ZIndex = 3; t.Parent = rowF
	local d = Instance.new("TextLabel")
	d.Size = UDim2.new(1, -96, 0, 16); d.Position = UDim2.new(0, 12, 0, 27)
	d.BackgroundTransparency = 1; d.Text = desc or ""; d.TextColor3 = C_DIM
	d.Font = Enum.Font.Gotham; d.TextSize = 11; d.TextXAlignment = Enum.TextXAlignment.Left
	d.TextTruncate = Enum.TextTruncate.AtEnd; d.ZIndex = 3; d.Parent = rowF
	return rowF
end

-- Pill toggle placed on the right of a row. cb(state) fires on change.
local function makeRowToggle(page, title, desc, initial, cb)
	local rowF = makeRow(page, title, desc)
	local state = initial and true or false
	local track_ = Instance.new("TextButton")
	track_.Size = UDim2.new(0, 46, 0, 24); track_.Position = UDim2.new(1, -58, 0.5, -12)
	track_.AutoButtonColor = false; track_.Text = ""; track_.BorderSizePixel = 0
	track_.BackgroundColor3 = state and C_ACCENT or Color3.fromRGB(60, 68, 88)
	track_.ZIndex = 4; track_.Parent = rowF; corner(track_, 12)
	local knob = Instance.new("Frame")
	knob.Size = UDim2.new(0, 20, 0, 20); knob.BorderSizePixel = 0
	knob.BackgroundColor3 = Color3.fromRGB(255,255,255); knob.ZIndex = 5; knob.Parent = track_
	corner(knob, 10)
	local function paint()
		track_.BackgroundColor3 = state and C_ACCENT or Color3.fromRGB(60, 68, 88)
		knob.Position = state and UDim2.new(1, -22, 0.5, -10) or UDim2.new(0, 2, 0.5, -10)
	end
	paint()
	track(track_.MouseButton1Click:Connect(function()
		state = not state; paint(); cb(state)
	end))
	return function() return state end, function(v) state = v; paint() end
end

-- A button placed on the right of a row. cb() fires on click.
local function makeRowButton(page, title, desc, btnText, color, cb)
	local rowF = makeRow(page, title, desc)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0, 74, 0, 30); b.Position = UDim2.new(1, -86, 0.5, -15)
	b.BackgroundColor3 = color or C_BTN; b.Text = btnText; b.TextColor3 = C_TXT
	b.Font = Enum.Font.GothamMedium; b.TextSize = 12; b.BorderSizePixel = 0
	b.ZIndex = 4; b.Parent = rowF; corner(b, 8)
	track(b.MouseButton1Click:Connect(cb))
	return b
end

--------------------------------------------------------------------------------
-- PAGE 1 — Trade
--------------------------------------------------------------------------------
local pTrade = makeTab("Trade")

-- Name input (a full-width row with a TextBox).
local nameRow = makeRow(pTrade, "Second player", "pick from server ▼ or type")
local NameBox = Instance.new("TextBox")
NameBox.Size = UDim2.new(0, 118, 0, 30); NameBox.Position = UDim2.new(1, -130, 0.5, -15)
NameBox.BackgroundColor3 = C_BG; NameBox.Text = "Player2"
NameBox.PlaceholderText = "name…"; NameBox.PlaceholderColor3 = C_DIM
NameBox.TextColor3 = C_TXT; NameBox.Font = Enum.Font.Gotham; NameBox.TextSize = 12
NameBox.ClearTextOnFocus = false; NameBox.BorderSizePixel = 0; NameBox.ClipsDescendants = true
NameBox.ZIndex = 4; NameBox.Parent = nameRow; corner(NameBox, 8); pad(NameBox, 6)

local function currentName()
	local n = tostring(NameBox.Text)
	if n == "" then n = "Player2" end
	return n
end

-- Player picker: a collapsible list of the players currently on the server.
local pickRow = makeRow(pTrade, "Choose player", "tap to select from server")
local PickBtn = Instance.new("TextButton")
PickBtn.Size = UDim2.new(0, 74, 0, 30); PickBtn.Position = UDim2.new(1, -86, 0.5, -15)
PickBtn.BackgroundColor3 = C_ACCENT; PickBtn.Text = "Players ▼"; PickBtn.TextColor3 = C_TXT
PickBtn.Font = Enum.Font.GothamMedium; PickBtn.TextSize = 12; PickBtn.BorderSizePixel = 0
PickBtn.ZIndex = 4; PickBtn.Parent = pickRow; corner(PickBtn, 8)

rowOrder = rowOrder + 1
local PlayerList = Instance.new("Frame")
PlayerList.Size = UDim2.new(1, 0, 0, 0); PlayerList.AutomaticSize = Enum.AutomaticSize.Y
PlayerList.BackgroundColor3 = C_BG; PlayerList.BorderSizePixel = 0; PlayerList.ZIndex = 2
PlayerList.LayoutOrder = rowOrder; PlayerList.Visible = false; PlayerList.Parent = pTrade
corner(PlayerList, 10)
local pll = Instance.new("UIListLayout")
pll.Padding = UDim.new(0, 4); pll.SortOrder = Enum.SortOrder.LayoutOrder; pll.Parent = PlayerList
pad(PlayerList, 6)

local function refreshPlayers()
	for _, c in ipairs(PlayerList:GetChildren()) do
		if c:IsA("TextButton") then c:Destroy() end
	end
	local n = 0
	for _, pl in ipairs(Players:GetPlayers()) do
		if pl ~= LocalPlayer then
			n = n + 1
			local b = Instance.new("TextButton")
			b.Size = UDim2.new(1, 0, 0, 28); b.BackgroundColor3 = C_BTN
			b.Text = pl.Name; b.TextColor3 = C_TXT; b.Font = Enum.Font.Gotham; b.TextSize = 12
			b.BorderSizePixel = 0; b.ZIndex = 3; b.LayoutOrder = n; b.Parent = PlayerList
			corner(b, 6)
			b.MouseButton1Click:Connect(function()
				NameBox.Text = pl.Name
				PlayerList.Visible = false
				PickBtn.Text = "Players ▼"
			end)
		end
	end
	if n == 0 then
		local e = Instance.new("TextLabel")
		e.Size = UDim2.new(1, 0, 0, 24); e.BackgroundTransparency = 1
		e.Text = "no other players"; e.TextColor3 = C_DIM; e.Font = Enum.Font.Gotham
		e.TextSize = 12; e.ZIndex = 3; e.Parent = PlayerList
	end
end
track(PickBtn.MouseButton1Click:Connect(function()
	PlayerList.Visible = not PlayerList.Visible
	PickBtn.Text = PlayerList.Visible and "Players ▲" or "Players ▼"
	if PlayerList.Visible then refreshPlayers() end
end))

makeRowButton(pTrade, "Incoming request", "someone sends YOU a request", "Show", C_ACCENT, function()
	showRequestModal(currentName(), true)
end)
makeRowButton(pTrade, "Outgoing request", "YOU send a request (waiting)", "Show", C_BTN, function()
	showRequestModal(currentName(), false)
end)

local ItemsOpen = false
local _, setItemsToggle = makeRowToggle(pTrade, "Item picker", "open inventory to add items", false, function(on)
	ItemsOpen = on
	if on then openItemsPicker() else closeItemsPicker() end
end)
table.insert(onNewTrade, function() ItemsOpen = false; setItemsToggle(false) end)

makeRowToggle(pTrade, "Add to Player 2 side", "off = your side (left) / on = right", false, function(on)
	OfferMode = on and "Player2" or "Player1"
end)

--------------------------------------------------------------------------------
-- PAGE 2 — Spawn (add game items into your inventory)
--------------------------------------------------------------------------------
local pSpawn = makeTab("Spawn")

-- Flat, name-sorted index of the whole catalog (weapons + pets), rebuildable
-- when the real catalog finishes loading in the background.
local spawnIndex = {}
local function buildSpawnIndex()
	spawnIndex = {}
	for k, v in pairs(ItemDB) do
		if type(v) == "table" then
			table.insert(spawnIndex, { key = k, name = tostring(v.ItemName or v.Name or k), cat = "Weapons", rarity = v.Rarity })
		end
	end
	for k, v in pairs(PetDB) do
		if type(v) == "table" then
			table.insert(spawnIndex, { key = k, name = tostring(v.Name or v.ItemName or k), cat = "Pets", rarity = v.Rarity })
		end
	end
	table.sort(spawnIndex, function(a, b) return a.name:lower() < b.name:lower() end)
end
buildSpawnIndex()

-- Catalog status line (real vs fallback).
rowOrder = rowOrder + 1
local CatLabel = Instance.new("TextLabel")
CatLabel.Size = UDim2.new(1, 0, 0, 16); CatLabel.BackgroundTransparency = 1
CatLabel.Text = CatalogStatus; CatLabel.TextColor3 = C_DIM; CatLabel.Font = Enum.Font.Gotham
CatLabel.TextSize = 11; CatLabel.TextXAlignment = Enum.TextXAlignment.Left
CatLabel.TextWrapped = true; CatLabel.ZIndex = 2; CatLabel.LayoutOrder = rowOrder; CatLabel.Parent = pSpawn

-- Data diagnostic: shows why the catalog is/ isn't real (tap to run).
local Diag = Instance.new("TextLabel")
Diag.Size = UDim2.new(1, 0, 0, 10); Diag.AutomaticSize = Enum.AutomaticSize.Y
Diag.BackgroundColor3 = C_BG; Diag.BorderSizePixel = 0; Diag.ZIndex = 2
Diag.Text = ""; Diag.TextColor3 = C_DIM; Diag.Font = Enum.Font.Code; Diag.TextSize = 11
Diag.TextWrapped = true; Diag.TextYAlignment = Enum.TextYAlignment.Top
Diag.TextXAlignment = Enum.TextXAlignment.Left; Diag.Visible = false
rowOrder = rowOrder + 1; Diag.LayoutOrder = rowOrder; Diag.Parent = pSpawn
pad(Diag, 8); corner(Diag, 8)

makeRowButton(pSpawn, "Diagnose data", "why catalog is real / fallback", "Diag", C_ACCENT, function()
	local rs = game:GetService("ReplicatedStorage")
	local gsd = findGetSync()
	local pd = rawget(_G, "PlayerData")
	local lines = {}
	table.insert(lines, "GetSyncData: " .. (gsd and gsd:GetFullName() or "NOT FOUND"))
	table.insert(lines, "_G.PlayerData: " .. (type(pd) == "table" and "yes" or "no")
		.. (type(pd) == "table" and pd.Weapons and pd.Weapons.Owned and (" (" .. countKeys(pd.Weapons.Owned) .. " weapons)") or ""))
	table.insert(lines, "catalog: " .. CatalogStatus)
	table.insert(lines, "lastError: " .. tostring(lastSyncError))
	table.insert(lines, "ItemDB=" .. countKeys(ItemDB) .. " PetDB=" .. countKeys(PetDB))
	local samp = {}
	for _, e in ipairs(spawnIndex) do if #samp < 6 then table.insert(samp, e.name) end end
	table.insert(lines, "sample: " .. table.concat(samp, ", "))
	local rfs = {}
	for _, c in ipairs(rs:GetChildren()) do
		if c:IsA("RemoteFunction") and #rfs < 18 then table.insert(rfs, c.Name) end
	end
	table.insert(lines, "RS RemoteFunctions: " .. table.concat(rfs, ", "))
	-- Count hookable inventory slots currently in the picker.
	local nslots = 0
	if ItemsPicker then
		for _, s in ipairs(ItemsPicker:GetDescendants()) do
			local icon = s:FindFirstChild("Icon") or resolve(s, "Container.Icon")
			local btn = resolve(s, "Container.Button") or resolve(s, "Container.ActionButton") or s:FindFirstChild("Button")
			if icon and icon:IsA("ImageLabel") and btn and btn:IsA("GuiButton") then nslots = nslots + 1 end
		end
	end
	table.insert(lines, "ItemsPicker: " .. (ItemsPicker and ItemsPicker:GetFullName() or "nil") .. " | slots=" .. nslots)
	Diag.Text = table.concat(lines, "\n")
	Diag.Visible = true
	-- also re-attempt the real fetch in the background
	task.spawn(applyRealData)
end)

local spawnRow = makeRow(pSpawn, "Spawn item", "search the game catalog, tap +")
local SearchBox = Instance.new("TextBox")
SearchBox.Size = UDim2.new(0, 118, 0, 30); SearchBox.Position = UDim2.new(1, -130, 0.5, -15)
SearchBox.BackgroundColor3 = C_BG; SearchBox.Text = ""
SearchBox.PlaceholderText = "search…"; SearchBox.PlaceholderColor3 = C_DIM
SearchBox.TextColor3 = C_TXT; SearchBox.Font = Enum.Font.Gotham; SearchBox.TextSize = 12
SearchBox.ClearTextOnFocus = false; SearchBox.BorderSizePixel = 0; SearchBox.ClipsDescendants = true
SearchBox.ZIndex = 4; SearchBox.Parent = spawnRow; corner(SearchBox, 8); pad(SearchBox, 6)

rowOrder = rowOrder + 1
local SpawnList = Instance.new("Frame")
SpawnList.Size = UDim2.new(1, 0, 0, 0); SpawnList.AutomaticSize = Enum.AutomaticSize.Y
SpawnList.BackgroundColor3 = C_BG; SpawnList.BorderSizePixel = 0; SpawnList.ZIndex = 2
SpawnList.LayoutOrder = rowOrder; SpawnList.Parent = pSpawn
corner(SpawnList, 10)
local sll = Instance.new("UIListLayout")
sll.Padding = UDim.new(0, 4); sll.SortOrder = Enum.SortOrder.LayoutOrder; sll.Parent = SpawnList
pad(SpawnList, 6)

local function refreshSpawn(query)
	for _, c in ipairs(SpawnList:GetChildren()) do
		if c:IsA("TextButton") or c:IsA("TextLabel") then c:Destroy() end
	end
	query = tostring(query or ""):lower()
	local shown = 0
	for _, it in ipairs(spawnIndex) do
		if shown >= 40 then break end
		if query == "" or it.name:lower():find(query, 1, true) or tostring(it.key):lower():find(query, 1, true) then
			shown = shown + 1
			local b = Instance.new("TextButton")
			b.Size = UDim2.new(1, 0, 0, 28); b.BackgroundColor3 = C_BTN
			b.Text = "  " .. it.name .. "   +"
			b.TextXAlignment = Enum.TextXAlignment.Left
			b.TextColor3 = Rarity[it.rarity] or C_TXT
			b.Font = Enum.Font.Gotham; b.TextSize = 12; b.BorderSizePixel = 0
			b.ZIndex = 3; b.LayoutOrder = shown; b.Parent = SpawnList; corner(b, 6)
			track(b.MouseButton1Click:Connect(function()
				local owned = (it.cat == "Pets") and OwnedPets or OwnedWeapons
				owned[it.key] = (owned[it.key] or 0) + 1
				renderInventory()  -- refresh the trade inventory immediately
				b.Text = "  " .. it.name .. "   ✓ x" .. owned[it.key]
			end))
		end
	end
	if shown == 0 then
		local e = Instance.new("TextLabel")
		e.Size = UDim2.new(1, 0, 0, 24); e.BackgroundTransparency = 1
		e.Text = "no matches"; e.TextColor3 = C_DIM; e.Font = Enum.Font.Gotham
		e.TextSize = 12; e.ZIndex = 3; e.Parent = SpawnList
	end
end
track(SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
	refreshSpawn(SearchBox.Text)
end))
refreshSpawn("")

-- When the real catalog/inventory finishes loading in the background, rebuild.
onCatalogLoaded = function()
	buildSpawnIndex()
	refreshSpawn(SearchBox.Text)
	renderInventory()
	CatLabel.Text = CatalogStatus
end

--------------------------------------------------------------------------------
-- PAGE 3 — Accept
--------------------------------------------------------------------------------
local pAccept = makeTab("Accept")

local _, setAccP1 = makeRowToggle(pAccept, "You accepted (P1)", "YOU HAVE ACCEPTED.", false, function(on)
	setYourAcceptedUI(on)  -- also flips the green Accept button to Cancel
end)
local _, setAccP2 = makeRowToggle(pAccept, "Other accepted (P2)", "OTHER PLAYER HAS ACCEPTED.", false, function(on)
	DebugTradeTable.Player2.Accepted = on
	showAcceptedBadge("their", on, "OTHER PLAYER HAS ACCEPTED.")
	if on then completeTradeIfBothAccepted() end
end)
-- Reset both accept toggles whenever a fresh trade starts.
table.insert(onNewTrade, function() setAccP1(false); setAccP2(false) end)
makeRowButton(pAccept, "Terminate", "close & wipe the harness", "Wipe", C_RED, function()
	terminate(Panel)
end)

--------------------------------------------------------------------------------
-- PAGE 3 — Info
--------------------------------------------------------------------------------
local pInfo = makeTab("Info")
local function ok(x) return x and "OK" or "nil" end
local Status = Instance.new("TextLabel")
Status.Size = UDim2.new(1, 0, 0, 120); Status.BackgroundColor3 = C_ROW
Status.BorderSizePixel = 0; Status.ZIndex = 2; Status.LayoutOrder = 1; Status.Parent = pInfo
Status.Text = ("  layout: %s (%s)\n  Req %s · Trade %s · Cont %s\n  Items %s · Inv %s · Pets %s\n\n  offline • no server calls"):format(
	(TradeGUI and TradeGUI.Name or "NOT FOUND"), IsPhone and "phone" or "pc",
	ok(RequestFrame), ok(TradeRoot), ok(Container), ok(ItemsPicker), ok(InventoryFrame), ok(PetsFrame))
Status.TextColor3 = C_DIM; Status.Font = Enum.Font.Gotham; Status.TextSize = 12
Status.TextWrapped = true; Status.TextYAlignment = Enum.TextYAlignment.Top
Status.TextXAlignment = Enum.TextXAlignment.Left
corner(Status, 10)

-- Diagnostic: list the real child names of every Offer1/Offer2 frame, so we can
-- see whether "Accepted" / "Username" exist and their exact names.
local Dump = Instance.new("TextLabel")
Dump.Size = UDim2.new(1, 0, 0, 10); Dump.AutomaticSize = Enum.AutomaticSize.Y
Dump.BackgroundColor3 = C_BG; Dump.BorderSizePixel = 0; Dump.ZIndex = 2; Dump.LayoutOrder = 3
Dump.Text = ""; Dump.TextColor3 = C_DIM; Dump.Font = Enum.Font.Code; Dump.TextSize = 11
Dump.TextWrapped = true; Dump.TextYAlignment = Enum.TextYAlignment.Top
Dump.TextXAlignment = Enum.TextXAlignment.Left; Dump.Visible = false; Dump.Parent = pInfo
pad(Dump, 8); corner(Dump, 8)

makeRowButton(pInfo, "Trade tree", "dump the real node names", "Dump", C_ACCENT, function()
	local lines = {}
	local count = 0
	local function walk(inst, depth)
		if depth > 3 or count > 140 then return end
		for _, c in ipairs(inst:GetChildren()) do
			count = count + 1
			if count > 140 then table.insert(lines, "  …(truncated)"); return end
			local extra = ""
			if c:IsA("TextLabel") or c:IsA("TextButton") then
				extra = ' "' .. string.sub(tostring(c.Text), 1, 22) .. '"'
			end
			table.insert(lines, string.rep(" ", depth * 2) .. c.Name .. " [" .. c.ClassName .. "]" .. extra)
			walk(c, depth + 1)
		end
	end
	local root = TradeRoot or Container or TradeGUI
	if root then
		table.insert(lines, "TRADE " .. root:GetFullName())
		walk(root, 0)
	else
		table.insert(lines, "no trade root resolved")
	end
	if RequestFrame then
		table.insert(lines, "")
		table.insert(lines, "REQUEST " .. RequestFrame:GetFullName())
		count = 0
		walk(RequestFrame, 0)
	end
	Dump.Text = table.concat(lines, "\n")
	Dump.Visible = true
	Dump.Size = UDim2.new(1, 0, 0, 10)
end)

selectTab("Trade")

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
	-- Accept flow (matches MM2): Accept -> Confirm shows -> Confirm -> accepted,
	-- the green button becomes Cancel -> Cancel reverts.
	local acceptBtn = resolve(TradeRoot, "Actions.Accept.ActionButton")
	if acceptBtn then
		track(acceptBtn.MouseButton1Click:Connect(function()
			if CooldownRunning then return end                   -- blocked during 6s cooldown
			if DebugTradeTable.Player1.Accepted then return end  -- already accepted (Cancel showing)
			revealSubtree(resolve(TradeRoot, "Actions.Accept.Confirm"))
			setVisible(TradeRoot, "Actions.Accept.Confirm", true)
		end))
	end
	local confirmBtn = resolve(TradeRoot, "Actions.Accept.Confirm.ActionButton")
	if confirmBtn then
		track(confirmBtn.MouseButton1Click:Connect(function()
			if CooldownRunning then return end                   -- blocked during 6s cooldown
			setYourAcceptedUI(true)   -- hides Confirm, shows Cancel, lights badge
			if setAccP1 then setAccP1(true) end
		end))
	end
	-- Cancel your acceptance -> revert the button back to Accept.
	local cancelBtn = resolve(TradeRoot, "Actions.Accept.Cancel.ActionButton")
	if cancelBtn then
		track(cancelBtn.MouseButton1Click:Connect(function()
			setYourAcceptedUI(false)
			if setAccP1 then setAccP1(false) end
		end))
	end
end

-- Load the real catalog/inventory in the BACKGROUND (InvokeServer may yield) so
-- the menu is already on screen; the spawn list + inventory refresh when it lands.
task.spawn(applyRealData)

print("[TradeDebug] Harness loaded. Layout: " .. (TradeGUI and TradeGUI.Name or "NOT FOUND") ..
	" | Use the TradeDebugPanel to drive the offline trade.")
