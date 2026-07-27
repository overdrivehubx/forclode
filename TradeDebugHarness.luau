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
-- OPTIONAL: YOUR OWN WEAPON-SKIN MODELS  (for the Equip Spawner)
--------------------------------------------------------------------------------
-- MM2's real weapon models live on the SERVER, so the client isn't allowed to
-- load them by their in-game ItemID. BUT you can drop in your OWN uploaded
-- models here and the "Equip item" button will load them and put them in your
-- hand (client-side — only you see it).
--   1. Upload the skin's Model to Roblox under YOUR OWN account (publish it),
--      so the client is permitted to load it.
--   2. Add an entry below:  ["ItemName"] = <assetId>
--      • ItemName = the name exactly as shown in the Spawner (e.g. "Gingerscope")
--      • assetId  = a number OR a "rbxassetid://123..." string
--==============================================================================
_G.MH_SkinModels = _G.MH_SkinModels or {
	-- ["Gingerscope"] = 0,               -- <- put your model's asset id here
	-- ["8bit"]        = "rbxassetid://0",
}

-- Menu too big (or too small) on your device / executor? Tune this. 1 = Rubis
-- default, lower = smaller (e.g. 0.7 = 70%, 0.5 = half). Applies to the whole
-- MollyHub window.
_G.MH_MenuScale = _G.MH_MenuScale or 0.7

-- Known weapon MESHES, by item name: ["ItemName"] = { mesh = <id>, tex = <id> }.
-- Meshes and textures render on ANY account (models don't), so an entry here is
-- the surest way to get an item into your hand. The Equip button checks this
-- FIRST. Ids can be read off any weapon the client already shows — the equip
-- diagnostic's harvest[...] section lists them as mesh+texture pairs.
-- Entries also carry the mesh SCALE (sx/sy/sz). MM2 sets a different scale per
-- weapon, so a skin swapped in without it renders at the previous item's size.
-- Full shape of an entry (only mesh is required):
--   mesh, tex          asset ids
--   sx, sy, sz + k     the mesh Scale ("scale") or the part Size in studs ("size")
--   ox, oy, oz         mesh Offset          vx, vy, vz  mesh VertexColor
--   cf                 12 CFrame numbers: where it sits on your body
--   grip               12 CFrame numbers: how it sits in your hand
_G.MH_MeshMap = _G.MH_MeshMap or {
	-- Verified by hand AND matched independently by the skin learner, which read
	-- the same two ids off the game. Kept as a worked example of the format.
	["Gingerscope"] = {
		mesh = "15374602183", tex = "15409041564",
		sx = 0.084, sy = 0.084, sz = 0.084, k = "scale", slot = "Gun",
		ox = 0, oy = 0, oz = 0, vx = 1, vy = 1, vz = 1,
		cf = { 0.13, 0, 0.075, 1, 0, 0, 0, 0.707388222, 0.706825197, 0, -0.706825197, 0.707388222 },
		grip = { 0, -0.4, 0.9, 1, 0, 0, 0, 1, 0, 0, 0, 1 },
	},
}

-- Weapon looking too big or too small? Multiplies every skin's scale. 1 = the
-- size the game itself uses.
_G.MH_SkinScale = _G.MH_SkinScale or 1

-- Equipping an item in the GAME'S OWN inventory wears its skin, when we know
-- one. Set false to only equip from the Spawner tab's button.
if _G.MH_InventoryEquip == nil then _G.MH_InventoryEquip = true end

-- Where the equipped weapon sits in your hand: {x, y, z, rotX, rotY, rotZ} —
-- studs and degrees. Tweak if the model floats or points the wrong way.
_G.MH_HandOffset = _G.MH_HandOffset or { 0, -1, 0, 0, 0, 0 }

--==============================================================================
-- SAFETY WRAPPER — guarantee a visible result on EVERY executor.
-- Some mobile executors (e.g. Potassium) reject APIs others allow, which can
-- make the whole script fail silently with no panel. If anything below throws
-- at load, show the error ON SCREEN (no console needed) instead of nothing.
--==============================================================================
local function __showFatal(msg)
	pcall(function()
		local old = PlayerGui:FindFirstChild("TradeDebugError")
		if old then old:Destroy() end
		local g = Instance.new("ScreenGui")
		g.Name = "TradeDebugError"; g.ResetOnSpawn = false; g.IgnoreGuiInset = true
		g.DisplayOrder = 100000
		local f = Instance.new("TextLabel")
		f.Size = UDim2.new(0, 540, 0, 200); f.Position = UDim2.new(0.5, -270, 0, 60)
		f.BackgroundColor3 = Color3.fromRGB(28, 18, 22); f.BorderSizePixel = 0
		f.TextColor3 = Color3.fromRGB(255, 170, 170)
		f.Font = Enum.Font.Code; f.TextSize = 14; f.TextWrapped = true
		f.TextYAlignment = Enum.TextYAlignment.Top; f.TextXAlignment = Enum.TextXAlignment.Left
		f.Text = "  [MollyHub] load error — send this to fix it:\n\n  " .. tostring(msg)
		f.Parent = g
		g.Parent = PlayerGui
	end)
	warn("[TradeDebug] fatal: " .. tostring(msg))
end

local __ok, __err = xpcall(function()

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

-- Muted, MM2-ish rarity colours (the source's live map isn't reachable offline).
-- Real MM2 rarity colours (from the game's own rarity table / GiveWeapon GUI).
-- The trade + inventory UIs paint the ItemName PLATE with these; Common is
-- forced to the game's grey (0.415686 ≈ RGB 106) wherever it renders.
local Rarity = {
	["Classic"]   = Color3.fromRGB(255, 255, 0),
	["Common"]    = Color3.fromRGB(255, 255, 255),
	["Uncommon"]  = Color3.fromRGB(85, 193, 202),
	["Rare"]      = Color3.fromRGB(0, 255, 0),
	["Legendary"] = Color3.fromRGB(255, 0, 0),
	["Godly"]     = Color3.fromRGB(255, 0, 255),
	["Ancient"]   = Color3.fromRGB(170, 0, 0),
	["Divine"]    = Color3.fromRGB(255, 90, 160),
	["Vintage"]   = Color3.fromRGB(0, 200, 220),
	["Victim"]    = Color3.fromRGB(255, 140, 0),
	["Unique"]    = Color3.fromRGB(230, 200, 60),
	["Christmas"] = Color3.fromRGB(255, 40, 40),
	["Halloween"] = Color3.fromRGB(255, 120, 0),
}
local RARITY_GREY = Color3.fromRGB(95, 95, 95)  -- Common plate: game uses Color3.new(0.372549)

-- Coerce whatever the live "Rarity" module stores for a tier into a Color3.
-- The game's Sync/Rarity table may hold a bare Color3, or a record like
-- {Color=..}/{Colour=..}/[1]=.., or a {r,g,b} triple (0-1 or 0-255). Returns
-- nil when the value can't be read as a colour, so callers keep the embedded one.
local function toColor3(v)
	if typeof(v) == "Color3" then return v end
	if type(v) == "table" then
		for _, k in ipairs({ "Color", "Colour", "Color3", "Plate", 1 }) do
			if typeof(v[k]) == "Color3" then return v[k] end
		end
		local r, g, b = v.R or v.r or v[1], v.G or v.g or v[2], v.B or v.b or v[3]
		if type(r) == "number" and type(g) == "number" and type(b) == "number" then
			if r > 1 or g > 1 or b > 1 then return Color3.fromRGB(r, g, b) end
			return Color3.new(r, g, b)
		end
	end
	return nil
end

local RarityValue = {
	Classic=1, Common=2, Uncommon=3, Rare=4, Legendary=5,
	Godly=6, Divine=6.6, Ancient=6.5, Victim=7, Unique=11,
	Christmas=1.6, Halloween=1.5,
}

local ItemDB = {
-- === Real MM2 catalog embedded from Mm2.rbxl Sync.Item (1478 items, Chroma incl.) ===
	["10K"]={ItemName="Gold Icebreaker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7532367817",ItemType="Knife",Rarity="Victim"},
	["10K2"]={ItemName="Gold Iceblaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7532385790",ItemType="Gun",Rarity="Victim"},
	["10MEvoKnife"]={ItemName="10M Evo",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12697571074",ItemType="Knife",Rarity="Ancient"},
	["10MFlame"]={ItemName="10M Flames",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12697094641",ItemType="Knife",Rarity="Ancient"},
	["10MHammer"]={ItemName="10M Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12697258965",ItemType="Knife",Rarity="Ancient"},
	["10MKnife"]={ItemName="10M Knife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12697198308",ItemType="Knife",Rarity="Ancient"},
	["10MWing"]={ItemName="10M Revolver",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12697314808",ItemType="Gun",Rarity="Ancient"},
	["1K"]={ItemName="Bronze Icebreaker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7532367786",ItemType="Knife",Rarity="Victim"},
	["1K2"]={ItemName="Bronze Iceblaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7532385763",ItemType="Gun",Rarity="Victim"},
	["2015"]={ItemName="2015",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=199026945",ItemType="Knife",Rarity="Common"},
	["22lookzz"]={ItemName="Kai's Heat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12565856718",ItemType="Knife",Rarity="Ancient"},
	["22lookzzL"]={ItemName="Kai's Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12565923698",ItemType="Gun",Rarity="Ancient"},
	["5K"]={ItemName="Silver Icebreaker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6738084960",ItemType="Knife",Rarity="Victim"},
	["5K2"]={ItemName="Silver Iceblaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6738084727",ItemType="Gun",Rarity="Victim"},
	["8bit"]={ItemName="8bit",Image="http://www.roblox.com/asset/?id=198453482",ItemType="Knife",Rarity="Common"},
	["???ChampulseV???"]={ItemName="???ChampulseV???",Image="rbxassetid://14144117130",ItemType="Gun",Rarity="Dream"},
	["Abstract"]={ItemName="Abstract",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365569428",ItemType="Knife",Rarity="Rare"},
	["Ace"]={ItemName="Ace",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238546577",ItemType="Gun",Rarity="Rare"},
	["AcidWaves"]={ItemName="Acid Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13552947684",ItemType="Knife",Rarity="Common"},
	["Adurite"]={ItemName="Adurite",Image="http://www.roblox.com/asset/?id=192492943",ItemType="Knife",Rarity="Uncommon"},
	["AduriteGun"]={ItemName="Adurite",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=175668921",ItemType="Gun",Rarity="Uncommon"},
	["Affect"]={ItemName="Affection",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9145774032",ItemType="Knife",Rarity="Legendary"},
	["Aid"]={ItemName="Juice",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203807397",ItemType="Gun",Rarity="Common"},
	["Alex"]={ItemName="Alex",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=546159020",ItemType="Knife",Rarity="Common"},
	["AlexisGemstone"]={ItemName="Alexis Gemstone",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12685169299",ItemType="Knife",Rarity="Godly"},
	["AlexisGun"]={ItemName="Alexis Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12685180059",ItemType="Gun",Rarity="Godly"},
	["Alien"]={ItemName="Alien",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13073203994",ItemType="Knife",Rarity="Common"},
	["Alien2a"]={ItemName="Alien",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=12877358827",ItemType="Knife",Rarity="Common"},
	["AlienBringer"]={ItemName="Light Alien Bringer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154542607",ItemType="Gun",Rarity="Godly"},
	["AlienBringer2"]={ItemName="Dark Alien Bringer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154539950",ItemType="Gun",Rarity="Godly"},
	["AlienGun"]={ItemName="Alien Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13156571119",ItemType="Gun",Rarity="Ancient"},
	["Aliengun"]={ItemName="Alien",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11521540391",ItemType="Gun",Rarity="Common"},
	["AlienPiercer"]={ItemName="Alien Piercer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154593575",ItemType="Gun",Rarity="Godly"},
	["AliensAxe"]={ItemName="Alien's Axe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154605522",ItemType="Knife",Rarity="Godly"},
	["AliensExperiment"]={ItemName="Alien's Experiment",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154566719",ItemType="Gun",Rarity="Godly"},
	["AliensMatter"]={ItemName="Alien's Matter",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154615957",ItemType="Knife",Rarity="Godly"},
	["AliensToxic"]={ItemName="Alien's Toxic",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154571999",ItemType="Knife",Rarity="Godly"},
	["AliensToxicity"]={ItemName="Alien's Toxicity",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154592084",ItemType="Knife",Rarity="Godly"},
	["AliensVoidBlade"]={ItemName="Alien's Void Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154547854",ItemType="Knife",Rarity="Godly"},
	["AliensWeapon"]={ItemName="Alien's Weapon",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154582113",ItemType="Knife",Rarity="Godly"},
	["AmericaGun"]={ItemName="America",Image="http://www.roblox.com/asset/?id=164676043",ItemType="Gun",Rarity="Classic"},
	["AmericanBatwing"]={ItemName="American Batwing",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13945904263",ItemType="Knife",Rarity="Ancient"},
	["AmericanEternal"]={ItemName="American Eternal",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13953499474",ItemType="Knife",Rarity="Godly"},
	["AmericanHarvester"]={ItemName="American Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13952861043",ItemType="Gun",Rarity="Godly"},
	["AmericaSword"]={ItemName="Old Glory",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=446047742",ItemType="Knife",Rarity="Godly"},
	["Amerilaser"]={ItemName="Amerilaser",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=446050753",ItemType="Gun",Rarity="Godly"},
	["AmethystLaser"]={ItemName="Amethyst",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11556050437",ItemType="Gun",Rarity="Godly"},
	["AncientBlade"]={ItemName="Ancient Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12708314524",ItemType="Knife",Rarity="Godly"},
	["AncientGun"]={ItemName="Ancient Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12708199498",ItemType="Gun",Rarity="Godly"},
	["Andro"]={ItemName="Icebeam",Image="http://www.roblox.com/asset/?id=8319648787",ItemType="Gun",Rarity="Godly"},
	["Apocalypse"]={ItemName="Apocalypse",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11421182576",ItemType="Gun",Rarity="Common"},
	["ApocalypseK"]={ItemName="Apocalypse",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11421427593",ItemType="Knife",Rarity="Common"},
	["Aqua"]={ItemName="Aqua",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315501208",ItemType="Knife",Rarity="Common"},
	["Aqua2aaa"]={ItemName="Aqua",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14301719723",ItemType="Knife",Rarity="Godly"},
	["AquaReaver"]={ItemName="Aqua Reaver",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14275114096",ItemType="Knife",Rarity="Godly"},
	["Art"]={ItemName="Art",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2866292486",ItemType="Knife",Rarity="Common"},
	["Asteroid"]={ItemName="Asteroid",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=476599365",ItemType="Gun",Rarity="Common"},
	["Astral"]={ItemName="Astral",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=1342262875",ItemType="Knife",Rarity="Godly"},
	["Astrala"]={ItemName="Astral Piercer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13138606417",ItemType="Gun",Rarity="Ancient"},
	["AstralG"]={ItemName="Astral",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11521404659",ItemType="Gun",Rarity="Rare"},
	["AstralK"]={ItemName="Astral Knife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=1342262875",ItemType="Knife",Rarity="Rare"},
	["AstroKnife"]={ItemName="Astro",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12699586850",ItemType="Knife",Rarity="Uncommon"},
	["AstrolaticKnife"]={ItemName="Astrolatic",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12699589581",ItemType="Knife",Rarity="Rare"},
	["Astronaunt"]={ItemName="Astronaunt",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=12877369813",ItemType="Knife",Rarity="Common"},
	["AstronauntKnife"]={ItemName="Astronaunt",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12699588721",ItemType="Knife",Rarity="Common"},
	["Atmospehere"]={ItemName="Atmosphere",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11521377012",ItemType="Knife",Rarity="Common"},
	["AuraEternal"]={ItemName="Aura Eternal",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14838259360",ItemType="Knife",Rarity="Ancient"},
	["AuraLuger"]={ItemName="Aura Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14838244550",ItemType="Gun",Rarity="Ancient"},
	["Aurora"]={ItemName="Aurora",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10684698021",ItemType="Knife",Rarity="Legendary"},
	["AuroraGun"]={ItemName="Aurora",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11064562609",ItemType="Gun",Rarity="Rare"},
	["AutumnDagger"]={ItemName="Autumn Dagger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11557827711",ItemType="Knife",Rarity="Godly"},
	["AutumnEdge"]={ItemName="Autumn's Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11557243385",ItemType="Knife",Rarity="Godly"},
	["AxeOfLight"]={ItemName="Axe Of Light",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2613911237",ItemType="Knife",Rarity="Ancient"},
	["Azure"]={ItemName="Azure Knife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12069870810",ItemType="Knife",Rarity="Ancient"},
	["Backrooms"]={ItemName="Backrooms",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11503939552",ItemType="Gun",Rarity="Common"},
	["Bacon"]={ItemName="Bacon",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238546467",ItemType="Gun",Rarity="Rare"},
	["Ban"]={ItemName="Ban Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7250913946",ItemType="Knife",Rarity="Ancient"},
	["BanHammer2"]={ItemName="Ban Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14276002749",ItemType="Knife",Rarity="Dream"},
	["Bat"]={ItemName="Darkwing",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11308388864",ItemType="Gun",Rarity="Godly"},
	["Bat22"]={ItemName="Bat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11360077723",ItemType="Knife",Rarity="Godly"},
	["Bats"]={ItemName="Bats",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873625",ItemType="Knife",Rarity="Rare"},
	["Bats2"]={ItemName="Bats",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10938010052",ItemType="Gun",Rarity="Common"},
	["BatsK"]={ItemName="Bat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11227117747",ItemType="Knife",Rarity="Common"},
	["BattleAxe"]={ItemName="Battleaxe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7356720801",ItemType="Knife",Rarity="Godly"},
	["BattleAxe 2"]={ItemName="BattleAxe II",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7108492649",ItemType="Knife",Rarity="Godly"},
	["BattleAxe2"]={ItemName="Battleaxe II",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7108492649",ItemType="Knife",Rarity="Godly"},
	["BattleAxe3"]={ItemName="Battleaxe III",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2807900686",ItemType="Knife",Rarity="Godly"},
	["Batwing"]={ItemName="Batwing",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=375690925",ItemType="Knife",Rarity="Ancient"},
	["BatwingGun"]={ItemName="Batwing Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13540522685",ItemType="Gun",Rarity="Ancient"},
	["Batwinghi"]={ItemName="Batwing",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=375690925",ItemType="Knife",Rarity="Ancient"},
	["BBElderGun"]={ItemName="Bronze Elderwood",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11205468509",ItemType="Gun",Rarity="Victim"},
	["BBioBlade"]={ItemName="BioBlade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6906074983",ItemType="Knife",Rarity="Godly"},
	["BBVampire"]={ItemName="Blue Vamp's Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11204996615",ItemType="Knife",Rarity="Victim"},
	["BClover"]={ItemName="Blue Clover",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12741318439",ItemType="Knife",Rarity="Common"},
	["beach"]={ItemName="Beach",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10034345532",ItemType="Knife",Rarity="Uncommon"},
	["BeachBall"]={ItemName="Beach Ball",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12956659162",ItemType="Knife",Rarity="Ancient"},
	["BeachballKnife"]={ItemName="Beachball",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13849708333",ItemType="Knife",Rarity="Rare"},
	["BeachBallSlasher"]={ItemName="BeachBall Slasher",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14166876090",ItemType="Knife",Rarity="Godly"},
	["BeachKnife"]={ItemName="Beach",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13849647779",ItemType="Knife",Rarity="Common"},
	["BeachKnife2"]={ItemName="Beach",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14166191922",ItemType="Knife",Rarity="Legendary"},
	["BeamLightHarvester"]={ItemName="BeamLight Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14419978164",ItemType="Gun",Rarity="Ancient"},
	["BeeKarambit"]={ItemName="Bee Karambit",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13003686038",ItemType="Knife",Rarity="Ancient"},
	["BeeRifle"]={ItemName="Bee Rifle",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13003701246",ItemType="Gun",Rarity="Ancient"},
	["BElderGun"]={ItemName="Blue Elderwood",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11205462971",ItemType="Gun",Rarity="Victim"},
	["BHallowKNI"]={ItemName="Bloodscythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7356519141",ItemType="Knife",Rarity="Godly"},
	["Bharv"]={ItemName="Blue Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8550613564",ItemType="Gun",Rarity="Victim"},
	["BHarv"]={ItemName="Bronze Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10475957654",ItemType="Gun",Rarity="Victim"},
	["BigKill"]={ItemName="Big Kill",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=162669041",ItemType="Gun",Rarity="Common"},
	["BIGOcean2"]={ItemName="BIG Ocean",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13957777452",ItemType="Gun",Rarity="Godly"},
	["BIGWaves2"]={ItemName="BIG Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13957713621",ItemType="Knife",Rarity="Godly"},
	["BillyBlade"]={ItemName="Billy Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14597685120",ItemType="Knife",Rarity="Victim"},
	["BioBlade"]={ItemName="Bioblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6730209208",ItemType="Knife",Rarity="Godly"},
	["BioGun"]={ItemName="Biogun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6696823358",ItemType="Gun",Rarity="Uncommon"},
	["BioH"]={ItemName="Bioheat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10512705107",ItemType="Knife",Rarity="Godly"},
	["Bit"]={ItemName="Bit",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238549030",ItemType="Gun",Rarity="Common"},
	["BKarambit"]={ItemName="Blue Karambit",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12530499399",ItemType="Knife",Rarity="Ancient"},
	["BKBioBlade"]={ItemName="BioBlade",Image="http://www.roblox.com/asset/?id=6905670919",ItemType="Knife",Rarity="Godly"},
	["BlackHoleScythe"]={ItemName="Black Hole Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154536565",ItemType="Knife",Rarity="Ancient"},
	["BlackKNI"]={ItemName="Black Knife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12957265317",ItemType="Knife",Rarity="Rare"},
	["BlackLugerF"]={ItemName="Black Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=420&height=420&assetId=7177442016",ItemType="Gun",Rarity="Godly"},
	["BlackSaber"]={ItemName="Black Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10940483914",ItemType="Knife",Rarity="Ancient"},
	["BlackSeer"]={ItemName="Black Seer",Image="http://www.roblox.com/asset/?id=9826479419",ItemType="Knife",Rarity="Ancient"},
	["BlastCore"]={ItemName="Blast Core",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12946023848",ItemType="Knife",Rarity="Ancient"},
	["BlastCoreLuger"]={ItemName="Blast Core Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12946962976",ItemType="Gun",Rarity="Ancient"},
	["Blaster"]={ItemName="Blaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=386277381",ItemType="Gun",Rarity="Godly"},
	["Bleached"]={ItemName="Bleached",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315500879",ItemType="Knife",Rarity="Common"},
	["BLeaf"]={ItemName="Black Leaf",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12881662024",ItemType="Knife",Rarity="Uncommon"},
	["Bleed"]={ItemName="Rupture",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315100702",ItemType="Gun",Rarity="Legendary"},
	["BleedingBlizzard"]={ItemName="Bleeding Blizzard",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433453427",ItemType="Knife",Rarity="Uncommon"},
	["Blizzard"]={ItemName="Blizzard",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433419569",ItemType="Knife",Rarity="Common"},
	["BlizzardShards"]={ItemName="Blizzard Shards",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13430721497",ItemType="Knife",Rarity="Godly"},
	["BloodHallow"]={ItemName="Bloody Hallowgun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7333263081",ItemType="Gun",Rarity="Godly"},
	["BloodKnife"]={ItemName="Blood",Image="http://www.roblox.com/asset/?id=144307188",ItemType="Knife",Rarity="Classic"},
	["BloodRadioactive"]={ItemName="Blood Radioactive",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13651490064",ItemType="Knife",Rarity="Rare"},
	["Bloodslash"]={ItemName="Blood Slash",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11387190208",ItemType="Knife",Rarity="Godly"},
	["BloodVAMp"]={ItemName="Blood Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6917339862",ItemType="Knife",Rarity="Godly"},
	["BloodWaves"]={ItemName="Blood Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13553033211",ItemType="Knife",Rarity="Common"},
	["Bloody"]={ItemName="Ghoul",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11227451338",ItemType="Knife",Rarity="Common"},
	["Bloodyedge"]={ItemName="Bloody Hallow's Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7774030663",ItemType="Knife",Rarity="Godly"},
	["BloodyHarv"]={ItemName="Bloody Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11377960873",ItemType="Gun",Rarity="Godly"},
	["Blossom"]={ItemName="Blossom",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=363150561",ItemType="Knife",Rarity="Ancient"},
	["BlossomG"]={ItemName="Blossoms",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12359251263",ItemType="Gun",Rarity="Common"},
	["BlossomK"]={ItemName="Blossom",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=363150561",ItemType="Knife",Rarity="Common"},
	["BlossomsG"]={ItemName="Blossom",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12363892685",ItemType="Gun",Rarity="Godly"},
	["BlueAlien"]={ItemName="Blue Alien",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13073974943",ItemType="Knife",Rarity="Godly"},
	["BlueBat"]={ItemName="Blue Bat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11497150282",ItemType="Knife",Rarity="Custom"},
	["BlueCandy"]={ItemName="Blue Candy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7456451831",ItemType="Knife",Rarity="Victim"},
	["BlueCandyNew"]={ItemName="Blue Candy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7456451831",ItemType="Knife",Rarity="Victim"},
	["BlueDream"]={ItemName="Blue Dream",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=",ItemType="Knife",Rarity="Ancient"},
	["BlueElderblade"]={ItemName="Blue Elderwood",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11529516285",ItemType="Knife",Rarity="Victim"},
	["BlueFadedRadioactive"]={ItemName="Blue Faded Radioactive",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13651483040",ItemType="Knife",Rarity="Uncommon"},
	["BlueFadeHammer"]={ItemName="Blue Fade Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433327496",ItemType="Knife",Rarity="Uncommon"},
	["BlueGun"]={ItemName="Blue Swirly",Image="http://www.roblox.com/asset/?id=10202255905",ItemType="Gun",Rarity="Victim"},
	["BlueHallowGun"]={ItemName="Blue Hallow Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13072149940",ItemType="Gun",Rarity="Godly"},
	["BlueHammer"]={ItemName="Blue Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433312866",ItemType="Knife",Rarity="Common"},
	["BlueHarvester"]={ItemName="Blue Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14835260057",ItemType="Gun",Rarity="Godly"},
	["BlueLaser"]={ItemName="Blue Laser",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11633575687",ItemType="Gun",Rarity="Godly"},
	["BlueLogChopper"]={ItemName="Blue Logchopper",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12670909883",ItemType="Knife",Rarity="Ancient"},
	["BlueLuger"]={ItemName="Blue Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9824393221",ItemType="Gun",Rarity="Godly"},
	["BlueMarble"]={ItemName="Blue Marble",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11189585625",ItemType="Knife",Rarity="Rare"},
	["BlueMinty"]={ItemName="Blue Minty",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12671128579",ItemType="Gun",Rarity="Victim"},
	["BlueOblivion"]={ItemName="Blue Oblivion",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14835256266",ItemType="Knife",Rarity="Godly"},
	["BlueRadioactive"]={ItemName="Blue Radioactive",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13651504895",ItemType="Knife",Rarity="Common"},
	["BlueSaber"]={ItemName="Blue Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10940513269",ItemType="Knife",Rarity="Ancient"},
	["BlueScratch"]={ItemName="Scratch",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10702885376",ItemType="Knife",Rarity="Legendary"},
	["BlueSeer"]={ItemName="Blue Seer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6934305463",ItemType="Knife",Rarity="Godly"},
	["BlueStarryBringer"]={ItemName="Blue Starry Bringer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12882019444",ItemType="Gun",Rarity="Godly"},
	["Bluesteel"]={ItemName="Bluesteel",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=159947939",ItemType="Knife",Rarity="Uncommon"},
	["BluesteelGun"]={ItemName="Bluesteel",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=162668203",ItemType="Gun",Rarity="Uncommon"},
	["BlueSugar"]={ItemName="Blue Sugar",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7371056276",ItemType="Gun",Rarity="Victim"},
	["BlueSummerBlade"]={ItemName="Blue Summer Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14710422518",ItemType="Knife",Rarity="Victim"},
	["BlueSwirlyAxe"]={ItemName="Blue Swirly",Image="http://www.roblox.com/asset/?id=10202025730",ItemType="Knife",Rarity="Victim"},
	["BlueTech"]={ItemName="Blue Tech",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433184821",ItemType="Knife",Rarity="Common"},
	["BlueUfo"]={ItemName="Blue UFO",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13074814890",ItemType="Knife",Rarity="Rare"},
	["BlueVampireEdge"]={ItemName="Blue Vampire's Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13072082450",ItemType="Knife",Rarity="Godly"},
	["BlueWaves"]={ItemName="Blue Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13552781372",ItemType="Knife",Rarity="Common"},
	["BMIcebreaker"]={ItemName="Blood Moon Icebreaker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14264365257",ItemType="Knife",Rarity="Ancient"},
	["BMIcepiercer"]={ItemName="Blood Moon Icepiercer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14264389490",ItemType="Gun",Rarity="Ancient"},
	["BogChopper"]={ItemName="Bog's Chopper",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12660996662",ItemType="Knife",Rarity="Ancient"},
	["BogElderwood"]={ItemName="Bog's Elderwood",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12661026480",ItemType="Gun",Rarity="Ancient"},
	["BombasticBatwing"]={ItemName="Lava Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10560570293",ItemType="Knife",Rarity="Godly"},
	["BombPop"]={ItemName="Bomb Pop",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13850681973",ItemType="Knife",Rarity="Victim"},
	["BoneBlade"]={ItemName="Boneblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7587860356",ItemType="Knife",Rarity="Godly"},
	["Bones"]={ItemName="Bones",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873816",ItemType="Knife",Rarity="Common"},
	["Bones2020"]={ItemName="Bones",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5872492951",ItemType="Knife",Rarity="Rare"},
	["BonesG19"]={ItemName="Bones",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7192738528",ItemType="Gun",Rarity="Uncommon"},
	["boneskni"]={ItemName="Bones",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5872492951",ItemType="Knife",Rarity="Rare"},
	["BoomerangKNI"]={ItemName="Boomerang",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12956729903",ItemType="Knife",Rarity="Ancient"},
	["Borders"]={ItemName="Borders",Image="http://www.roblox.com/asset/?id=198453499",ItemType="Knife",Rarity="Common"},
	["BPixel"]={ItemName="Black Pixel",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12881688023",ItemType="Knife",Rarity="Rare"},
	["BR"]={ItemName="Br..",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9094244345",ItemType="Gun",Rarity="Common"},
	["Brains"]={ItemName="Brains",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873956",ItemType="Knife",Rarity="Common"},
	["Brains19"]={ItemName="Brains",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7192738827",ItemType="Knife",Rarity="Uncommon"},
	["Brains22"]={ItemName="Brains",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11359790483",ItemType="Gun",Rarity="Uncommon"},
	["BrightGreen"]={ItemName="Bright Green",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12957245635",ItemType="Knife",Rarity="Rare"},
	["Brightness"]={ItemName="Brightness",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2889470086",ItemType="Knife",Rarity="Rare"},
	["Bronze"]={ItemName="Bronze",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8597250519",ItemType="Knife",Rarity="Uncommon"},
	["BronzeCandy"]={ItemName="Bronze Candy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7231969153",ItemType="Knife",Rarity="Victim"},
	["BronzeEdge"]={ItemName="Bronze Hallow",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9561289070",ItemType="Knife",Rarity="Victim"},
	["BronzeElderblade"]={ItemName="Bronze Elderwood",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11529514526",ItemType="Knife",Rarity="Victim"},
	["BronzeGun"]={ItemName="Bronze Swirly",Image="http://www.roblox.com/asset/?id=9029813442",ItemType="Gun",Rarity="Victim"},
	["BronzeIceCrusher"]={ItemName="Icecrusher",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14686900942",ItemType="Knife",Rarity="Victim"},
	["BronzeIcePiercer"]={ItemName="Icepiercer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14686921623",ItemType="Gun",Rarity="Victim"},
	["BronzeLogchopper"]={ItemName="Bronze Logchopper",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12670844483",ItemType="Knife",Rarity="Ancient"},
	["BronzeMinty"]={ItemName="Bronze Minty",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12671068835",ItemType="Gun",Rarity="Victim"},
	["BronzeSummerBlade"]={ItemName="Bronze Summer Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14710430439",ItemType="Knife",Rarity="Victim"},
	["BronzeSummerSwirl"]={ItemName="Bronze Summer Swirl",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14685952633",ItemType="Knife",Rarity="Godly"},
	["BronzeSwirlyAxe"]={ItemName="Bronze Swirly",Image="http://www.roblox.com/asset/?id=9029811206",ItemType="Knife",Rarity="Victim"},
	["BronzeWaves"]={ItemName="Bronze Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13553756599",ItemType="Knife",Rarity="Rare"},
	["BrownSeer"]={ItemName="Brown Seer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11557631496",ItemType="Knife",Rarity="Godly"},
	["BrownWaves"]={ItemName="Brown Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13553057090",ItemType="Knife",Rarity="Uncommon"},
	["BRR"]={ItemName="Brr...",Image="http://www.roblox.com/asset/?id=9103786828",ItemType="Knife",Rarity="Godly"},
	["Brush"]={ItemName="Brush",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365568602",ItemType="Knife",Rarity="Uncommon"},
	["BSand"]={ItemName="Black Sand",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12881651608",ItemType="Knife",Rarity="Uncommon"},
	["Bubbleknife"]={ItemName="Bubble",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14166423019",ItemType="Knife",Rarity="Godly"},
	["Bubbles2"]={ItemName="Bubbles 2.0",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14312421008",ItemType="Knife",Rarity="Godly"},
	["Bunny"]={ItemName="Bunny",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=387874365",ItemType="Knife",Rarity="Common"},
	["BunnyBlade"]={ItemName="Easter Basket",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13050773828",ItemType="Knife",Rarity="Ancient"},
	["BunnyBlaster"]={ItemName="Bunny Blaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13035750527",ItemType="Gun",Rarity="Ancient"},
	["BunnysBlade"]={ItemName="Bunny Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13025384313",ItemType="Knife",Rarity="Godly"},
	["BunnysGun"]={ItemName="Bunny Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13025382998",ItemType="Gun",Rarity="Godly"},
	["BunnysSlingshot"]={ItemName="Bunny's Slingshot",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13036545457",ItemType="Gun",Rarity="Ancient"},
	["BunnysSword"]={ItemName="Bunny's Sword",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13036546963",ItemType="Knife",Rarity="Ancient"},
	["BVampire"]={ItemName="Bronze Vamp's Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11204997676",ItemType="Knife",Rarity="Victim"},
	["BWaves"]={ItemName="Black Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12881625541",ItemType="Knife",Rarity="Uncommon"},
	["BWavesK"]={ItemName="Bronze Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13973923102",ItemType="Knife",Rarity="Godly"},
	["BZebra"]={ItemName="Black Zebra",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12881677868",ItemType="Knife",Rarity="Rare"},
	["CAD"]={ItemName="Spring Showers",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9336161605",ItemType="Knife",Rarity="Rare"},
	["Camo"]={ItemName="Camo",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=160024789",ItemType="Gun",Rarity="Uncommon"},
	["CamoKNI"]={ItemName="Camo",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6696851556",ItemType="Knife",Rarity="Uncommon"},
	["Candle"]={ItemName="Candle",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5872491708",ItemType="Knife",Rarity="Common"},
	["CandleF"]={ItemName="Candleflame",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=7805833970",ItemType="Knife",Rarity="Godly"},
	["Candleflame"]={ItemName="Candleflame",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7904766997",ItemType="Knife",Rarity="Godly"},
	["CandleK"]={ItemName="Candle",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5872491708",ItemType="Knife",Rarity="Common"},
	["Candy"]={ItemName="Candy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332021011",ItemType="Knife",Rarity="Godly"},
	["candycorn"]={ItemName="Candycorn",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5866454590",ItemType="Gun",Rarity="Common"},
	["CandyCorn19"]={ItemName="Candycorn",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7534491723",ItemType="Knife",Rarity="Common"},
	["Candycorn22"]={ItemName="Candy Corn",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11361624969",ItemType="Knife",Rarity="Common"},
	["Candycorngun"]={ItemName="Candy Corn",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11421171576",ItemType="Gun",Rarity="Common"},
	["CandyCornGun"]={ItemName="Candy Corn",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5866454590",ItemType="Gun",Rarity="Common"},
	["CandyKNI"]={ItemName="Candycorn",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10702863757",ItemType="Knife",Rarity="Common"},
	["CandySwirl"]={ItemName="Candy Swirl",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11064568760",ItemType="Knife",Rarity="Rare"},
	["Cane"]={ItemName="Cane",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=331140746",ItemType="Knife",Rarity="Rare"},
	["Cane2"]={ItemName="Cane",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10684688120",ItemType="Knife",Rarity="Common"},
	["CaneGun"]={ItemName="Cane",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332497187",ItemType="Gun",Rarity="Rare"},
	["CaneGun2"]={ItemName="Cane",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2669785546",ItemType="Gun",Rarity="Rare"},
	["Cardboard"]={ItemName="Cardboard",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235366729",ItemType="Knife",Rarity="Common"},
	["Carrot"]={ItemName="Carrot",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=387874071",ItemType="Knife",Rarity="Common"},
	["CarrotBlade"]={ItemName="Carrot Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13050805620",ItemType="Knife",Rarity="Ancient"},
	["carved"]={ItemName="Carved",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5866436906",ItemType="Knife",Rarity="Common"},
	["CarvedKnife"]={ItemName="Carved",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5866436906",ItemType="Knife",Rarity="Common"},
	["Cat"]={ItemName="Cat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10469641876",ItemType="Gun",Rarity="Common"},
	["CatGun"]={ItemName="Cat Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12957208790",ItemType="Gun",Rarity="Uncommon"},
	["CatKnife"]={ItemName="Cat Knife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12957158243",ItemType="Knife",Rarity="Common"},
	["Caution"]={ItemName="Caution",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238546422",ItemType="Gun",Rarity="Uncommon"},
	["Cavern"]={ItemName="Cavern",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11064575017",ItemType="Gun",Rarity="Legendary"},
	["Cbat"]={ItemName="Chroma Batwing",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10981802745",ItemType="Knife",Rarity="Ancient",Chroma=true},
	["CBEAM"]={ItemName="Chroma Plasmabeam",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11062898644",ItemType="Gun",Rarity="Godly",Chroma=true},
	["CBlaster"]={ItemName="Chroma Blaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11003243923",ItemType="Gun",Rarity="Godly",Chroma=true},
	["CBlossom"]={ItemName="Chroma Blossom",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12684485052",ItemType="Gun",Rarity="Godly"},
	["CBone"]={ItemName="Chroma Boneblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=2513597845",ItemType="Knife",Rarity="Godly",Chroma=true},
	["CCandy"]={ItemName="Chroma Candy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11062965805",ItemType="Knife",Rarity="Godly",Chroma=true},
	["CChill"]={ItemName="Chroma Chill",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11134441993",ItemType="Knife",Rarity="Godly",Chroma=true},
	["CChromatic"]={ItemName="Chromatic",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10264829646",ItemType="Knife",Rarity="Godly",Chroma=true},
	["CClockwork"]={ItemName="Chroma Clockwork",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11064509652",ItemType="Knife",Rarity="Godly",Chroma=true},
	["cCookiecane"]={ItemName="Cookiecane",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=11873630718",ItemType="Knife",Rarity="Godly"},
	["CDCres"]={ItemName="Darklord",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11133844866",ItemType="Knife",Rarity="Godly"},
	["CDeath"]={ItemName="Chroma Deathshard",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=3187397317",ItemType="Knife",Rarity="Godly",Chroma=true},
	["CDominus"]={ItemName="Chroma Dominus",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13129579258",ItemType="Knife",Rarity="Ancient"},
	["CElderFeat"]={ItemName="Chroma Elderwood Set",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11612015895",ItemType="Knife",Rarity="Ancient",Chroma=true},
	["CElderGun"]={ItemName="Chroma Elderwood Revolver",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11534147919",ItemType="Gun",Rarity="Godly",Chroma=true},
	["CElderKNI"]={ItemName="Chroma Elderwood Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11534152460",ItemType="Knife",Rarity="Ancient",Chroma=true},
	["Celestial"]={ItemName="Celestial",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10761310844",ItemType="Knife",Rarity="Common"},
	["CelestialEmberedge"]={ItemName="Celestial Emberedge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14269390309",ItemType="Knife",Rarity="Ancient"},
	["CFang"]={ItemName="Chroma Fang",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=6691406510",ItemType="Knife",Rarity="Godly",Chroma=true},
	["CGem"]={ItemName="Chroma Gemstone",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=3183657875",ItemType="Knife",Rarity="Godly",Chroma=true},
	["CGinger"]={ItemName="Chroma Gingerblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=2672351679",ItemType="Knife",Rarity="Godly",Chroma=true},
	["CHallow"]={ItemName="Chroma Hallow's Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11116337149",ItemType="Knife",Rarity="Godly",Chroma=true},
	["challowgun"]={ItemName="Chroma Hallowgun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6889438105",ItemType="Gun",Rarity="Godly",Chroma=true},
	["CHallowKNI"]={ItemName="Chroma Hallowscythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11256630157",ItemType="Knife",Rarity="Ancient",Chroma=true},
	["CHandsaw"]={ItemName="Rainbow Handsaw",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2579951570",ItemType="Knife",Rarity="Godly"},
	["CHarv"]={ItemName="Chroma Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11064976187",ItemType="Gun",Rarity="Ancient",Chroma=true},
	["CHeat"]={ItemName="Chroma Heat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=3187444849",ItemType="Knife",Rarity="Godly",Chroma=true},
	["Checker"]={ItemName="Checker",Image="http://www.roblox.com/asset/?id=198461230",ItemType="Knife",Rarity="Uncommon"},
	["Cheddar"]={ItemName="Cheddar",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=203808317",ItemType="Gun",Rarity="Uncommon"},
	["Cheesy"]={ItemName="Cheesy",Image="http://www.roblox.com/asset/?id=198455898",ItemType="Knife",Rarity="Uncommon"},
	["Cherry"]={ItemName="Cherry",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235366575",ItemType="Knife",Rarity="Common"},
	["Chill"]={ItemName="Chill",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332022166",ItemType="Knife",Rarity="Godly"},
	["Chips"]={ItemName="Blue",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473626317",ItemType="Knife",Rarity="Uncommon"},
	["Choco"]={ItemName="Choco",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=387874991",ItemType="Knife",Rarity="Common"},
	["ChocolateGun"]={ItemName="Chocolate Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13012196015",ItemType="Gun",Rarity="Uncommon"},
	["ChocolateKnife"]={ItemName="Chocolate",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13006978551",ItemType="Knife",Rarity="Uncommon"},
	["Chroma Candleflame"]={ItemName="Chroma Candleflame",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7864020145",ItemType="Knife",Rarity="Godly",Chroma=true},
	["Chroma Seer"]={ItemName="Chroma Seer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6566760171",ItemType="Knife",Rarity="Godly",Chroma=true},
	["ChromaAmerilaser2"]={ItemName="Chroma Amerilaser",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=446050753",ItemType="Gun",Rarity="Godly",Chroma=true},
	["ChromaBolt"]={ItemName="Chroma Bolt",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5049413434",ItemType="Knife",Rarity="Godly"},
	["ChromaBoxingGlove"]={ItemName="Chroma Boxing Glove",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13129184549",ItemType="Knife",Rarity="Ancient"},
	["ChromaCandle"]={ItemName="Chroma Candleflame",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7864020145",ItemType="Knife",Rarity="Godly",Chroma=true},
	["ChromaCelestial"]={ItemName="Chroma Celestial",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14339569072",ItemType="Knife",Rarity="Dream"},
	["ChromaClownHammer"]={ItemName="Chroma Clown Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12957739044",ItemType="Knife",Rarity="Victim"},
	["ChromaCorrupt"]={ItemName="Chroma Corrupt",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13850886686",ItemType="Knife",Rarity="Victim",Chroma=true},
	["ChromaDark"]={ItemName="Chroma Darkbringer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=4751507011",ItemType="Gun",Rarity="Godly",Chroma=true},
	["ChromaElderBlade"]={ItemName="Chroma Elderwood Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11299939017",ItemType="Knife",Rarity="Godly",Chroma=true},
	["ChromaET"]={ItemName="Chroma Eternal",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7440228176",ItemType="Knife",Rarity="Godly"},
	["ChromaEX0"]={ItemName="Chroma EX0",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=5129657642",ItemType="Knife",Rarity="Godly"},
	["ChromaFang"]={ItemName="Chroma Fang",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=3187397850",ItemType="Knife",Rarity="Godly",Chroma=true},
	["CHromaGun"]={ItemName="Chroma Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11489051520",ItemType="Gun",Rarity="Rare",Chroma=true},
	["ChromaHarvester"]={ItemName="BeamLight Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14419978164",ItemType="Gun",Rarity="Ancient"},
	["Chromaknife"]={ItemName="Chroma Knife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11489053258",ItemType="Knife",Rarity="Rare",Chroma=true},
	["ChromaLight"]={ItemName="Chroma Lightbringer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=4751507078",ItemType="Gun",Rarity="Godly",Chroma=true},
	["ChromaOcean2"]={ItemName="Chroma Ocean",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13957777452",ItemType="Gun",Rarity="Godly",Chroma=true},
	["ChromaOldGlory2"]={ItemName="Chroma Old Glory",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=446047742",ItemType="Knife",Rarity="Godly",Chroma=true},
	["ChromaPhantom"]={ItemName="Chroma Phantom",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11416087653",ItemType="Knife",Rarity="Godly",Chroma=true},
	["ChromaPopit"]={ItemName="Chorma Popit",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13129181126",ItemType="Knife",Rarity="Ancient"},
	["ChromaShark"]={ItemName="Chroma Shark",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=3187421856",ItemType="Gun",Rarity="Godly",Chroma=true},
	["ChromaSlash"]={ItemName="Chroma Slasher",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6691400343",ItemType="Knife",Rarity="Godly",Chroma=true},
	["ChromaSpectre"]={ItemName="Chroma Spectre",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11416086161",ItemType="Gun",Rarity="Godly",Chroma=true},
	["ChromaSwirl"]={ItemName="Chroma Swirly Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8803116773",ItemType="Gun",Rarity="Godly",Chroma=true},
	["ChromaTech"]={ItemName="Chroma Tech",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=6717465233",ItemType="Knife",Rarity="Legendary"},
	["ChromaUfo"]={ItemName="Chroma UFO",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13074536007",ItemType="Knife",Rarity="Legendary"},
	["ChromaWaves"]={ItemName="Chroma Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13553841204",ItemType="Knife",Rarity="Rare"},
	["ChromaWaves2"]={ItemName="Chroma Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13957713621",ItemType="Knife",Rarity="Godly",Chroma=true},
	["ChromawoodBlade"]={ItemName="Chromawood Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12696808960",ItemType="Knife",Rarity="Godly"},
	["ChromawoodRevolver"]={ItemName="Chromawood Revolver",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12696943623",ItemType="Gun",Rarity="Godly"},
	["ChromawoodScythe"]={ItemName="Chromawood Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12696725108",ItemType="Knife",Rarity="Ancient"},
	["CIceblaster"]={ItemName="Chroma Iceblaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6692715534",ItemType="Gun",Rarity="Victim",Chroma=true},
	["CIcebreaker"]={ItemName="Chroma Icebreaker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6692716412",ItemType="Knife",Rarity="Victim",Chroma=true},
	["Circuit"]={ItemName="Circuit",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235366945",ItemType="Knife",Rarity="Uncommon"},
	["CIS"]={ItemName="Crates In Space",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11512575645",ItemType="Knife",Rarity="Legendary"},
	["Clan"]={ItemName="Clan",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235366460",ItemType="Knife",Rarity="Common"},
	["Claser"]={ItemName="Chroma Laser",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=3187422628",ItemType="Gun",Rarity="Godly",Chroma=true},
	["ClassicG"]={ItemName="Classic Gun",Image="http://www.roblox.com/asset/?id=10706634555",ItemType="Gun",Rarity="Classic"},
	["ClassicK"]={ItemName="Classic Knife",Image="http://www.roblox.com/asset/?id=10706632385",ItemType="Knife",Rarity="Classic"},
	["Clay"]={ItemName="Clay",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8597257334",ItemType="Knife",Rarity="Common"},
	["Clockwork"]={ItemName="Clockwork",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=360609441",ItemType="Knife",Rarity="Godly"},
	["cloudgun"]={ItemName="Clouds",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10034377312",ItemType="Gun",Rarity="Common"},
	["clouds"]={ItemName="Clouds",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10034306705",ItemType="Knife",Rarity="Common"},
	["CloverCandleflame"]={ItemName="Clover Candleflame",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12741516820",ItemType="Knife",Rarity="Godly"},
	["CloverLuger"]={ItemName="Clover Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12741529675",ItemType="Gun",Rarity="Godly"},
	["Clown"]={ItemName="Clown",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315501118",ItemType="Knife",Rarity="Common"},
	["clown2"]={ItemName="Bozo",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10394180658",ItemType="Gun",Rarity="Uncommon"},
	["clown22"]={ItemName="Bozo",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10865418937",ItemType="Knife",Rarity="Uncommon"},
	["ClownGun"]={ItemName="Clown",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6952182082",ItemType="Gun",Rarity="Common"},
	["ClownHammer"]={ItemName="Clown Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12957737966",ItemType="Knife",Rarity="Victim"},
	["Cluger"]={ItemName="Chroma Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=3187399258",ItemType="Gun",Rarity="Godly",Chroma=true},
	["CNikScythe"]={ItemName="Chroma Nik's Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12270018846",ItemType="Knife",Rarity="Ancient",Chroma=true},
	["Coal"]={ItemName="Coal",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10684686903",ItemType="Gun",Rarity="Common"},
	["Coal2"]={ItemName="Coal",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6676484080",ItemType="Knife",Rarity="Common"},
	["Coaly"]={ItemName="Coal",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2669784920",ItemType="Gun",Rarity="Common"},
	["Cola"]={ItemName="Soda",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238546400",ItemType="Gun",Rarity="Uncommon"},
	["ColaCan"]={ItemName="Bloxy Cola",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12956537078",ItemType="Knife",Rarity="Ancient"},
	["Cold"]={ItemName="Cold",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=161309889",ItemType="Gun",Rarity="Common"},
	["Combaty"]={ItemName="Combat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6936810108",ItemType="Knife",Rarity="Common"},
	["Cookie"]={ItemName="Cookie",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10684693700",ItemType="Gun",Rarity="Uncommon"},
	["Cookie2"]={ItemName="Glitch 5",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10761415410",ItemType="Knife",Rarity="Common"},
	["Cookieblade"]={ItemName="Cookieblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10920502562",ItemType="Knife",Rarity="Godly"},
	["Copping"]={ItemName="Copper",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6696850282",ItemType="Knife",Rarity="Common"},
	["Corl"]={ItemName="Corl",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=546161858",ItemType="Knife",Rarity="Common"},
	["Cosmic"]={ItemName="Cosmic",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=12877365075",ItemType="Knife",Rarity="Common"},
	["CosmicEternal"]={ItemName="Cosmic Eternal",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11531600491",ItemType="Knife",Rarity="Godly"},
	["CosmicHarvester"]={ItemName="Crateblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11523626881",ItemType="Knife",Rarity="Godly"},
	["CottonCandy"]={ItemName="Cotton Candy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=435933179",ItemType="Knife",Rarity="Legendary"},
	["CousinTentacles"]={ItemName="Cousin Tentacles",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12700102966",ItemType="Knife",Rarity="Ancient"},
	["CPixel"]={ItemName="Chroma Pixel",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11134445116",ItemType="Knife",Rarity="Godly",Chroma=true},
	["CPlasma"]={ItemName="Chroma Plasmablade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10358644308",ItemType="Knife",Rarity="Godly",Chroma=true},
	["CPlasmabeam"]={ItemName="Chroma CPlasmabeam",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11062898644",ItemType="Gun",Rarity="Godly",Chroma=true},
	["CPlasmablade"]={ItemName="Chroma Plasmablade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10488677541",ItemType="Knife",Rarity="Godly",Chroma=true},
	["CPum"]={ItemName="Chroma Pumpking",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11541547606",ItemType="Knife",Rarity="Godly",Chroma=true},
	["CrackedKnife"]={ItemName="Cracked Egg",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13002297456",ItemType="Knife",Rarity="Rare"},
	["Cracks"]={ItemName="Cracks",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10469643036",ItemType="Knife",Rarity="Common"},
	["cracks"]={ItemName="Cracks",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11230719202",ItemType="Gun",Rarity="Common"},
	["CrateMaster"]={ItemName="Glitch 2",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8578155859",ItemType="Gun",Rarity="Common"},
	["CrateMaster3"]={ItemName="Crateharvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10298067121",ItemType="Gun",Rarity="Godly"},
	["CreatorHammer"]={ItemName="Creator's Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=422672447",ItemType="Knife",Rarity="Victim"},
	["Cres"]={ItemName="Crescendo",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=1201481809",ItemType="Knife",Rarity="Ancient"},
	["CrimsonHammer"]={ItemName="Crimson Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433840470",ItemType="Knife",Rarity="Rare"},
	["CrimsonScythe"]={ItemName="Bloody Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11274914673",ItemType="Knife",Rarity="Godly"},
	["CRY"]={ItemName="Spring Showers",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9336180707",ItemType="Gun",Rarity="Rare"},
	["Crystal"]={ItemName="Crystalblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10661009964",ItemType="Knife",Rarity="Godly"},
	["CrystalHeat"]={ItemName="Frozen Heat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11565647436",ItemType="Knife",Rarity="Godly"},
	["CrystalHeat2"]={ItemName="Crystal Heat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=4908566389",ItemType="Knife",Rarity="Godly"},
	["CSakura"]={ItemName="Chroma Sakura",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12684474229",ItemType="Knife",Rarity="Godly"},
	["CSaw"]={ItemName="Chroma Saw",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=3187398132",ItemType="Knife",Rarity="Godly",Chroma=true},
	["CSeer"]={ItemName="Chroma Seer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=3184140321",ItemType="Knife",Rarity="Godly",Chroma=true},
	["CSharkseeker"]={ItemName="Chroma Sharkseeker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=12835482439",ItemType="Gun",Rarity="Victim"},
	["CSpaceWalk"]={ItemName="Chroma Spacewalker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10697292136",ItemType="Knife",Rarity="Godly",Chroma=true},
	["Csugar"]={ItemName="Chroma Sugar",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11651979785",ItemType="Gun",Rarity="Godly",Chroma=true},
	["CSwirl"]={ItemName="Swirly Axe",Image="http://www.roblox.com/asset/?id=10202139383",ItemType="Knife",Rarity="Ancient"},
	["CTides"]={ItemName="Chroma Tides",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=3187398906",ItemType="Knife",Rarity="Godly",Chroma=true},
	["CTrident2"]={ItemName="Chroma Trident",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14166380128",ItemType="Knife",Rarity="Godly",Chroma=true},
	["Curse"]={ItemName="Curse",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11361655474",ItemType="Knife",Rarity="Rare"},
	["CVirtual"]={ItemName="Chroma Virtual",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10151494980",ItemType="Knife",Rarity="Godly",Chroma=true},
	["CyanHammer"]={ItemName="Cyan Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433303658",ItemType="Knife",Rarity="Common"},
	["CyanOverlord"]={ItemName="Cyan Overlord",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14838212546",ItemType="Knife",Rarity="Ancient"},
	["CyanSharkseeker"]={ItemName="Cyan Sharkseeker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13072199815",ItemType="Gun",Rarity="Godly"},
	["CyanTech"]={ItemName="Cyan Tech",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433219592",ItemType="Knife",Rarity="Uncommon"},
	["CyanVampireEdge"]={ItemName="Vampire's Oblivion",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14728391347",ItemType="Knife",Rarity="Ancient"},
	["DaisyG"]={ItemName="Daisy Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12684533852",ItemType="Gun",Rarity="Common"},
	["DaisyK"]={ItemName="Daisy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12684519031",ItemType="Knife",Rarity="Common"},
	["DaKnife"]={ItemName="Dababy Knife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetid=12798443166",ItemType="Knife",Rarity="Legendary"},
	["Damp"]={ItemName="Damp",Image="http://www.roblox.com/asset/?id=198461253",ItemType="Knife",Rarity="Rare"},
	["DarkBlade2"]={ItemName="Dark Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2430037369",ItemType="Knife",Rarity="Godly"},
	["DarkBrod"]={ItemName="Darkbringer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=4751387674",ItemType="Gun",Rarity="Godly"},
	["DarkDeath"]={ItemName="Dark Death",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12881780378",ItemType="Gun",Rarity="Godly"},
	["DarkDeathHammer"]={ItemName="Dark Death Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12881798507",ItemType="Knife",Rarity="Godly"},
	["DarkGreenWaves"]={ItemName="Dark Green Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13558351366",ItemType="Knife",Rarity="Legendary"},
	["DarkIcebreaker"]={ItemName="Dark Icebreaker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12881928428",ItemType="Knife",Rarity="Godly"},
	["DarkKarambit"]={ItemName="Dark Karambit",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12881997762",ItemType="Knife",Rarity="Godly"},
	["DarkMatterBlade"]={ItemName="Dark Matter Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154576193",ItemType="Knife",Rarity="Godly"},
	["DarkMatterBringer"]={ItemName="Dark Matter Bringer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154544553",ItemType="Gun",Rarity="Godly"},
	["DarkMatterShark"]={ItemName="Dark Matter Shark",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154584026",ItemType="Gun",Rarity="Godly"},
	["Darkness"]={ItemName="Darkness",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11359817141",ItemType="Gun",Rarity="Common"},
	["DarknessBlade"]={ItemName="Darkness Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14731577211",ItemType="Knife",Rarity="Dream"},
	["DarknessK"]={ItemName="Darkness",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11421362677",ItemType="Knife",Rarity="Common"},
	["DarkPlasmabeam"]={ItemName="Dark Plasmabeam",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12882052029",ItemType="Gun",Rarity="Godly"},
	["DarkPlasmablade"]={ItemName="Dark Plasmablade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12882037071",ItemType="Knife",Rarity="Godly"},
	["DarkPrism"]={ItemName="Dark Prism",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12881942854",ItemType="Knife",Rarity="Godly"},
	["DarkSwirly"]={ItemName="Dark Swirly",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12881732154",ItemType="Knife",Rarity="Legendary"},
	["DarkWing"]={ItemName="Dark Wing",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2430037132",ItemType="Gun",Rarity="Godly"},
	["DB"]={ItemName="Diamond Darkbringer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10960525869",ItemType="Gun",Rarity="Godly"},
	["Deathshard"]={ItemName="Deathshard",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=3175017717",ItemType="Knife",Rarity="Godly"},
	["Deathspeaker"]={ItemName="Void Heat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10190284022",ItemType="Knife",Rarity="Common"},
	["DeepSea"]={ItemName="Deep Sea",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=4659634072",ItemType="Knife",Rarity="Rare"},
	["DefaultGun"]={ItemName="Default Gun",Image="http://www.roblox.com/asset/?id=8478112339",ItemType="Gun",Rarity="Common"},
	["DefaultKnife"]={ItemName="Default Knife",Image="http://www.roblox.com/asset/?id=584555920",ItemType="Knife",Rarity="Common"},
	["DemonHammer"]={ItemName="Demon Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13344861613",ItemType="Knife",Rarity="Godly"},
	["demonic"]={ItemName="Hell",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10770119228",ItemType="Knife",Rarity="Godly"},
	["DemonicDoom"]={ItemName="Demonic Doom",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13777614682",ItemType="Knife",Rarity="Ancient"},
	["DemonTech"]={ItemName="Demon Tech",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14299690114",ItemType="Gun",Rarity="Godly"},
	["Denis"]={ItemName="Denis",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=546161062",ItemType="Knife",Rarity="Common"},
	["DevSword"]={ItemName="Dev Sword",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14312343757",ItemType="Knife",Rarity="Dream"},
	["Dew"]={ItemName="Black",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473626646",ItemType="Knife",Rarity="Rare"},
	["DewMo"]={ItemName="Mountain Dew",Image="http://www.roblox.com/asset/?id=7030500492",ItemType="Knife",Rarity="Uncommon"},
	["Dimensions"]={ItemName="Uranus",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10034608552",ItemType="Knife",Rarity="Common"},
	["DiscoLuger"]={ItemName="Disco's Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9143122031",ItemType="Gun",Rarity="Custom"},
	["DiscoTide"]={ItemName="Disco's Tides",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9142907759",ItemType="Knife",Rarity="Custom"},
	["Disint"]={ItemName="Laser",Image="http://www.roblox.com/asset/?id=54798135",ItemType="Gun",Rarity="Classic"},
	["DL"]={ItemName="Diamond Lightbringer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10960524397",ItemType="Gun",Rarity="Godly"},
	["DNAKni"]={ItemName="DNA",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12881545614",ItemType="Knife",Rarity="Common"},
	["Doge"]={ItemName="Doge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235371276",ItemType="Knife",Rarity="Uncommon"},
	["DogeEdge"]={ItemName="Doge Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12957303704",ItemType="Knife",Rarity="Godly"},
	["DogeHarvester"]={ItemName="Doge Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12957313803",ItemType="Gun",Rarity="Godly"},
	["DogKnife"]={ItemName="Dog Knife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12957180549",ItemType="Knife",Rarity="Common"},
	["Donut"]={ItemName="Donut",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235366815",ItemType="Knife",Rarity="Uncommon"},
	["Dorito"]={ItemName="Doritos",Image="http://www.roblox.com/asset/?id=7030500492",ItemType="Knife",Rarity="Common"},
	["Doritos"]={ItemName="Purple",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473626740",ItemType="Knife",Rarity="Rare"},
	["DPLuger"]={ItemName="Dark Pink Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12488710947",ItemType="Gun",Rarity="Godly"},
	["DragonBlaster"]={ItemName="Dragon Blaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14338539848",ItemType="Gun",Rarity="Godly"},
	["Dreadgun"]={ItemName="Darkswirl",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11410045855",ItemType="Gun",Rarity="Godly"},
	["DuckKNI"]={ItemName="Rubber Duck",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=40925251",ItemType="Knife",Rarity="Ancient"},
	["DuckyPrismatic"]={ItemName="Ducky Prismatic",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12959051243",ItemType="Knife",Rarity="Ancient"},
	["Duckysblade"]={ItemName="Ducky's Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12958516557",ItemType="Knife",Rarity="Ancient"},
	["Dungeon19"]={ItemName="Dungeon",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7192745333",ItemType="Knife",Rarity="Rare"},
	["EagleSword"]={ItemName="Eagle Sword",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13944517280",ItemType="Knife",Rarity="Godly"},
	["Earth"]={ItemName="Earth",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10761415410",ItemType="Knife",Rarity="Godly"},
	["Earth22"]={ItemName="Earth",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=3526872144",ItemType="Knife",Rarity="Godly"},
	["EasterBrod"]={ItemName="Easterbringer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9389270331",ItemType="Gun",Rarity="Godly"},
	["EasterEgg"]={ItemName="Easter Egg",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12684670673",ItemType="Knife",Rarity="Legendary"},
	["EasterEggG"]={ItemName="Easter Egg Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12684686256",ItemType="Gun",Rarity="Legendary"},
	["EasterFederation"]={ItemName="Easter Federation",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13036548591",ItemType="Knife",Rarity="Victim"},
	["EasterGun"]={ItemName="Easter Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13012237109",ItemType="Gun",Rarity="Rare"},
	["EasterKnife"]={ItemName="Easter Knife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13012210287",ItemType="Knife",Rarity="Rare"},
	["EasterOBV"]={ItemName="Easter OBV",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13012210287",ItemType="Knife",Rarity="Victim"},
	["Eco"]={ItemName="Eco",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365567889",ItemType="Knife",Rarity="Common"},
	["EctoKNI"]={ItemName="Ecto",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10702870679",ItemType="Knife",Rarity="Common"},
	["ED"]={ItemName="Faberge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9335193874",ItemType="Knife",Rarity="Legendary"},
	["EerieLuger"]={ItemName="Eerie Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13791393707",ItemType="Gun",Rarity="Ancient"},
	["Eggblade"]={ItemName="Eggblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7266437724",ItemType="Knife",Rarity="Godly"},
	["EggKnife"]={ItemName="Egg Knife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13002214103",ItemType="Knife",Rarity="Common"},
	["EggOblivion"]={ItemName="Egg Oblivion",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13036550442",ItemType="Knife",Rarity="Victim"},
	["Eggs"]={ItemName="Egg",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=387875405",ItemType="Knife",Rarity="Common"},
	["EggSeer"]={ItemName="Seer O' Eggs",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9388371078",ItemType="Knife",Rarity="Godly"},
	["EggSword"]={ItemName="Egg Cracker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9388058041",ItemType="Knife",Rarity="Godly"},
	["EgS"]={ItemName="Chocolate Egg",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9335240809",ItemType="Knife",Rarity="Uncommon"},
	["ElderBlade"]={ItemName="Elderwood Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11359058986",ItemType="Knife",Rarity="Godly"},
	["ElderGun"]={ItemName="Elderwood Revolver",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=4468571736",ItemType="Gun",Rarity="Godly"},
	["ElderKNI"]={ItemName="Elderwood Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6484433812",ItemType="Knife",Rarity="Ancient"},
	["ElderKnife"]={ItemName="Elder",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11459359408",ItemType="Knife",Rarity="Uncommon"},
	["ElderWoodLord"]={ItemName="Elderwood Lord",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=14835004442",ItemType="Knife",Rarity="Ancient"},
	["Electric"]={ItemName="Electric",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11645548288",ItemType="Knife",Rarity="Godly"},
	["ElectricForce"]={ItemName="Electric Force",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13070525663",ItemType="Knife",Rarity="Ancient"},
	["ElectricForceBlaster"]={ItemName="Electric Force Blaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13070527022",ItemType="Gun",Rarity="Ancient"},
	["Elf"]={ItemName="Elf",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=331746317",ItemType="Knife",Rarity="Common"},
	["Elf2"]={ItemName="Elf",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6676485129",ItemType="Knife",Rarity="Common"},
	["ElfGun"]={ItemName="Elf",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332767999",ItemType="Gun",Rarity="Common"},
	["Elite"]={ItemName="Elite",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=241095344",ItemType="Knife",Rarity="Legendary"},
	["EliteBlue"]={ItemName="Blue Elite",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=720&height=720&assetId=1269374321",ItemType="Knife",Rarity="Legendary"},
	["EliteGreen"]={ItemName="Green Elite",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332754554",ItemType="Knife",Rarity="Legendary"},
	["Emerald"]={ItemName="Emerald",Image="http://www.roblox.com/asset/?id=198461276",ItemType="Knife",Rarity="Legendary"},
	["Enchant"]={ItemName="Enchanted",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10650699495",ItemType="Knife",Rarity="Godly"},
	["Engraved"]={ItemName="Engraved",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203807690",ItemType="Gun",Rarity="Common"},
	["Envy"]={ItemName="Envy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8597255478",ItemType="Knife",Rarity="Uncommon"},
	["EPicnicKnife"]={ItemName="Easter Picnic",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13002297456",ItemType="Knife",Rarity="Uncommon"},
	["ErrorCommon"]={ItemName="Hacker Error",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=",ItemType="Knife",Rarity="Common"},
	["Eternal"]={ItemName="Eternal",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=538706317",ItemType="Knife",Rarity="Godly"},
	["eternalcane"]={ItemName="Eternalcane",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7707958777",ItemType="Knife",Rarity="Godly"},
	["EternalGalaxy"]={ItemName="Eternal Galaxy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2866244494",ItemType="Knife",Rarity="Godly"},
	["Eternalh"]={ItemName="Eternal Galaxy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2866244494",ItemType="Knife",Rarity="Godly"},
	["EternalII"]={ItemName="Eternal II",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7707954024",ItemType="Knife",Rarity="Godly"},
	["EternalIII"]={ItemName="Eternal III",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7707954501",ItemType="Knife",Rarity="Godly"},
	["EternalIV"]={ItemName="Eternal IV",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7707955529",ItemType="Knife",Rarity="Godly"},
	["EternalV"]={ItemName="Eternal V",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9441604143",ItemType="Knife",Rarity="Godly"},
	["EternalWinter"]={ItemName="Eternal Winter",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11611679187",ItemType="Knife",Rarity="Godly"},
	["Eternity"]={ItemName="Eternity",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=14833863379",ItemType="Knife",Rarity="Mythic"},
	["Euro"]={ItemName="Euro",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=305504173",ItemType="Knife",Rarity="Common"},
	["Extra"]={ItemName="Portals",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11521562669",ItemType="Gun",Rarity="Rare"},
	["EyeBall"]={ItemName="Eyeball",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11361636003",ItemType="Knife",Rarity="Common"},
	["EyeOftheAbyss"]={ItemName="Eye Of the Abyss",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=14791096970",ItemType="Knife",Rarity="Dream"},
	["Fade"]={ItemName="Fade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315501640",ItemType="Knife",Rarity="Legendary"},
	["FadingKnife"]={ItemName="Fading",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11488925725",ItemType="Knife",Rarity="Common"},
	["FakeGun"]={ItemName="Fake Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=197518111",ItemType="Knife",Rarity="Uncommon"},
	["FakeKNI"]={ItemName="Fake Knife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9127108628",ItemType="Gun",Rarity="Uncommon"},
	["Fall"]={ItemName="Fall Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10981825771",ItemType="Knife",Rarity="Godly"},
	["FallBreeze"]={ItemName="Fall's Breeze",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11557772066",ItemType="Knife",Rarity="Godly"},
	["FallCamo"]={ItemName="Fall Camo",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10469648598",ItemType="Gun",Rarity="Uncommon"},
	["Fallout"]={ItemName="Fallout",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=175668592",ItemType="Gun",Rarity="Common"},
	["FallScratch"]={ItemName="Orange Scratch",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11558667372",ItemType="Knife",Rarity="Legendary"},
	["Fang"]={ItemName="Fang",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=3187397768",ItemType="Knife",Rarity="Godly"},
	["Fanta"]={ItemName="Orange",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473626025",ItemType="Knife",Rarity="Common"},
	["Festive"]={ItemName="Festive",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8597254434",ItemType="Knife",Rarity="Rare"},
	["Firework2"]={ItemName="Firework",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13589895832",ItemType="Knife",Rarity="Ancient"},
	["Firework_G"]={ItemName="Firework",Image="13944750844",ItemType="Gun",Rarity="Ancient"},
	["FireworkDoom"]={ItemName="Firework Doom",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13945254297",ItemType="Knife",Rarity="Victim"},
	["Flames"]={ItemName="Flames",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=585873746",ItemType="Knife",Rarity="Ancient"},
	["Flare"]={ItemName="Flare Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetid=12798443166",ItemType="Gun",Rarity="Ancient"},
	["Flashlight"]={ItemName="Flashlight",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13129171395",ItemType="Knife",Rarity="Godly"},
	["FloralKnife"]={ItemName="Floral",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14166195589",ItemType="Knife",Rarity="Rare"},
	["FlowerGun"]={ItemName="Flower Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13009458297",ItemType="Gun",Rarity="Uncommon"},
	["FlowerKnife"]={ItemName="Flower",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13006926164",ItemType="Knife",Rarity="Uncommon"},
	["FlowerLuger"]={ItemName="Flower Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14608058301",ItemType="Gun",Rarity="Godly"},
	["FlowersKnife"]={ItemName="Flowers",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13849721333",ItemType="Knife",Rarity="Rare"},
	["Fog"]={ItemName="Fog",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11288188449",ItemType="Knife",Rarity="Uncommon"},
	["FreshScythe"]={ItemName="Fresh Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13529548333",ItemType="Knife",Rarity="Victim"},
	["Frost"]={ItemName="Frost",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11645549176",ItemType="Knife",Rarity="Godly"},
	["Frostbite"]={ItemName="Frostbite",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11483042598",ItemType="Knife",Rarity="Godly"},
	["FrostbitePack"]={ItemName="Frostbite Pack",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11611961669",ItemType="Knife",Rarity="Godly"},
	["Frosted"]={ItemName="Frosted",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11064526466",ItemType="Gun",Rarity="Common"},
	["Frosty"]={ItemName="Frosty",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6676484567",ItemType="Knife",Rarity="Uncommon"},
	["Frozen"]={ItemName="Frozen",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11085940961",ItemType="Knife",Rarity="Uncommon"},
	["Fusion"]={ItemName="Fusion",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365569686",ItemType="Knife",Rarity="Legendary"},
	["Future"]={ItemName="Future",Image="http://www.roblox.com/asset/?id=197639041",ItemType="Knife",Rarity="Uncommon"},
	["FuturisticBlade"]={ItemName="Futuristic",Image="http://www.roblox.com/asset/?id=10716394504",ItemType="Knife",Rarity="Ancient"},
	["GAHarv"]={ItemName="Galaxy Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10928399610",ItemType="Gun",Rarity="Ancient"},
	["Galactic"]={ItemName="Galactic",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=173913533",ItemType="Gun",Rarity="Rare"},
	["GalacticPole"]={ItemName="Galaxy Pole",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9084828249",ItemType="Knife",Rarity="Common"},
	["GalacticRaygun"]={ItemName="Galactic Raygun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154563071",ItemType="Gun",Rarity="Godly"},
	["GalaticKnife"]={ItemName="Galatic",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12699581611",ItemType="Knife",Rarity="Common"},
	["Galaxy"]={ItemName="Galaxy",Image="http://www.roblox.com/asset/?id=192480941",ItemType="Knife",Rarity="Rare"},
	["GalaxyBlade"]={ItemName="Galaxyblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11582653595",ItemType="Knife",Rarity="Godly"},
	["GalaxyConsumer"]={ItemName="Galaxy Consumer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13074636739",ItemType="Knife",Rarity="Ancient"},
	["GalaxyCresendo"]={ItemName="Galaxy Cresendo",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=4643805173",ItemType="Knife",Rarity="Godly"},
	["GalaxyHoleKnife"]={ItemName="Galaxy Hole",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12699585395",ItemType="Knife",Rarity="Uncommon"},
	["GalaxyIceShard"]={ItemName="Galaxy Ice Shard",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12543916871",ItemType="Knife",Rarity="Godly"},
	["GalaxyKarambit"]={ItemName="Galaxy Karambit",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154595497",ItemType="Knife",Rarity="Godly"},
	["GalaxyKatana"]={ItemName="Galaxy Katana",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5852997339",ItemType="Knife",Rarity="Godly"},
	["GalaxyKing"]={ItemName="Galaxy King",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12877155611",ItemType="Knife",Rarity="Godly"},
	["GalaxyLastHope"]={ItemName="Galaxy's Last Hope",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14108484987",ItemType="Knife",Rarity="Dream"},
	["GalaxyLuger"]={ItemName="Galaxy Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10179597414",ItemType="Gun",Rarity="Godly"},
	["GalaxyPeriastron"]={ItemName="Galaxy Periastron",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5852997947",ItemType="Knife",Rarity="Godly"},
	["GalaxyRayGun"]={ItemName="Galaxy Ray Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154602567",ItemType="Gun",Rarity="Godly"},
	["GalaxySouls"]={ItemName="Galaxy Souls",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13174695619",ItemType="Knife",Rarity="Godly"},
	["GalaxySugar"]={ItemName="Galaxy Sugar",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154690928",ItemType="Gun",Rarity="Godly"},
	["GalaxyWaves"]={ItemName="Galaxy Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12684952173",ItemType="Knife",Rarity="Ancient"},
	["GalaxyWebs"]={ItemName="Earth",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10034601923",ItemType="Knife",Rarity="Uncommon"},
	["GalaxyWithers"]={ItemName="Galaxy Wither",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154560400",ItemType="Knife",Rarity="Godly"},
	["garve"]={ItemName="Grave",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11227260622",ItemType="Gun",Rarity="Common"},
	["GBan"]={ItemName="Golden Ban Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11135316004",ItemType="Knife",Rarity="Ancient"},
	["GClover"]={ItemName="Green Clover",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12741305522",ItemType="Knife",Rarity="Common"},
	["GElderGun"]={ItemName="Gold Elderwood",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11363661530",ItemType="Gun",Rarity="Victim"},
	["Gemb"]={ItemName="Gemblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11115985432",ItemType="Knife",Rarity="Godly"},
	["Gemmy"]={ItemName="Gemstone",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6484429997",ItemType="Knife",Rarity="Godly"},
	["Gfire"]={ItemName="Green Fire",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6676486863",ItemType="Knife",Rarity="Legendary"},
	["GHarv"]={ItemName="Gold Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11363654968",ItemType="Gun",Rarity="Victim"},
	["Ghost"]={ItemName="Ghost",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10938021548",ItemType="Gun",Rarity="Legendary"},
	["GhostBlade"]={ItemName="Ghostblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7474451512",ItemType="Knife",Rarity="Godly"},
	["GhostBone"]={ItemName="Ghost's Bone",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9344094402",ItemType="Knife",Rarity="Godly"},
	["GhostFire"]={ItemName="Ghostfire",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11421244474",ItemType="Gun",Rarity="Rare"},
	["GhostFlame"]={ItemName="Ghost Flame",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13791184106",ItemType="Knife",Rarity="Ancient"},
	["ghostk"]={ItemName="Ghost",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11227060039",ItemType="Knife",Rarity="Legendary"},
	["GhostKarambit"]={ItemName="Ghost Karambit",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154595497",ItemType="Knife",Rarity="Godly"},
	["GhostKnife"]={ItemName="Ghost",Image="http://www.roblox.com/asset/?id=144268841",ItemType="Knife",Rarity="Classic"},
	["Ghostly"]={ItemName="Ghostly",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11361664731",ItemType="Knife",Rarity="Uncommon"},
	["GhostlyBats"]={ItemName="Ghostly Bats",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11288242176",ItemType="Knife",Rarity="Uncommon"},
	["GhostRay"]={ItemName="Ghost Ray",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13790982270",ItemType="Gun",Rarity="Ancient"},
	["ghosts"]={ItemName="Ghosts",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5866442790",ItemType="Knife",Rarity="Uncommon"},
	["Ghosts"]={ItemName="Ghosts",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5866442790",ItemType="Knife",Rarity="Uncommon"},
	["GhostSaber"]={ItemName="Ghost Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13770794170",ItemType="Knife",Rarity="Ancient"},
	["GhostsBlaster"]={ItemName="Ghost's Blaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12770059068",ItemType="Gun",Rarity="Ancient"},
	["GhostsK"]={ItemName="Ghosts",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5866442790",ItemType="Knife",Rarity="Uncommon"},
	["GhostsScythe"]={ItemName="Ghost's Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12770613259",ItemType="Knife",Rarity="Ancient"},
	["Ghosty"]={ItemName="Ghosty",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873080",ItemType="Knife",Rarity="Common"},
	["GhoulBlade"]={ItemName="Ghoulblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11474975351",ItemType="Knife",Rarity="Godly"},
	["giftbag"]={ItemName="Giftbag",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121864813",ItemType="Gun",Rarity="Common"},
	["GiftBag"]={ItemName="Gift Bag",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121864813",ItemType="Gun",Rarity="Common"},
	["Gifted"]={ItemName="Gifted",Image="http://www.roblox.com/asset/?id=197627734",ItemType="Knife",Rarity="Uncommon"},
	["GiftsGun"]={ItemName="Gifts",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11064521010",ItemType="Gun",Rarity="Common"},
	["Giftwrap"]={ItemName="Giftwrap",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10684682699",ItemType="Knife",Rarity="Common"},
	["GigaChadK"]={ItemName="Gigachad",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9117914818",ItemType="Knife",Rarity="Dream"},
	["Ginger"]={ItemName="Ginger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=331744703",ItemType="Knife",Rarity="Rare"},
	["GingerBlade"]={ItemName="Gingerblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2669336659",ItemType="Knife",Rarity="Godly"},
	["GingerBread"]={ItemName="Gingerbread",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10684692635",ItemType="Gun",Rarity="Uncommon"},
	["Gingerbread"]={ItemName="Gingerbread",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121860619",ItemType="Gun",Rarity="Uncommon"},
	["GingerbreadGun"]={ItemName="Gingerbread",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11064552137",ItemType="Gun",Rarity="Uncommon"},
	["GingerGun"]={ItemName="Ginger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332497038",ItemType="Gun",Rarity="Rare"},
	["GingerKNI"]={ItemName="Ginger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2669638742",ItemType="Knife",Rarity="Legendary"},
	["GingerLuger"]={ItemName="Ginger Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6691516059",ItemType="Gun",Rarity="Godly"},
	["Gingery"]={ItemName="Gingerbread",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6676485952",ItemType="Knife",Rarity="Rare"},
	["Glitch1"]={ItemName="Glitch1",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=420&height=420&assetId=196751515",ItemType="Knife",Rarity="Common"},
	["Glitch2"]={ItemName="Glitch2",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=420&height=420&assetId=196751515",ItemType="Knife",Rarity="Common"},
	["Glitch3"]={ItemName="Glitch3",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=420&height=420&assetId=196751515",ItemType="Knife",Rarity="Common"},
	["Glitched"]={ItemName="Glitched Time",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9144895887",ItemType="Knife",Rarity="Uncommon"},
	["GlitchedKnife"]={ItemName="Glitched Knife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12957289158",ItemType="Knife",Rarity="Legendary"},
	["GlitchedLeaf"]={ItemName="Glitched Leaf",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=4659636452",ItemType="Knife",Rarity="Dream"},
	["Glitter"]={ItemName="Glitter Star",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12490006664",ItemType="Knife",Rarity="Godly"},
	["GlitterPO"]={ItemName="Glitter PO",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12742140554",ItemType="Knife",Rarity="Ancient"},
	["GlitterPoIceblaster"]={ItemName="Glitter PO Iceblaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12708081959",ItemType="Gun",Rarity="Ancient"},
	["GodBlade"]={ItemName="GODBLADE",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11531853158",ItemType="Knife",Rarity="Godly"},
	["GodsWrath"]={ItemName="God's Wrath",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14516512341",ItemType="Knife",Rarity="Dream"},
	["GOLD"]={ItemName="Golden Candy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7231969618",ItemType="Knife",Rarity="Victim"},
	["GOLD2"]={ItemName="Golden Sugar",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6696937657",ItemType="Gun",Rarity="Victim"},
	["GoldBat"]={ItemName="Gold Bat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11497107398",ItemType="Knife",Rarity="Custom"},
	["GoldCandy"]={ItemName="Gold Candy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8563597228",ItemType="Knife",Rarity="Victim"},
	["GOLDEGG"]={ItemName="Golden Egg",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9335339879",ItemType="Knife",Rarity="Godly"},
	["GoldElderBlade"]={ItemName="Gold Elderwood",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14523052902",ItemType="Knife",Rarity="Ancient"},
	["Golden Iceblaster"]={ItemName="Gold Iceblaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7129826323",ItemType="Gun",Rarity="Victim"},
	["Golden Icebreaker"]={ItemName="Gold Icebreaker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6404115112",ItemType="Knife",Rarity="Victim"},
	["GoldenBatwing"]={ItemName="Golden Batwing",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13430632151",ItemType="Knife",Rarity="Victim"},
	["GoldenBunny"]={ItemName="Golden Bunny",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13002375437",ItemType="Knife",Rarity="Rare"},
	["GoldenEdge"]={ItemName="Golden Hallow",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9561288313",ItemType="Knife",Rarity="Victim"},
	["GoldenGun"]={ItemName="Golden",Image="http://www.roblox.com/asset/?id=147835357",ItemType="Gun",Rarity="Classic"},
	["GoldenKnife"]={ItemName="Golden",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2534846221",ItemType="Knife",Rarity="Rare"},
	["GoldGun"]={ItemName="Gold Swirly",Image="http://www.roblox.com/asset/?id=9029716722",ItemType="Gun",Rarity="Victim"},
	["GoldIceCrusher"]={ItemName="Icecrusher",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14686897067",ItemType="Knife",Rarity="Victim"},
	["GoldIcePiercer"]={ItemName="Icepiercer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14686912739",ItemType="Gun",Rarity="Victim"},
	["GoldKNI"]={ItemName="Golden",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11132857745",ItemType="Knife",Rarity="Classic"},
	["GoldLogchopper"]={ItemName="Gold Logchopper",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12670875631",ItemType="Knife",Rarity="Ancient"},
	["GoldMinty"]={ItemName="Gold Minty",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12671115486",ItemType="Gun",Rarity="Victim"},
	["GoldSummerBlade"]={ItemName="Gold Summer Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14710306099",ItemType="Knife",Rarity="Victim"},
	["GoldSwirlyAxe"]={ItemName="Gold Swirly",Image="http://www.roblox.com/asset/?id=9029702397",ItemType="Knife",Rarity="Victim"},
	["GoldWaves"]={ItemName="Gold Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13553771108",ItemType="Knife",Rarity="Rare"},
	["Goo"]={ItemName="Goo",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=237336076",ItemType="Knife",Rarity="Common"},
	["GooBlaster"]={ItemName="Goo Blaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13019236092",ItemType="Gun",Rarity="Godly"},
	["gorhicg"]={ItemName="Gothic",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11230717411",ItemType="Gun",Rarity="Uncommon"},
	["Gothic"]={ItemName="Gothic",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10469646210",ItemType="Knife",Rarity="Uncommon"},
	["GradientClover"]={ItemName="Gradient Clover",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12741415312",ItemType="Knife",Rarity="Uncommon"},
	["Graffiti"]={ItemName="Galaxy Graffiti",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9143014948",ItemType="Knife",Rarity="Legendary"},
	["GraffitiKNI"]={ItemName="Graffiti",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=4659634630",ItemType="Knife",Rarity="Uncommon"},
	["Grandmaster"]={ItemName="Grandmaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2846089925",ItemType="Knife",Rarity="Victim"},
	["Grave"]={ItemName="Grave",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10935528758",ItemType="Knife",Rarity="Common"},
	["GrayBlizzard"]={ItemName="Gray Blizzard",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433436754",ItemType="Knife",Rarity="Rare"},
	["GrayGalaxy"]={ItemName="Gray Galaxy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12881495373",ItemType="Knife",Rarity="Common"},
	["GrayTech"]={ItemName="Gray Tech",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433227635",ItemType="Knife",Rarity="Rare"},
	["GreenAlien"]={ItemName="Green Alien",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13074028185",ItemType="Knife",Rarity="Godly"},
	["GreenBlizzard"]={ItemName="Green Blizzard",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433445370",ItemType="Knife",Rarity="Common"},
	["GreenCandy"]={ItemName="Green Candy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2851762405",ItemType="Knife",Rarity="Godly"},
	["GreenFadedRadioactive"]={ItemName="Green Faded Radioactive",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13651492806",ItemType="Knife",Rarity="Uncommon"},
	["GreenHallowGun"]={ItemName="Green Hallow Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13072143597",ItemType="Gun",Rarity="Godly"},
	["GreenHammer"]={ItemName="Green Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433316376",ItemType="Knife",Rarity="Common"},
	["GreenKNI"]={ItemName="Green Marble",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10702881824",ItemType="Knife",Rarity="Rare"},
	["GreenLuger"]={ItemName="Green Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=1005311101",ItemType="Gun",Rarity="Godly"},
	["GreenSaber"]={ItemName="Green Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10940490202",ItemType="Knife",Rarity="Ancient"},
	["GreenScratch"]={ItemName="Bunny Scratch",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9389255906",ItemType="Knife",Rarity="Legendary"},
	["GreenSharkseeker"]={ItemName="Green Sharkseeker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13072182344",ItemType="Gun",Rarity="Godly"},
	["GreenTech"]={ItemName="Green Tech",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433207139",ItemType="Knife",Rarity="Common"},
	["GreenUfo"]={ItemName="Green UFO",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13074704405",ItemType="Knife",Rarity="Common"},
	["GreenVampireEdge"]={ItemName="Green Vampire's Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13072073150",ItemType="Knife",Rarity="Godly"},
	["GreyPixel"]={ItemName="Gray Pixel",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12881515575",ItemType="Knife",Rarity="Common"},
	["Grim"]={ItemName="Grim",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11190358237",ItemType="Knife",Rarity="Common"},
	["GrimReaper"]={ItemName="Grim Reaper",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5003097935",ItemType="Knife",Rarity="Godly"},
	["GrimS"]={ItemName="Grim Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11403158113",ItemType="Knife",Rarity="Godly"},
	["Grind"]={ItemName="Grind",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=305503942",ItemType="Knife",Rarity="Common"},
	["GUM"]={ItemName="Pink Candy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2865358733",ItemType="Knife",Rarity="Godly"},
	["Gun1"]={ItemName="Cowboy",Image="http://www.roblox.com/asset/?id=144290769",ItemType="Gun",Rarity="Classic"},
	["GVampire"]={ItemName="Gold Vamp's Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7871361074",ItemType="Knife",Rarity="Victim"},
	["GVirtual"]={ItemName="Gold Virtual",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11090654958",ItemType="Knife",Rarity="Victim"},
	["GWavesK"]={ItemName="Gold Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13973932074",ItemType="Knife",Rarity="Godly"},
	["hack"]={ItemName="Hackstone",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10913861917",ItemType="Knife",Rarity="Godly"},
	["Hacked2"]={ItemName="Hacked",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433200855",ItemType="Knife",Rarity="Rare"},
	["Hacker"]={ItemName="Hacker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203819271",ItemType="Gun",Rarity="Rare"},
	["HackerBlaster"]={ItemName="Hacker Blaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12708383565",ItemType="Gun",Rarity="Godly"},
	["HackerVirtual"]={ItemName="Hacker Virtual",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12708382384",ItemType="Knife",Rarity="Godly"},
	["Hallow"]={ItemName="Hallow's Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531878205",ItemType="Knife",Rarity="Godly"},
	["HallowBlade"]={ItemName="Hallow's Blade",Image="http://www.roblox.com/asset/?id=1258872529",ItemType="Knife",Rarity="Godly"},
	["HallowGod"]={ItemName="Hallow's God",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11358664039",ItemType="Knife",Rarity="Godly"},
	["Hallowgun"]={ItemName="Hallowgun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5877089721",ItemType="Gun",Rarity="Godly"},
	["HallowKing"]={ItemName="Hallow's King",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11298136675",ItemType="Knife",Rarity="Godly"},
	["HallowKNI"]={ItemName="Hallowscythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11165162734",ItemType="Knife",Rarity="Ancient"},
	["HallowMagic1"]={ItemName="Hallow's Magic",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11165387956",ItemType="Gun",Rarity="Rare"},
	["HallowMagic2"]={ItemName="Hallow's Magic",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11288235936",ItemType="Knife",Rarity="Rare"},
	["HallowSaber"]={ItemName="Hallow Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10831068605",ItemType="Knife",Rarity="Godly"},
	["HallowsDoom2"]={ItemName="Hallow's Doom",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14108542614",ItemType="Knife",Rarity="Dream"},
	["HallowSky"]={ItemName="Autumn Sky",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11459554147",ItemType="Knife",Rarity="Legendary"},
	["HammerTime"]={ItemName="Stormbreaker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13867881010",ItemType="Knife",Rarity="Ancient"},
	["Handsaw"]={ItemName="Handsaw",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332042435",ItemType="Knife",Rarity="Godly"},
	["Hard"]={ItemName="Hardened",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6696850681",ItemType="Knife",Rarity="Common"},
	["Harv"]={ItemName="Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7864252802",ItemType="Gun",Rarity="Ancient"},
	["HarvL"]={ItemName="Heart Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12489940637",ItemType="Gun",Rarity="Godly"},
	["Haunted"]={ItemName="Haunted",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10469640867",ItemType="Knife",Rarity="Common"},
	["Haunted2"]={ItemName="Haunted",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10938042664",ItemType="Gun",Rarity="Common"},
	["Hauntedk"]={ItemName="Haunted",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11227114070",ItemType="Knife",Rarity="Common"},
	["Hazard"]={ItemName="Hazard",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11361646375",ItemType="Knife",Rarity="Uncommon"},
	["Hazard2"]={ItemName="Hazard",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11421227517",ItemType="Gun",Rarity="Uncommon"},
	["Hazmat"]={ItemName="Hazmat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315501297",ItemType="Knife",Rarity="Uncommon"},
	["Heartblade"]={ItemName="Heartblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6413214382",ItemType="Knife",Rarity="Godly"},
	["Heartbreaker"]={ItemName="Heartbreaker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11534147919",ItemType="Knife",Rarity="Ancient"},
	["Hearts"]={ItemName="Hearts",Image="https://www.roblox.com/asset/?id=363362737",ItemType="Knife",Rarity="Common"},
	["HeartsG"]={ItemName="Hearts",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12359259801",ItemType="Gun",Rarity="Uncommon"},
	["HeartsK"]={ItemName="Hearts",Image="https://www.roblox.com/asset/?id=363362737",ItemType="Knife",Rarity="Common"},
	["Heat"]={ItemName="Heat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=3187444758",ItemType="Knife",Rarity="Godly"},
	["Heatwave"]={ItemName="Heatwave",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2955984749",ItemType="Knife",Rarity="Godly"},
	["heavenly"]={ItemName="Heaven",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10770134784",ItemType="Knife",Rarity="Godly"},
	["Hero"]={ItemName="Spring Hero",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=4463367089",ItemType="Knife",Rarity="Godly"},
	["HighTech"]={ItemName="High Tech",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=4659635055",ItemType="Knife",Rarity="Uncommon"},
	["Hive"]={ItemName="Hive",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315501434",ItemType="Knife",Rarity="Uncommon"},
	["HL2"]={ItemName="HL2",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238546100",ItemType="Gun",Rarity="Common"},
	["HollyKNI"]={ItemName="Holly",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2669638990",ItemType="Knife",Rarity="Uncommon"},
	["hologun"]={ItemName="Hologun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11489105673",ItemType="Gun",Rarity="Common"},
	["holoknife"]={ItemName="Holoknife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11489150805",ItemType="Knife",Rarity="Common"},
	["HoloSaber"]={ItemName="Holographic Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11087170589",ItemType="Knife",Rarity="Godly"},
	["HOP"]={ItemName="Bunnyhops",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9335209901",ItemType="Knife",Rarity="Uncommon"},
	["Hunter"]={ItemName="Hunter",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11421368292",ItemType="Knife",Rarity="Common"},
	["Ice"]={ItemName="Ice",Image="http://www.roblox.com/asset/?id=191976710",ItemType="Knife",Rarity="Common"},
	["Ice beam"]={ItemName="Icebeam",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9319693764",ItemType="Gun",Rarity="Godly"},
	["Ice flake"]={ItemName="Iceflake",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10147681981",ItemType="Knife",Rarity="Godly"},
	["ICE1"]={ItemName="Icebreaker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6492468078",ItemType="Knife",Rarity="Ancient"},
	["ICE2"]={ItemName="Iceblaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7177398867",ItemType="Gun",Rarity="Godly"},
	["IceCamo"]={ItemName="Ice Camo",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10684696156",ItemType="Gun",Rarity="Rare"},
	["IceCrack"]={ItemName="Icecracker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121848805",ItemType="Knife",Rarity="Legendary"},
	["Icecracker"]={ItemName="Icecracker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121848805",ItemType="Knife",Rarity="Legendary"},
	["IcecreamKnife"]={ItemName="Icecream",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13849681146",ItemType="Knife",Rarity="Uncommon"},
	["Icecrusher3"]={ItemName="Icecrusher",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=11855282546",ItemType="Knife",Rarity="Godly"},
	["IceDragon"]={ItemName="Ice Dragon",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=585846454",ItemType="Knife",Rarity="Godly"},
	["icepop"]={ItemName="Ice Pop",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10034302558",ItemType="Knife",Rarity="Uncommon"},
	["icey"]={ItemName="Icewing",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7089084437",ItemType="Knife",Rarity="Ancient"},
	["IciclesKNI"]={ItemName="Icicles",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2669639638",ItemType="Knife",Rarity="Rare"},
	["Idol"]={ItemName="Super Idol",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7030500492",ItemType="Knife",Rarity="Legendary"},
	["Imbued"]={ItemName="Imbued",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=162668312",ItemType="Gun",Rarity="Rare"},
	["Indy"]={ItemName="Indy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=305506951",ItemType="Knife",Rarity="Common"},
	["Infected"]={ItemName="Infected",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=200953094",ItemType="Knife",Rarity="Common"},
	["InfectedGun"]={ItemName="Infected",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11421270078",ItemType="Gun",Rarity="Common"},
	["InfectedK"]={ItemName="Infected",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11421330374",ItemType="Knife",Rarity="Common"},
	["Infiltrator"]={ItemName="Infiltrator",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203806022",ItemType="Gun",Rarity="Common"},
	["INK"]={ItemName="Splat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6696851110",ItemType="Gun",Rarity="Common"},
	["iRevolver"]={ItemName="iRevolver",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203809168",ItemType="Gun",Rarity="Rare"},
	["Iron"]={ItemName="Iron",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=160201541",ItemType="Gun",Rarity="Common"},
	["Jack"]={ItemName="Jack",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315099010",ItemType="Knife",Rarity="Rare"},
	["JackORainbows"]={ItemName="Chroma Jack O' Rainbows",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2978125233",ItemType="Knife",Rarity="Legendary",Chroma=true},
	["JackTrack"]={ItemName="Jack's Track",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9819748169",ItemType="Knife",Rarity="Victim"},
	["JaysBatwing"]={ItemName="Jay's Batwing",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12566454928",ItemType="Knife",Rarity="Ancient"},
	["JaysHarvester"]={ItemName="Jay's Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12566486707",ItemType="Gun",Rarity="Ancient"},
	["JaysiPhone"]={ItemName="Jay's iPhone",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13157109762",ItemType="Knife",Rarity="Ancient"},
	["JBasketball"]={ItemName="Julia's Basketball",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12955957018",ItemType="Knife",Rarity="Ancient"},
	["JD"]={ItemName="JD",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=566867312",ItemType="Knife",Rarity="Legendary"},
	["JesusPhantom"]={ItemName="Jesuss Phantom",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13070621761",ItemType="Knife",Rarity="Ancient"},
	["JesusSpectre"]={ItemName="Jesuss Spectre",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13070619796",ItemType="Gun",Rarity="Ancient"},
	["JIceblaster"]={ItemName="Julia's Iceblaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12568392325",ItemType="Gun",Rarity="Ancient"},
	["Jigsaw"]={ItemName="Jigsaw",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365569126",ItemType="Knife",Rarity="Uncommon"},
	["JingleGun"]={ItemName="Jinglegun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6909193869",ItemType="Gun",Rarity="Godly"},
	["JKarambit"]={ItemName="Julia's Karambit",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12568277479",ItemType="Knife",Rarity="Ancient"},
	["Juice"]={ItemName="Juice",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13529473111",ItemType="Gun",Rarity="Victim"},
	["jup"]={ItemName="Jupiter",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10034612307",ItemType="Knife",Rarity="Legendary"},
	["kevinjiram1"]={ItemName="kevinjiram1's Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12568156036",ItemType="Knife",Rarity="Ancient"},
	["kevinjiram1G"]={ItemName="kevinjiram1's Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12568163805",ItemType="Gun",Rarity="Ancient"},
	["KittyGun"]={ItemName="Kitty Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14319678518",ItemType="Gun",Rarity="Victim"},
	["KittyKnife2"]={ItemName="Kitty",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14319684090",ItemType="Knife",Rarity="Victim"},
	["Knife1"]={ItemName="Splitter",Image="http://www.roblox.com/asset/?id=143820641",ItemType="Knife",Rarity="Classic"},
	["Knife_2"]={ItemName="Diyaa",Image="rbxassetid://14832117050",ItemType="Knife",Rarity="Dream"},
	["Kool"]={ItemName="Yellow",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473625906",ItemType="Knife",Rarity="Common"},
	["KoolU"]={ItemName="KoolAid",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7030500492",ItemType="Knife",Rarity="Common"},
	["Korblox"]={ItemName="Korblox",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315501501",ItemType="Knife",Rarity="Rare"},
	["Krypto"]={ItemName="Krypto",Image="http://www.roblox.com/asset/?id=198458841",ItemType="Knife",Rarity="Rare"},
	["Lantern"]={ItemName="Lantern",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11421404772",ItemType="Knife",Rarity="Uncommon"},
	["Laser"]={ItemName="Laser",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=3187422496",ItemType="Gun",Rarity="Godly"},
	["LavaHarvester"]={ItemName="Lava Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13036372703",ItemType="Gun",Rarity="Ancient"},
	["LeafBringer"]={ItemName="Leafbringer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=12701558659",ItemType="Gun",Rarity="Victim"},
	["LeafCorrupt"]={ItemName="Leaf Corrupt",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13850672123",ItemType="Knife",Rarity="Godly"},
	["LeafKNI"]={ItemName="Leaf",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=4659636452",ItemType="Knife",Rarity="Common"},
	["LeafLuger"]={ItemName="Leaf Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13849775154",ItemType="Gun",Rarity="Godly"},
	["LeafOLuger"]={ItemName="Leaf O' Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11557568828",ItemType="Gun",Rarity="Godly"},
	["LeafScythe"]={ItemName="Leafscythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=12701559436",ItemType="Knife",Rarity="Ancient"},
	["LeafShard"]={ItemName="Leaf Shard",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13849764873",ItemType="Knife",Rarity="Godly"},
	["LeafsLuger"]={ItemName="Luger O' Nature",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9361205598",ItemType="Gun",Rarity="Godly"},
	["LegendaryIce"]={ItemName="Enchanted Blaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10045264641",ItemType="Gun",Rarity="Ancient"},
	["Lego"]={ItemName="....",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=142257783",ItemType="Knife",Rarity="Common"},
	["LegoBleed"]={ItemName="Lego's Bleed",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11459419632",ItemType="Gun",Rarity="Legendary"},
	["LegoC"]={ItemName="Master's Darkbringer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10333816668",ItemType="Gun",Rarity="Godly"},
	["LegoD"]={ItemName="Master's Dartbringer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11489586388",ItemType="Gun",Rarity="Victim"},
	["LegoLuger"]={ItemName="Master's Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11489608804",ItemType="Gun",Rarity="Godly"},
	["LegoSC"]={ItemName="Master's Seeker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10035821605",ItemType="Gun",Rarity="Victim"},
	["LegosMM2"]={ItemName="Lego",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11489294739",ItemType="Knife",Rarity="Victim"},
	["LegoSy"]={ItemName="Master's Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10914068113",ItemType="Knife",Rarity="Victim"},
	["LightAXE"]={ItemName="Light Axe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2613911237",ItemType="Knife",Rarity="Godly"},
	["LightBlueWaves"]={ItemName="Light Blue Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13553692771",ItemType="Knife",Rarity="Uncommon"},
	["LightBrod"]={ItemName="Lightbringer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6229048362",ItemType="Gun",Rarity="Godly"},
	["Lightning"]={ItemName="Lightning",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9094202233",ItemType="Gun",Rarity="Common"},
	["Lights"]={ItemName="Lights",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2866301922",ItemType="Knife",Rarity="Uncommon"},
	["LightsK"]={ItemName="Lights",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11064557436",ItemType="Knife",Rarity="Uncommon"},
	["Lightyear"]={ItemName="Lightyear",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9144867666",ItemType="Knife",Rarity="Common"},
	["LikeABoss"]={ItemName="MLG",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7030500492",ItemType="Knife",Rarity="Common"},
	["Lime"]={ItemName="Lime",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8597253606",ItemType="Knife",Rarity="Uncommon"},
	["LimeFadedRadioactive"]={ItemName="Lime Faded Radioactive",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13651479990",ItemType="Knife",Rarity="Rare"},
	["Linked"]={ItemName="Linked",Image="http://www.roblox.com/asset/?id=198453528",ItemType="Knife",Rarity="Common"},
	["LMFAO"]={ItemName="Pink",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473626473",ItemType="Knife",Rarity="Uncommon"},
	["Log"]={ItemName="Log",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365567962",ItemType="Knife",Rarity="Common"},
	["logchopper"]={ItemName="Logchopper",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6546515752",ItemType="Knife",Rarity="Ancient"},
	["LolGun"]={ItemName="Lol Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12957220348",ItemType="Gun",Rarity="Uncommon"},
	["LolKnife"]={ItemName="Lol Knife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12957174825",ItemType="Knife",Rarity="Common"},
	["LongGalaxy"]={ItemName="Long Galaxies",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9281331917",ItemType="Knife",Rarity="Ancient"},
	["LongRainbows"]={ItemName="Long Rainbows",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2764489474",ItemType="Knife",Rarity="Godly"},
	["Lor"]={ItemName="Green Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10491532112",ItemType="Knife",Rarity="Custom"},
	["LorizasUltimateBlade"]={ItemName="Glitch 3",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7945053992",ItemType="Knife",Rarity="Victim"},
	["Love"]={ItemName="Love",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=196750845",ItemType="Knife",Rarity="Common"},
	["LoveGun"]={ItemName="Love",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203867650",ItemType="Gun",Rarity="Uncommon"},
	["LovelyKNI"]={ItemName="Lovely",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6696824052",ItemType="Knife",Rarity="Common"},
	["LuckSaber"]={ItemName="Luck Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12814330768",ItemType="Knife",Rarity="Ancient"},
	["Lucky"]={ItemName="Lucky",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365569265",ItemType="Knife",Rarity="Uncommon"},
	["LuckyBeam"]={ItemName="Lucky Beam",Image="http://www.roblox.com/asset/?id=12815459183",ItemType="Knife",Rarity="Godly"},
	["LuckyEdge"]={ItemName="Lucky Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12815645977",ItemType="Knife",Rarity="Godly"},
	["LuckyGun"]={ItemName="Lucky",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12725441577",ItemType="Gun",Rarity="Ancient"},
	["LuckyIceblaster"]={ItemName="Lucky Iceblaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12814327308",ItemType="Gun",Rarity="Godly"},
	["LuckysLuger"]={ItemName="Lucky's Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12814269066",ItemType="Gun",Rarity="Ancient"},
	["LuckySwirl"]={ItemName="Lucky Swirl",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12725979519",ItemType="Knife",Rarity="Ancient"},
	["Luger"]={ItemName="Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=3187399148",ItemType="Gun",Rarity="Godly"},
	["lugercane"]={ItemName="Lugercane",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8033657330",ItemType="Gun",Rarity="Godly"},
	["LWeb"]={ItemName="Lego's Web",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11459398661",ItemType="Knife",Rarity="Legendary"},
	["Magma"]={ItemName="Magma",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10469645319",ItemType="Knife",Rarity="Rare"},
	["magma"]={ItemName="Magma",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11230714942",ItemType="Gun",Rarity="Rare"},
	["Magma2"]={ItemName="Magma",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11497022655",ItemType="Knife",Rarity="Godly"},
	["MagmaKNI"]={ItemName="Magma",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10702878536",ItemType="Knife",Rarity="Rare"},
	["Majestic"]={ItemName="Majestic",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11611275036",ItemType="Knife",Rarity="Godly"},
	["Makeshift"]={ItemName="Makeshift",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11265604130",ItemType="Gun",Rarity="Godly"},
	["MakeshiftK"]={ItemName="Makeshift",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11421438883",ItemType="Knife",Rarity="Rare"},
	["Marina"]={ItemName="Marina",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203808190",ItemType="Gun",Rarity="Uncommon"},
	["Marley"]={ItemName="Green",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473625785",ItemType="Knife",Rarity="Common"},
	["Mars"]={ItemName="Mars",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11521370408",ItemType="Knife",Rarity="Uncommon"},
	["MAsterBlade"]={ItemName="Master's Nightblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10203337028",ItemType="Knife",Rarity="Godly"},
	["MasterBlade"]={ItemName="Master's Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11489702133",ItemType="Knife",Rarity="Godly"},
	["MB"]={ItemName="Minty's Tides",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9962014908",ItemType="Knife",Rarity="Custom"},
	["Mechanic"]={ItemName="Mech's Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12565252196",ItemType="Knife",Rarity="Ancient"},
	["MechanicH"]={ItemName="Mech's Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12565352326",ItemType="Gun",Rarity="Ancient"},
	["Melon"]={ItemName="Melon",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315501369",ItemType="Knife",Rarity="Uncommon"},
	["MelonGun"]={ItemName="Melon",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14166276522",ItemType="Gun",Rarity="Uncommon"},
	["Mercury"]={ItemName="Mercury",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=12877363091",ItemType="Knife",Rarity="Uncommon"},
	["MickeyMouseLuger"]={ItemName="Mickey Mouse Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14601437994",ItemType="Gun",Rarity="Godly"},
	["mid"]={ItemName="Midnight Heat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10333279761",ItemType="Knife",Rarity="Godly"},
	["Midnight"]={ItemName="Midnight",Image="http://www.roblox.com/asset/?id=197664126",ItemType="Knife",Rarity="Legendary"},
	["MidnightAxe"]={ItemName="Midnight Axe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12652903619",ItemType="Knife",Rarity="Ancient"},
	["MidnightBlade2"]={ItemName="Midnight Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13159569964",ItemType="Knife",Rarity="Ancient"},
	["minty"]={ItemName="Minty",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6720772904",ItemType="Gun",Rarity="Godly"},
	["MISS"]={ItemName="Bronze Candy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7231969153",ItemType="Knife",Rarity="Victim"},
	["MISS2"]={ItemName="Bronze Sugar",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6992378303",ItemType="Gun",Rarity="Victim"},
	["MISS3"]={ItemName="Silver Sugar",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12708467338",ItemType="Gun",Rarity="Victim"},
	["Missing"]={ItemName="Missing",Image="http://www.roblox.com/asset/?id=198455936",ItemType="Knife",Rarity="Uncommon"},
	["MLG"]={ItemName="Shiny",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473626979",ItemType="Knife",Rarity="Legendary"},
	["MLGChips"]={ItemName="Chips",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12579331175",ItemType="Knife",Rarity="Uncommon"},
	["MLGDew"]={ItemName="Dew",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12579363005",ItemType="Knife",Rarity="Rare"},
	["MLGDoritos"]={ItemName="Doritos",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12579376653",ItemType="Knife",Rarity="Rare"},
	["MLGFanta"]={ItemName="Fanta",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12579273144",ItemType="Knife",Rarity="Common"},
	["MLGG"]={ItemName="MLG Knife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12584586482",ItemType="Knife",Rarity="Legendary"},
	["MLGGoldenKnife"]={ItemName="MLG Golden",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12579439062",ItemType="Knife",Rarity="Godly"},
	["MLGKool"]={ItemName="Kool",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12579284565",ItemType="Knife",Rarity="Common"},
	["MLGLMFAO"]={ItemName="Lol",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12579319932",ItemType="Knife",Rarity="Uncommon"},
	["MLGMarley"]={ItemName="Marley",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12579295237",ItemType="Knife",Rarity="Common"},
	["MLGPepper"]={ItemName="Pepper",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=12579263600",ItemType="Knife",Rarity="Common"},
	["MLGSnoop"]={ItemName="Snoop",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12579347846",ItemType="Knife",Rarity="Uncommon"},
	["MM2"]={ItemName="MM2",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11489232305",ItemType="Knife",Rarity="Uncommon"},
	["MM2Space"]={ItemName="Space",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6696852403",ItemType="Knife",Rarity="Rare"},
	["Molten"]={ItemName="Molten",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203869308",ItemType="Gun",Rarity="Rare"},
	["MoltenKnife"]={ItemName="Molten",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235371809",ItemType="Knife",Rarity="Rare"},
	["MoneyHammer"]={ItemName="Money Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14529327212",ItemType="Knife",Rarity="Ancient"},
	["MoneyLuger"]={ItemName="Money Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14529548162",ItemType="Gun",Rarity="Ancient"},
	["MonsterAxe"]={ItemName="Monster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11226504523",ItemType="Knife",Rarity="Godly"},
	["Moon"]={ItemName="Moon",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11521411797",ItemType="Gun",Rarity="Uncommon"},
	["MoonHex"]={ItemName="Moon Hex",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13003511759",ItemType="Knife",Rarity="Ancient"},
	["MoonKnife"]={ItemName="Moon",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12699587826",ItemType="Knife",Rarity="Common"},
	["Moonlight"]={ItemName="Moonlight",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10960548592",ItemType="Knife",Rarity="Godly"},
	["MoonLight"]={ItemName="Moonlight",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11421234997",ItemType="Gun",Rarity="Uncommon"},
	["Moons"]={ItemName="Moons",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873154",ItemType="Knife",Rarity="Uncommon"},
	["MT"]={ItemName="Minty's Blaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10960663086",ItemType="Gun",Rarity="Custom"},
	["mumfied"]={ItemName="Mummified",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11230757529",ItemType="Knife",Rarity="Uncommon"},
	["Mummy"]={ItemName="Mummy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315155591",ItemType="Gun",Rarity="Rare"},
	["Mummy2"]={ItemName="Mummy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10938011803",ItemType="Knife",Rarity="Uncommon"},
	["mummygun"]={ItemName="Mummy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5866463755",ItemType="Gun",Rarity="Uncommon"},
	["MummyGun2020"]={ItemName="Mummy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5866463755",ItemType="Gun",Rarity="Uncommon"},
	["MummyK"]={ItemName="Mummy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11227273117",ItemType="Gun",Rarity="Uncommon"},
	["MummyKNI"]={ItemName="Mummy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10702872356",ItemType="Knife",Rarity="Uncommon"},
	["Musical"]={ItemName="Musical",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365569566",ItemType="Knife",Rarity="Rare"},
	["Mutant"]={ItemName="Mutant",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154580456",ItemType="Gun",Rarity="Godly"},
	["MythicalSummer"]={ItemName="Mythical Summer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14312371922",ItemType="Gun",Rarity="Godly"},
	["NebUla"]={ItemName="Nebula",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7207884027",ItemType="Knife",Rarity="Godly"},
	["Nebula"]={ItemName="Nebula",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7207884027",ItemType="Knife",Rarity="Godly"},
	["NeoGrey"]={ItemName="Neo Grey",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12684936181",ItemType="Knife",Rarity="Ancient"},
	["NeoHammer"]={ItemName="Neo Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433916864",ItemType="Knife",Rarity="Legendary"},
	["NeoHandsaw"]={ItemName="Neosaw",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11504026962",ItemType="Knife",Rarity="Godly"},
	["Neon"]={ItemName="Neon",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=159746637",ItemType="Knife",Rarity="Common"},
	["NeonGreen"]={ItemName="Neon Green",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12741490898",ItemType="Knife",Rarity="Legendary"},
	["NeonSaw"]={ItemName="Neon Saw",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13156571119",ItemType="Gun",Rarity="Ancient"},
	["NeoRadioactive"]={ItemName="Neo Radioactive",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13651486465",ItemType="Knife",Rarity="Legendary"},
	["NeoSaber"]={ItemName="Neo Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14299682275",ItemType="Knife",Rarity="Godly"},
	["Neptune"]={ItemName="Neptune",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10761306662",ItemType="Knife",Rarity="Legendary"},
	["Neptune2"]={ItemName="Neptune",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=12877366923",ItemType="Knife",Rarity="Uncommon"},
	["NERFGUN"]={ItemName="SharkSeeker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=6967771328",ItemType="Gun",Rarity="Victim"},
	["NERFGUN2"]={ItemName="Dartbringer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=8626617523",ItemType="Gun",Rarity="Victim"},
	["Nether"]={ItemName="Nether",Image="http://www.roblox.com/asset/?id=197657098",ItemType="Knife",Rarity="Rare"},
	["News"]={ItemName="News",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238546032",ItemType="Gun",Rarity="Common"},
	["NewShadowBlaster"]={ItemName="Prism",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10394185791",ItemType="Gun",Rarity="Common"},
	["Night"]={ItemName="Night",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=159971385",ItemType="Gun",Rarity="Uncommon"},
	["Nightblade"]={ItemName="Nightblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=475478854",ItemType="Knife",Rarity="Godly"},
	["NightFire"]={ItemName="Nightfire",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=4659626966",ItemType="Gun",Rarity="Rare"},
	["Nightmare2"]={ItemName="Nightmare",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14167384101",ItemType="Knife",Rarity="Dream"},
	["NightmareDemon2"]={ItemName="Nightmare Demon",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14299732622",ItemType="Knife",Rarity="Godly"},
	["Nik Scythe"]={ItemName="Nik's Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2599788159",ItemType="Knife",Rarity="Ancient"},
	["NikHarvester"]={ItemName="Nik's Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14838126994",ItemType="Gun",Rarity="Ancient"},
	["NikSC"]={ItemName="Nik's Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5412013108",ItemType="Knife",Rarity="Ancient"},
	["NiksHeat"]={ItemName="Nik's Heat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14838381513",ItemType="Knife",Rarity="Ancient"},
	["NiksLuger"]={ItemName="Nik's Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14838163440",ItemType="Gun",Rarity="Ancient"},
	["Nova"]={ItemName="Nova",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235371686",ItemType="Knife",Rarity="Rare"},
	["NuclearDemon"]={ItemName="Nuclear Demon",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13593261250",ItemType="Knife",Rarity="Dream"},
	["NuclearHammer"]={ItemName="Nuclear Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=4860572702",ItemType="Knife",Rarity="Godly"},
	["NukeHammer"]={ItemName="Nuke Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13673430296",ItemType="Knife",Rarity="Godly"},
	["Nutcracker"]={ItemName="Nutcracker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332497657",ItemType="Gun",Rarity="Uncommon"},
	["Nyan"]={ItemName="Nyan",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7030500492",ItemType="Knife",Rarity="Common"},
	["OBioBlade"]={ItemName="BioBlade",Image="http://www.roblox.com/asset/?id=6905653504",ItemType="Knife",Rarity="Godly"},
	["Oblivionvortex2"]={ItemName="Oblivion Vortex",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13024293178",ItemType="Knife",Rarity="Victim"},
	["OceanB"]={ItemName="Bronze Ocean",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13975614951",ItemType="Gun",Rarity="Godly"},
	["OceanBlade2aa"]={ItemName="Ocean Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14312407377",ItemType="Knife",Rarity="Godly"},
	["OceanG"]={ItemName="Ocean",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13957777452",ItemType="Gun",Rarity="Godly"},
	["OceanGold"]={ItemName="Gold Ocean",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13975646190",ItemType="Gun",Rarity="Godly"},
	["OceanGreen"]={ItemName="Green Ocean",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13976963260",ItemType="Gun",Rarity="Godly"},
	["OceanKing2"]={ItemName="Ocean King",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14312413510",ItemType="Knife",Rarity="Godly"},
	["OceanPink"]={ItemName="Pink Ocean",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13977011975",ItemType="Gun",Rarity="Godly"},
	["OceanPurple"]={ItemName="Purple Ocean",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13976992166",ItemType="Gun",Rarity="Godly"},
	["OceanRed"]={ItemName="Red Ocean",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13976977827",ItemType="Gun",Rarity="Godly"},
	["OceanS"]={ItemName="Silver Ocean",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13975622403",ItemType="Gun",Rarity="Godly"},
	["Oily"]={ItemName="Oily",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315501170",ItemType="Knife",Rarity="Common"},
	["OJ"]={ItemName="OJ",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10217288633",ItemType="Knife",Rarity="Common"},
	["Ollie"]={ItemName="Ollie",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=305504399",ItemType="Knife",Rarity="Common"},
	["OmegaLuger"]={ItemName="Omega Luger",Image="13784291631",ItemType="Gun",Rarity="Victim"},
	["OmegaSword"]={ItemName="Omega's Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=1392870183",ItemType="Knife",Rarity="Ancient"},
	["Orange Iceblaster"]={ItemName="Bronze Iceblaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6404167442",ItemType="Gun",Rarity="Victim"},
	["Orange Icebreaker"]={ItemName="Bronze Icebreaker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6788746249",ItemType="Knife",Rarity="Victim"},
	["OrangeBlizzard"]={ItemName="Orange Blizzard",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433448359",ItemType="Knife",Rarity="Common"},
	["OrangeHammer"]={ItemName="Orange Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433322335",ItemType="Knife",Rarity="Uncommon"},
	["OrangeHarvester"]={ItemName="Orange Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13529553759",ItemType="Gun",Rarity="Victim"},
	["OrangeMarble"]={ItemName="Orange Marble",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873011",ItemType="Knife",Rarity="Rare"},
	["OrangeSaber"]={ItemName="Orange Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10940496106",ItemType="Knife",Rarity="Ancient"},
	["OrangeSeer"]={ItemName="Orange Seer",Image="http://www.roblox.com/asset/?id=9826482073",ItemType="Knife",Rarity="Godly"},
	["OrangeUfo"]={ItemName="Orange UFO",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13074513741",ItemType="Knife",Rarity="Common"},
	["OrangeWaves"]={ItemName="Orange Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13553718681",ItemType="Knife",Rarity="Uncommon"},
	["Ornament1"]={ItemName="Ornament",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=331745428",ItemType="Knife",Rarity="Common"},
	["Ornament1Gun"]={ItemName="Ornament1",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332497144",ItemType="Gun",Rarity="Common"},
	["Ornament2"]={ItemName="Ornament2",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=331745341",ItemType="Knife",Rarity="Common"},
	["Ornament2Gun"]={ItemName="Ornament2",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332497550",ItemType="Gun",Rarity="Common"},
	["Ornaments"]={ItemName="Ornaments",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121853160",ItemType="Knife",Rarity="Common"},
	["Ouch"]={ItemName="Mortal Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9073017141",ItemType="Knife",Rarity="Victim"},
	["Ouch2"]={ItemName="Immortal Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2722410982",ItemType="Knife",Rarity="Victim"},
	["Overlord"]={ItemName="Overlord",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11584030246",ItemType="Knife",Rarity="Godly"},
	["Overseer"]={ItemName="Overseer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=175668680",ItemType="Gun",Rarity="Legendary"},
	["OverseerCrescendo"]={ItemName="Overseer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11558966309",ItemType="Knife",Rarity="Godly"},
	["OverseerKnife"]={ItemName="Overseer",Image="http://www.roblox.com/asset/?id=198458910",ItemType="Knife",Rarity="Legendary"},
	["paint"]={ItemName="Painting",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10034314734",ItemType="Knife",Rarity="Common"},
	["Paper"]={ItemName="Paper",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235366870",ItemType="Knife",Rarity="Uncommon"},
	["Passion"]={ItemName="Passion",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=363150334",ItemType="Knife",Rarity="Common"},
	["PassionG"]={ItemName="Passion",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12359256570",ItemType="Gun",Rarity="Common"},
	["PassionK"]={ItemName="Passion",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=363150334",ItemType="Knife",Rarity="Common"},
	["Patrick"]={ItemName="Patrick",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=383476085",ItemType="Knife",Rarity="Common"},
	["PatrickReal"]={ItemName="Patrick",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2927553361",ItemType="Knife",Rarity="Godly"},
	["PatrickSakura"]={ItemName="Patrick Sakura",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12814328958",ItemType="Knife",Rarity="Godly"},
	["PatricksHat"]={ItemName="Patrick's Hat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12741474131",ItemType="Knife",Rarity="Rare"},
	["PatrickSugar"]={ItemName="Patrick Sugar",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12815565364",ItemType="Gun",Rarity="Godly"},
	["Patriot2"]={ItemName="Patriot",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=3400461375",ItemType="Knife",Rarity="Godly"},
	["PClover"]={ItemName="Pink Clover",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12741337872",ItemType="Knife",Rarity="Common"},
	["Pea"]={ItemName="Pea",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238545971",ItemType="Gun",Rarity="Common"},
	["Pepper"]={ItemName="Brown",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473625645",ItemType="Knife",Rarity="Common"},
	["peternal"]={ItemName="Patriotic Eternal",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10126559405",ItemType="Knife",Rarity="Godly"},
	["Phantom"]={ItemName="Phantom",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11360307373",ItemType="Knife",Rarity="Godly"},
	["PhantomKNI"]={ItemName="Phantom",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10702868120",ItemType="Knife",Rarity="Common"},
	["Phaser"]={ItemName="Phaser",Image="http://www.roblox.com/asset/?id=144325423",ItemType="Gun",Rarity="Classic"},
	["Pine"]={ItemName="Pine",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11064538252",ItemType="Gun",Rarity="Common"},
	["PinkBlizzard"]={ItemName="Pink Blizzard",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433450655",ItemType="Knife",Rarity="Uncommon"},
	["PinkHammer"]={ItemName="Pink Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433319451",ItemType="Knife",Rarity="Uncommon"},
	["PinkRadioactive"]={ItemName="Pink Radioactive",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13651495913",ItemType="Knife",Rarity="Common"},
	["PinkSharkseeker"]={ItemName="Pink Sharkseeker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13072213373",ItemType="Gun",Rarity="Godly"},
	["PinkTech"]={ItemName="Pink Tech",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433212447",ItemType="Knife",Rarity="Uncommon"},
	["PinkUfo"]={ItemName="Pink UFO",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13074719267",ItemType="Knife",Rarity="Uncommon"},
	["PinkWavesK"]={ItemName="Pink Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13974001930",ItemType="Knife",Rarity="Godly"},
	["Piracy"]={ItemName="Pirate",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6696852109",ItemType="Gun",Rarity="Uncommon"},
	["Pixel"]={ItemName="Pixel",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365347166",ItemType="Knife",Rarity="Godly"},
	["Pixelated"]={ItemName="Pixelated",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11422256997",ItemType="Knife",Rarity="Godly"},
	["PizzaTides"]={ItemName="Pizza Tides",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11779357164",ItemType="Knife",Rarity="Godly"},
	["PKANSC"]={ItemName="Pkan's Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10759868369",ItemType="Knife",Rarity="Custom"},
	["PKANSC2"]={ItemName="Pkan's Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10759732983",ItemType="Gun",Rarity="Custom"},
	["PlanetKnife"]={ItemName="Planet",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12699721613",ItemType="Knife",Rarity="Godly"},
	["Plasmabeam"]={ItemName="Plasmabeam",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10169498421",ItemType="Gun",Rarity="Godly"},
	["Plasmablade"]={ItemName="Plasmablade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10169438381",ItemType="Knife",Rarity="Godly"},
	["Plasmite"]={ItemName="Plasmite",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=161369368",ItemType="Knife",Rarity="Legendary"},
	["plluger"]={ItemName="Purple Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2815862191",ItemType="Gun",Rarity="Godly"},
	["PLuger"]={ItemName="Pink Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12488705448",ItemType="Gun",Rarity="Godly"},
	["Plum"]={ItemName="Plum",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8597252439",ItemType="Knife",Rarity="Common"},
	["PoisonGalaxy"]={ItemName="Poison Galaxy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13138613066",ItemType="Knife",Rarity="Godly"},
	["PoisonGun"]={ItemName="Poisongun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11190423924",ItemType="Gun",Rarity="Uncommon"},
	["Poisonheat"]={ItemName="Poison Heat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10512700279",ItemType="Knife",Rarity="Godly"},
	["PoisonVamp"]={ItemName="Poison Vamp",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13684816104",ItemType="Knife",Rarity="Ancient"},
	["Pole"]={ItemName="Pole",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2741786863",ItemType="Knife",Rarity="Godly"},
	["Poltergeist2"]={ItemName="Poltergeist",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13791416102",ItemType="Gun",Rarity="Ancient"},
	["pool"]={ItemName="Pool",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10034310197",ItemType="Knife",Rarity="Common"},
	["PoolNoodle"]={ItemName="Pool Noodle",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14166199101",ItemType="Knife",Rarity="Uncommon"},
	["Popsicle2"]={ItemName="Popsicle",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14166205990",ItemType="Knife",Rarity="Uncommon"},
	["Popsicle2aa"]={ItemName="Popsicle",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14266982462",ItemType="Gun",Rarity="Godly"},
	["PopsicleKnife"]={ItemName="Popsicle",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13849688952",ItemType="Knife",Rarity="Uncommon"},
	["Portal"]={ItemName="Portal",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12646783826",ItemType="Knife",Rarity="Godly"},
	["portalkni"]={ItemName="Portal",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5866444722",ItemType="Knife",Rarity="Rare"},
	["PortalKnife"]={ItemName="Portal",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5866444722",ItemType="Knife",Rarity="Rare"},
	["Possessed"]={ItemName="Possessed",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11452816916",ItemType="Knife",Rarity="Godly"},
	["potion"]={ItemName="Potion",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10938242481",ItemType="Gun",Rarity="Uncommon"},
	["potionk"]={ItemName="Potion",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11227103555",ItemType="Knife",Rarity="Uncommon"},
	["PotionKNI"]={ItemName="Potion",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10702875913",ItemType="Knife",Rarity="Uncommon"},
	["Predator"]={ItemName="Predator",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203810176",ItemType="Gun",Rarity="Legendary"},
	["PredatorKnife"]={ItemName="Predator",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235372015",ItemType="Knife",Rarity="Legendary"},
	["Premicer"]={ItemName="Premicer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14512949426",ItemType="Gun",Rarity="Christmas"},
	["Present"]={ItemName="Present",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6676488487",ItemType="Knife",Rarity="Common"},
	["Presher"]={ItemName="Presher",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=14513004059",ItemType="Knife",Rarity="Christmas"},
	["presxkndf"]={ItemName="Pres Knife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12816928505",ItemType="Knife",Rarity="Dream"},
	["presxsug"]={ItemName="Pres Sugar",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetid=12797861161",ItemType="Gun",Rarity="Ancient"},
	["Prism"]={ItemName="Prism",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=306046703",ItemType="Knife",Rarity="Common"},
	["PrisMatic"]={ItemName="Prismatic",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7266436015",ItemType="Knife",Rarity="Godly"},
	["Prop"]={ItemName="Pizza",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=602146440",ItemType="Knife",Rarity="Godly"},
	["Pum"]={ItemName="Pumpking",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5868274299",ItemType="Knife",Rarity="Godly"},
	["pumpkinkni"]={ItemName="Pumpkin",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5872490600",ItemType="Knife",Rarity="Uncommon"},
	["PumpkinKnife2020"]={ItemName="Pumpkin",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5872490600",ItemType="Knife",Rarity="Uncommon"},
	["PumpkinPatch19"]={ItemName="Pumpkin Patch",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7192751463",ItemType="Knife",Rarity="Common"},
	["PumpSaber"]={ItemName="Pumpkin Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11169065628",ItemType="Knife",Rarity="Godly"},
	["PurpleAlien2"]={ItemName="Purple Alien",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433623238",ItemType="Knife",Rarity="Rare"},
	["PurpleBlade"]={ItemName="Purple Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154587086",ItemType="Knife",Rarity="Godly"},
	["PurpleBlizzard"]={ItemName="Purple Blizzard",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433456487",ItemType="Knife",Rarity="Uncommon"},
	["PurpleHallowGun"]={ItemName="Purple Hallow Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13072096700",ItemType="Gun",Rarity="Godly"},
	["PurpleL"]={ItemName="Purple Laser",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2777369743",ItemType="Gun",Rarity="Godly"},
	["PurpleLaser"]={ItemName="Purple Laser",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=4919562212",ItemType="Gun",Rarity="Godly"},
	["PurpleLuger"]={ItemName="Purple Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13389365115",ItemType="Gun",Rarity="Godly"},
	["PurpleRadioactive"]={ItemName="Purple Radioactive",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13651502278",ItemType="Knife",Rarity="Uncommon"},
	["PurpleSaber"]={ItemName="Purple Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10940507286",ItemType="Knife",Rarity="Ancient"},
	["PurpleSeer"]={ItemName="Purple Seer",Image="http://www.roblox.com/asset/?id=7215615855",ItemType="Knife",Rarity="Godly"},
	["PurpleUfo"]={ItemName="Purple UFO",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13074723227",ItemType="Knife",Rarity="Uncommon"},
	["PurpleVampireEdge"]={ItemName="Purple Vampire's Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13072090239",ItemType="Knife",Rarity="Godly"},
	["PurpleWaves"]={ItemName="Purple Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13553057090",ItemType="Knife",Rarity="Common"},
	["PurpleWavez2"]={ItemName="Purple Watcher",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14299697341",ItemType="Knife",Rarity="Godly"},
	["PWaves"]={ItemName="Purple Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12671238992",ItemType="Knife",Rarity="Ancient"},
	["PWavesK"]={ItemName="Purple Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13977889195",ItemType="Knife",Rarity="Godly"},
	["Quartz"]={ItemName="Quartz",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12881530128",ItemType="Knife",Rarity="Common"},
	["QuatRevolver"]={ItemName="Quatuan's  Revolver",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12755571323",ItemType="Gun",Rarity="Ancient"},
	["QuatScythe"]={ItemName="Quatuan's  Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12755552687",ItemType="Knife",Rarity="Ancient"},
	["Radioactive2"]={ItemName="Radioactive",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13651477543",ItemType="Knife",Rarity="Common"},
	["Rainbow"]={ItemName="Rainbow",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=159747377",ItemType="Knife",Rarity="Rare"},
	["RainbowBlade"]={ItemName="Rainbow Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12661198026",ItemType="Knife",Rarity="Ancient"},
	["RainbowBlade2"]={ItemName="Rainbow Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=1363425037",ItemType="Knife",Rarity="Godly"},
	["RainbowFlames"]={ItemName="Rainbow Flames",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11410631476",ItemType="Knife",Rarity="Victim"},
	["RainbowGold"]={ItemName="Rainbow Gold",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12741452635",ItemType="Knife",Rarity="Rare"},
	["RainbowGun"]={ItemName="Rainbow Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13007087116",ItemType="Gun",Rarity="Godly"},
	["RainbowGUN"]={ItemName="Rainbow",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6696853417",ItemType="Gun",Rarity="Rare"},
	["RainbowHammer"]={ItemName="Rainbow Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13430331796",ItemType="Knife",Rarity="Godly"},
	["RainbowHeat"]={ItemName="Heat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11544924901",ItemType="Knife",Rarity="Godly"},
	["RainbowKnife"]={ItemName="Rainbow",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13007075807",ItemType="Knife",Rarity="Godly"},
	["RainbowLaseraa"]={ItemName="Rainbow Laser",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14299673851",ItemType="Gun",Rarity="Godly"},
	["RainbowSaber"]={ItemName="Rainbow Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10940480878",ItemType="Knife",Rarity="Godly"},
	["RainbowSeer"]={ItemName="Rainbow Seer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11422386373",ItemType="Knife",Rarity="Godly"},
	["RainbowWaves"]={ItemName="Rainbow Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13553777405",ItemType="Knife",Rarity="Godly"},
	["RayGun2"]={ItemName="Ray Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12700154850",ItemType="Gun",Rarity="Godly"},
	["RayGun3"]={ItemName="Ray Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12700154850",ItemType="Gun",Rarity="Godly"},
	["RBioBlade"]={ItemName="BioBlade",Image="http://www.roblox.com/asset/?id=6905647347",ItemType="Knife",Rarity="Godly"},
	["RClover"]={ItemName="Red Clover",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12741351590",ItemType="Knife",Rarity="Common"},
	["Reaver1"]={ItemName="Reaver",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11008627340",ItemType="Knife",Rarity="Rare"},
	["Reaver12"]={ItemName="Reaver",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11008630085",ItemType="Knife",Rarity="Legendary"},
	["Reaver2"]={ItemName="Reaver",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11008624647",ItemType="Knife",Rarity="Godly"},
	["Reaver3"]={ItemName="Reaver",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7864256669",ItemType="Knife",Rarity="Ancient"},
	["Reaveraaa"]={ItemName="Reaver",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7864256669",ItemType="Knife",Rarity="Ancient"},
	["RedBat"]={ItemName="Red Bat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11497119924",ItemType="Knife",Rarity="Custom"},
	["RedBlaster"]={ItemName="Red Iceblaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6731029978",ItemType="Gun",Rarity="Victim"},
	["RedBreaker"]={ItemName="Red Icebreaker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6731029458",ItemType="Knife",Rarity="Victim"},
	["RedEdge"]={ItemName="Red Hallow",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9561291606",ItemType="Knife",Rarity="Victim"},
	["RedGalaxy"]={ItemName="Red Galaxy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12701085002",ItemType="Knife",Rarity="Godly"},
	["RedGalaxyGun"]={ItemName="Red Galaxy Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12701086577",ItemType="Gun",Rarity="Godly"},
	["RedIceCrusher"]={ItemName="Icecrusher",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14686905493",ItemType="Knife",Rarity="Victim"},
	["RedIcePiercer"]={ItemName="Icepiercer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14686928562",ItemType="Gun",Rarity="Victim"},
	["RedLuger"]={ItemName="Red Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=1005425810",ItemType="Gun",Rarity="Godly"},
	["RedMarble"]={ItemName="Red Marble",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11189599040",ItemType="Knife",Rarity="Legendary"},
	["RedRadioactive"]={ItemName="Red Radioactive",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13651498650",ItemType="Knife",Rarity="Common"},
	["RedSaber"]={ItemName="Red Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10940501301",ItemType="Knife",Rarity="Ancient"},
	["RedSeer"]={ItemName="Red Seer",Image="http://www.roblox.com/asset/?id=6484307015",ItemType="Knife",Rarity="Godly"},
	["RedTech"]={ItemName="Red Tech",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433178836",ItemType="Knife",Rarity="Common"},
	["RedUfo"]={ItemName="Red UFO",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13074538846",ItemType="Knife",Rarity="Legendary"},
	["Reptile"]={ItemName="Reptile",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=162672131",ItemType="Knife",Rarity="Common"},
	["Rhavi"]={ItemName="Rhavi's Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12565129403",ItemType="Gun",Rarity="Ancient"},
	["RhaviL"]={ItemName="Rhavi's Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12565177265",ItemType="Gun",Rarity="Ancient"},
	["RhavisPhone"]={ItemName="Rhavi's Valk Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13790668162",ItemType="Gun",Rarity="Victim"},
	["Rick"]={ItemName="Never Gonna",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7030500492",ItemType="Knife",Rarity="Godly"},
	["Rings2"]={ItemName="Rings",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=12877357742",ItemType="Knife",Rarity="Common"},
	["RIP"]={ItemName="RIP",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11230948259",ItemType="Gun",Rarity="Common"},
	["Ripper"]={ItemName="Ripper",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5866460591",ItemType="Gun",Rarity="Legendary"},
	["RipperG"]={ItemName="Ripper",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5866460591",ItemType="Gun",Rarity="Legendary"},
	["RocketKnife"]={ItemName="Rocket",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12699606210",ItemType="Knife",Rarity="Legendary"},
	["RoseG"]={ItemName="Roses",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12359258015",ItemType="Gun",Rarity="Common"},
	["Roses"]={ItemName="Roses",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=363352002",ItemType="Knife",Rarity="Common"},
	["RosesG"]={ItemName="Roses",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12363809617",ItemType="Gun",Rarity="Legendary"},
	["RosesK"]={ItemName="Roses",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=363352002",ItemType="Knife",Rarity="Common"},
	["RSparkle"]={ItemName="Rainbow Sparkle",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12634697340",ItemType="Gun",Rarity="Ancient"},
	["Rubyblade"]={ItemName="Rubyblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11475243550",ItemType="Knife",Rarity="Godly"},
	["RubyLaser"]={ItemName="Ruby",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11556068487",ItemType="Gun",Rarity="Godly"},
	["Runey"]={ItemName="Rune",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6696853759",ItemType="Knife",Rarity="Legendary"},
	["RWavesK"]={ItemName="Red Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13973954470",ItemType="Knife",Rarity="Godly"},
	["Saber"]={ItemName="Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10716480011",ItemType="Knife",Rarity="Godly"},
	["SakuraK"]={ItemName="Sakura",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12363690089",ItemType="Knife",Rarity="Godly"},
	["SandKnife"]={ItemName="Sand",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13849661785",ItemType="Knife",Rarity="Common"},
	["Sandy"]={ItemName="Sandy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365568056",ItemType="Knife",Rarity="Common"},
	["Santa"]={ItemName="Santa",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=331746096",ItemType="Knife",Rarity="Common"},
	["Santa2"]={ItemName="Santa",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2669637780",ItemType="Knife",Rarity="Common"},
	["Santa3"]={ItemName="Santa",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6676487881",ItemType="Knife",Rarity="Common"},
	["SantaGun"]={ItemName="Santa",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332496861",ItemType="Gun",Rarity="Common"},
	["SapphireLaser"]={ItemName="Sapphire",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11556056397",ItemType="Gun",Rarity="Godly"},
	["SapphireSunsetHammer"]={ItemName="Sapphire Sunset Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433843387",ItemType="Knife",Rarity="Rare"},
	["Sat"]={ItemName="Saturn",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10034640392",ItemType="Knife",Rarity="Rare"},
	["Sausage"]={ItemName="Sausage",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9094238093",ItemType="Gun",Rarity="Common"},
	["Saw"]={ItemName="Saw",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=3187397991",ItemType="Knife",Rarity="Godly"},
	["SBlasterNEW"]={ItemName="Glitch 6",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10265115066",ItemType="Gun",Rarity="Common"},
	["Scarlet"]={ItemName="Scarlet",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8597318560",ItemType="Knife",Rarity="Rare"},
	["SClockwork"]={ItemName="Spacework",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11504144672",ItemType="Knife",Rarity="Godly"},
	["Scramble"]={ItemName="Scrambler",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9388105291",ItemType="Knife",Rarity="Godly"},
	["Scratch"]={ItemName="Scratch",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873371",ItemType="Knife",Rarity="Legendary"},
	["Scratch3"]={ItemName="Scratch",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11190366482",ItemType="Knife",Rarity="Legendary"},
	["Scream"]={ItemName="Scream",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13568187209",ItemType="Knife",Rarity="Dream"},
	["ScribbleGun"]={ItemName="Scribble Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12957227425",ItemType="Gun",Rarity="Uncommon"},
	["ScribbleKnife"]={ItemName="Scribble Knife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12957185656",ItemType="Knife",Rarity="Common"},
	["seagod"]={ItemName="Poseidon",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10034503628",ItemType="Knife",Rarity="Godly"},
	["SeaMonster2"]={ItemName="Sea Monster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14166883074",ItemType="Knife",Rarity="Godly"},
	["Seeker2"]={ItemName="Seeker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=",ItemType="Knife",Rarity="Dream"},
	["SElderGun"]={ItemName="Silver Elderwood",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11205483342",ItemType="Gun",Rarity="Victim"},
	["ShadedKNI"]={ItemName="Shaded",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=4659636085",ItemType="Knife",Rarity="Common"},
	["Shadow1"]={ItemName="Glitch 4",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8578155859",ItemType="Knife",Rarity="Common"},
	["ShadowBreaker"]={ItemName="Shadow Breaker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12884437060",ItemType="Knife",Rarity="Ancient"},
	["ShadowKnife"]={ItemName="Shadow",Image="http://www.roblox.com/asset/?id=144070096",ItemType="Knife",Rarity="Classic"},
	["ShadowsBlade"]={ItemName="Glitch 7",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10265100997",ItemType="Knife",Rarity="Common"},
	["Shark"]={ItemName="Shark",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=3187421705",ItemType="Gun",Rarity="Godly"},
	["SHarv"]={ItemName="Silver Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8550592316",ItemType="Gun",Rarity="Victim"},
	["Shiny"]={ItemName="Shiny",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8472449443",ItemType="Knife",Rarity="Legendary"},
	["ShinyHeat"]={ItemName="Shiny Heat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11503917186",ItemType="Knife",Rarity="Godly"},
	["Sidewinder"]={ItemName="Sidewinder",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=305503783",ItemType="Knife",Rarity="Common"},
	["SilentNight"]={ItemName="Silent Night",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121862034",ItemType="Gun",Rarity="Rare"},
	["SilentNightGun"]={ItemName="Silent Night",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121862034&bust=7810",ItemType="Gun",Rarity="Rare"},
	["Silver Iceblaster"]={ItemName="Silver Iceblaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6404166698",ItemType="Gun",Rarity="Victim"},
	["Silver Icebreaker"]={ItemName="Silver Icebreaker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6404126280",ItemType="Knife",Rarity="Victim"},
	["SilverBat"]={ItemName="Silver Bat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11497128209",ItemType="Knife",Rarity="Custom"},
	["SilverCandy"]={ItemName="Silver Candy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8563223017",ItemType="Knife",Rarity="Victim"},
	["SilverEdge"]={ItemName="Silver Hallow",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9561290297",ItemType="Knife",Rarity="Victim"},
	["SilverElderblade"]={ItemName="Silver Elderwood",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11529188165",ItemType="Knife",Rarity="Victim"},
	["SilverGun"]={ItemName="Silver Swirly",Image="http://www.roblox.com/asset/?id=9029804219",ItemType="Gun",Rarity="Victim"},
	["SilverIceCrusher"]={ItemName="Icecrusher",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14686898544",ItemType="Knife",Rarity="Victim"},
	["SilverIcePiercer"]={ItemName="Icepiercer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14686916599",ItemType="Gun",Rarity="Victim"},
	["SilverLogchopper"]={ItemName="Silver Logchopper",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12670865176",ItemType="Knife",Rarity="Ancient"},
	["SilverMinty"]={ItemName="Silver Minty",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12671093770",ItemType="Gun",Rarity="Victim"},
	["SilverSummerBlade"]={ItemName="Silver Summer Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14710426656",ItemType="Knife",Rarity="Victim"},
	["SilverSummerSwirl"]={ItemName="Silver Summer Swirl",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14685942740",ItemType="Knife",Rarity="Godly"},
	["SilverSwirlyAxe"]={ItemName="Silver Swirly",Image="http://www.roblox.com/asset/?id=9029802005",ItemType="Knife",Rarity="Victim"},
	["SilverWaves"]={ItemName="Silver Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13553763991",ItemType="Knife",Rarity="Rare"},
	["SinisterGun"]={ItemName="Sinister",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11459564267",ItemType="Gun",Rarity="Rare"},
	["SinisterKnife"]={ItemName="Sinister",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11459558475",ItemType="Knife",Rarity="Rare"},
	["SkeleBlade"]={ItemName="Skeleblade",Image="http://www.roblox.com/asset/?id=9319682046",ItemType="Knife",Rarity="Godly"},
	["Skeleton"]={ItemName="Skeleton Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11134944613",ItemType="Knife",Rarity="Godly"},
	["Sketch"]={ItemName="Sketch",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203808108",ItemType="Gun",Rarity="Uncommon"},
	["SketchYT"]={ItemName="Sketchy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=546161470",ItemType="Knife",Rarity="Common"},
	["Skool"]={ItemName="Skool",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=295269977",ItemType="Knife",Rarity="Common"},
	["skulls"]={ItemName="Skulls",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11230832710",ItemType="Knife",Rarity="Uncommon"},
	["Skulls19"]={ItemName="Skulls",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7192747470",ItemType="Knife",Rarity="Legendary"},
	["Slasher"]={ItemName="Slasher",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=3187398274",ItemType="Knife",Rarity="Godly"},
	["Slate"]={ItemName="Slate",Image="http://www.roblox.com/asset/?id=198453556",ItemType="Knife",Rarity="Common"},
	["Slime"]={ItemName="Slime",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10935533920",ItemType="Gun",Rarity="Common"},
	["slime"]={ItemName="Slime",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11227124502",ItemType="Knife",Rarity="Common"},
	["Slimy19"]={ItemName="Slimy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7192747184",ItemType="Knife",Rarity="Common"},
	["snakebite"]={ItemName="Snakebite",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11230746468",ItemType="Knife",Rarity="Rare"},
	["SnakeBite19"]={ItemName="SnakeBite",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7192766339",ItemType="Gun",Rarity="Rare"},
	["Sniper"]={ItemName="Sniper",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7112852156",ItemType="Gun",Rarity="Dream"},
	["Snoop"]={ItemName="Red",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473626150",ItemType="Knife",Rarity="Uncommon"},
	["Snow"]={ItemName="Galaxy's Chill",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9282625986",ItemType="Knife",Rarity="Ancient"},
	["Snowfalkes"]={ItemName="Snowflakes",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6123338102",ItemType="Knife",Rarity="Rare"},
	["Snowflake"]={ItemName="Snowflake",Image="http://www.roblox.com/asset/?id=8203481928",ItemType="Knife",Rarity="Godly"},
	["Snowflakes"]={ItemName="Snowflakes",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11064533113",ItemType="Knife",Rarity="Common"},
	["SnowGun"]={ItemName="Snowflake",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2669786515",ItemType="Gun",Rarity="Uncommon"},
	["Snowman"]={ItemName="Snowman",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=331745799",ItemType="Knife",Rarity="Uncommon"},
	["SnowMan"]={ItemName="Snowman",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10684691235",ItemType="Knife",Rarity="Uncommon"},
	["Snowman2"]={ItemName="Snowman",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433397974",ItemType="Knife",Rarity="Legendary"},
	["SnowmanGun"]={ItemName="Snowman",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332497603",ItemType="Gun",Rarity="Uncommon"},
	["SnowmanKNI"]={ItemName="Snowman",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2669640152",ItemType="Knife",Rarity="Common"},
	["Snowy"]={ItemName="Snowy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332011125",ItemType="Knife",Rarity="Uncommon"},
	["Snowy2"]={ItemName="Snowy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6676489522",ItemType="Knife",Rarity="Rare"},
	["Solarblade"]={ItemName="Solar",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2920327411",ItemType="Knife",Rarity="Godly"},
	["SolarGun"]={ItemName="Solar",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12699722757",ItemType="Gun",Rarity="Godly"},
	["Sorry"]={ItemName="Corrupt",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=197879343",ItemType="Knife",Rarity="Victim"},
	["SoulGlory"]={ItemName="Soul Glory",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13791408108",ItemType="Knife",Rarity="Ancient"},
	["SoulSaber"]={ItemName="Soul Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13777579617",ItemType="Knife",Rarity="Ancient"},
	["Space"]={ItemName="Space",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2889475004",ItemType="Knife",Rarity="Rare"},
	["Space22"]={ItemName="Space",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11521284513",ItemType="Knife",Rarity="Legendary"},
	["Space_Saber"]={ItemName="Galaxy Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10717013499",ItemType="Knife",Rarity="Godly"},
	["Space_SaberM"]={ItemName="Space Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10833217002",ItemType="Knife",Rarity="Godly"},
	["SpaceAxe"]={ItemName="Space Axe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11503691791",ItemType="Knife",Rarity="Godly"},
	["SpaceDestroyer"]={ItemName="Space Destroyer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13153729505",ItemType="Knife",Rarity="Dream"},
	["SpaceDestroyerBlue"]={ItemName="Space Destroyer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13174572505",ItemType="Knife",Rarity="Victim"},
	["SpaceDestroyerBronze"]={ItemName="Space Destroyer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13172461740",ItemType="Knife",Rarity="Victim"},
	["SpaceDestroyerGold"]={ItemName="Space Destroyer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13172432181",ItemType="Knife",Rarity="Victim"},
	["SpaceDestroyerSilver"]={ItemName="Space Destroyer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13172460727",ItemType="Knife",Rarity="Victim"},
	["SpaceDestroyerTeal"]={ItemName="Space Destroyer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13174758947",ItemType="Knife",Rarity="Victim"},
	["SpaceEdge"]={ItemName="Space's Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11503583441",ItemType="Knife",Rarity="Godly"},
	["SpaceElderWoodGun"]={ItemName="Space Elderwood Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154549959",ItemType="Gun",Rarity="Godly"},
	["SpaceElderWoodScythe"]={ItemName="Space Elderwood Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154545961",ItemType="Knife",Rarity="Godly"},
	["SpaceFederation"]={ItemName="Space Federation",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154558389",ItemType="Knife",Rarity="Godly"},
	["SpaceHeat2"]={ItemName="Heated Space",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11504553734",ItemType="Knife",Rarity="Godly"},
	["SpaceIcebreaker"]={ItemName="Space Icebreaker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13155467699",ItemType="Knife",Rarity="Godly"},
	["SpaceKing"]={ItemName="Space King",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9063876898",ItemType="Knife",Rarity="Victim"},
	["SpaceKinga"]={ItemName="Space King",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154574795",ItemType="Knife",Rarity="Godly"},
	["Spaceplasmabeam"]={ItemName="Spacebeam",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11503552319",ItemType="Gun",Rarity="Godly"},
	["Spaceplasmablade"]={ItemName="Spaceblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11503521251",ItemType="Knife",Rarity="Godly"},
	["SpaceSaber"]={ItemName="Space Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12543918880",ItemType="Knife",Rarity="Godly"},
	["Spaceship"]={ItemName="Spaceship",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=12877368633",ItemType="Knife",Rarity="Uncommon"},
	["Spaceship2a"]={ItemName="Space Ship",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=12877362335",ItemType="Knife",Rarity="Rare"},
	["SpaceSpider"]={ItemName="Space Spider",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154554048",ItemType="Knife",Rarity="Godly"},
	["Spaceswirl"]={ItemName="Spaceswirl",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11503602195",ItemType="Knife",Rarity="Ancient"},
	["SpaceTrident"]={ItemName="Space Trident",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154555854",ItemType="Knife",Rarity="Godly"},
	["SpaceVC"]={ItemName="Crystal Volcano",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11086678796",ItemType="Knife",Rarity="Godly"},
	["SpaceVirtual"]={ItemName="Space Virtual",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11520737635",ItemType="Knife",Rarity="Godly"},
	["SpaceWalk"]={ItemName="Spacewalker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9856362330",ItemType="Knife",Rarity="Godly"},
	["sparke"]={ItemName="Sparkle",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203869110",ItemType="Gun",Rarity="Legendary"},
	["Sparkle"]={ItemName="Sparkle",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203869110",ItemType="Gun",Rarity="Legendary"},
	["Spectral"]={ItemName="Spectral",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10469649533",ItemType="Gun",Rarity="Legendary"},
	["spectral"]={ItemName="Spectral",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11227048980",ItemType="Knife",Rarity="Legendary"},
	["Spectre"]={ItemName="Spectre",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11360305428",ItemType="Gun",Rarity="Godly"},
	["Spectrum"]={ItemName="Spectrum",Image="http://www.roblox.com/asset/?id=198458862",ItemType="Knife",Rarity="Rare"},
	["Spider"]={ItemName="Spider",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315120760",ItemType="Knife",Rarity="Godly"},
	["Spine"]={ItemName="Spine",Image="http://www.roblox.com/asset/?id=9096460806",ItemType="Knife",Rarity="Godly"},
	["Spitfire"]={ItemName="Spitfire",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=159971321",ItemType="Gun",Rarity="Rare"},
	["Splash"]={ItemName="Splash",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235371439",ItemType="Knife",Rarity="Legendary"},
	["SplashGun"]={ItemName="Splash",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=4659626370",ItemType="Gun",Rarity="Legendary"},
	["Splatter"]={ItemName="Splatter",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=159432647",ItemType="Knife",Rarity="Common"},
	["SpongeaaaBobPop2aa"]={ItemName="SpongeBob Popsicle",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13850638195",ItemType="Knife",Rarity="Victim"},
	["SpongeBobPop"]={ItemName="SpongeBob Pop",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13157421088",ItemType="Knife",Rarity="Ancient"},
	["SpookyScythe"]={ItemName="Spooky Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11125585699",ItemType="Knife",Rarity="Godly"},
	["SpringHex"]={ItemName="Spring Hex",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13009648727",ItemType="Knife",Rarity="Ancient"},
	["SpringNature"]={ItemName="Spring Nature",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12684643096",ItemType="Gun",Rarity="Rare"},
	["SpringParadise"]={ItemName="Spring Paradise",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12684602292",ItemType="Knife",Rarity="Rare"},
	["SpringSlash"]={ItemName="Spring Slashing",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9324551219",ItemType="Knife",Rarity="Godly"},
	["Squire"]={ItemName="Squire",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315501560",ItemType="Knife",Rarity="Rare"},
	["ss"]={ItemName="Summer Slashing",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10022284919",ItemType="Knife",Rarity="Godly"},
	["SSaber"]={ItemName="Space Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10833217002",ItemType="Knife",Rarity="Godly"},
	["StaffScythe"]={ItemName="Staff Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14276069183",ItemType="Knife",Rarity="Dream"},
	["Stainless"]={ItemName="Stainless",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235366771",ItemType="Knife",Rarity="Common"},
	["Stalker"]={ItemName="Stalker",Image="http://www.roblox.com/asset/?id=198455980",ItemType="Knife",Rarity="Uncommon"},
	["Star"]={ItemName="Star",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203807904",ItemType="Gun",Rarity="Common"},
	["StarDarkbringer"]={ItemName="Star Darkbringer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12881965841",ItemType="Gun",Rarity="Godly"},
	["StarHex"]={ItemName="Star Hex",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13036248251",ItemType="Knife",Rarity="Ancient"},
	["StarIcebreaker"]={ItemName="Star Iceblaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12815050226",ItemType="Knife",Rarity="Victim"},
	["StarKarambit"]={ItemName="Star Karambit",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12814324109",ItemType="Knife",Rarity="Ancient"},
	["Starlight"]={ItemName="Starlight",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10940418932",ItemType="Knife",Rarity="Godly"},
	["Starry"]={ItemName="Starry",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10684694784",ItemType="Knife",Rarity="Rare"},
	["StarryKnife"]={ItemName="Starry",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12699583543",ItemType="Knife",Rarity="Uncommon"},
	["StarsKnife"]={ItemName="Stars",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12699582474",ItemType="Knife",Rarity="Common"},
	["Static"]={ItemName="Static",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365568163",ItemType="Knife",Rarity="Common"},
	["StHarv"]={ItemName="Starry Green Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12741802273",ItemType="Gun",Rarity="Ancient"},
	["Stickers"]={ItemName="Stickers",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10469644480",ItemType="Knife",Rarity="Common"},
	["Stickers2"]={ItemName="Stickers",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10684689530",ItemType="Gun",Rarity="Common"},
	["Stickers22"]={ItemName="Stickers",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11361640359",ItemType="Knife",Rarity="Common"},
	["stickersg"]={ItemName="Stickers",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11230712441",ItemType="Gun",Rarity="Common"},
	["Stockings"]={ItemName="Stockings",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6123335682",ItemType="Knife",Rarity="Common"},
	["Strawberry"]={ItemName="Strawberry",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8597251868",ItemType="Knife",Rarity="Common"},
	["StrawberryKnife"]={ItemName="Strawberry Knife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12815080618",ItemType="Knife",Rarity="Victim"},
	["Sub"]={ItemName="Sub",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=546159250",ItemType="Knife",Rarity="Common"},
	["Subspace"]={ItemName="Space Blaster",Image="http://www.roblox.com/asset/?id=10716371424",ItemType="Gun",Rarity="Ancient"},
	["subspace"]={ItemName="Subspace Tripmine",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11532479761",ItemType="Knife",Rarity="Custom"},
	["Sugar"]={ItemName="Sugar",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10393984652",ItemType="Gun",Rarity="Godly"},
	["summer"]={ItemName="Summer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10034320549",ItemType="Knife",Rarity="Rare"},
	["summer2"]={ItemName="Summer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10034371897",ItemType="Gun",Rarity="Rare"},
	["Summerbringer"]={ItemName="Summer Bringer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13849875024",ItemType="Gun",Rarity="Godly"},
	["SummerFederation"]={ItemName="Summer Federation",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14266636424",ItemType="Knife",Rarity="Godly"},
	["SummerKinga"]={ItemName="Summer King",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13850044588",ItemType="Knife",Rarity="Ancient"},
	["SummerPhaser"]={ItemName="Summer Phaser",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14266791476",ItemType="Gun",Rarity="Godly"},
	["SummerRay2a"]={ItemName="Summer Ray",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14312371922",ItemType="Gun",Rarity="Godly"},
	["SummerScythe2"]={ItemName="Summer Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13849881919",ItemType="Knife",Rarity="Ancient"},
	["SummersEnd"]={ItemName="Summer's End",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14318885358",ItemType="Knife",Rarity="Godly"},
	["Summersmasher"]={ItemName="Summer Smasher",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13849804186",ItemType="Knife",Rarity="Victim"},
	["SummerSpider2a"]={ItemName="Summer Spider",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14325255969",ItemType="Knife",Rarity="Godly"},
	["SummerStickers"]={ItemName="Stickers",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14166208880",ItemType="Knife",Rarity="Common"},
	["SummerStickersGun"]={ItemName="Stickers",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14166273613",ItemType="Gun",Rarity="Common"},
	["SummersVoid2a"]={ItemName="Summer's Void",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14325239580",ItemType="Knife",Rarity="Godly"},
	["SummerSwirl"]={ItemName="Summer Swirl",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14685933498",ItemType="Knife",Rarity="Godly"},
	["SummerToy"]={ItemName="Toy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14166228499",ItemType="Knife",Rarity="Common"},
	["SummerToyGun"]={ItemName="Toy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14166270563",ItemType="Gun",Rarity="Common"},
	["SummerVampire"]={ItemName="Summer Vampire",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14312385946",ItemType="Knife",Rarity="Godly"},
	["SummerWing"]={ItemName="Summer Wing",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13851878306",ItemType="Knife",Rarity="Godly"},
	["SummerWing2a"]={ItemName="Summer Wing",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13849829699",ItemType="Knife",Rarity="Ancient"},
	["SunflowerG"]={ItemName="Sunflower Sugar",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12684583108",ItemType="Gun",Rarity="Uncommon"},
	["SunflowerK"]={ItemName="Sunflower",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12684556534",ItemType="Knife",Rarity="Uncommon"},
	["SunglassesKnife"]={ItemName="Sunglasses",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13849670606",ItemType="Knife",Rarity="Common"},
	["SunHammer2a"]={ItemName="Sun Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13557647027",ItemType="Knife",Rarity="Victim"},
	["SunLeafSlasher"]={ItemName="Sunleaf Slasher",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14606261071",ItemType="Knife",Rarity="Godly"},
	["SunsetGun"]={ItemName="Sunset",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14166267867",ItemType="Gun",Rarity="Rare"},
	["SunsetKnife"]={ItemName="Sunset",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13849743307",ItemType="Knife",Rarity="Legendary"},
	["SuperNova"]={ItemName="Galaxy's Core",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9529556770",ItemType="Knife",Rarity="Ancient"},
	["Superstar"]={ItemName="Superstar",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2889472412",ItemType="Knife",Rarity="Rare"},
	["sVampire"]={ItemName="Silver Vamp's Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11204998725",ItemType="Knife",Rarity="Victim"},
	["SWavesK"]={ItemName="Silver Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13973926984",ItemType="Knife",Rarity="Godly"},
	["Sweater"]={ItemName="Sweater",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6676489014",ItemType="Knife",Rarity="Uncommon"},
	["SweaterGun"]={ItemName="Sweater",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2669787088",ItemType="Gun",Rarity="Uncommon"},
	["Sweetheart"]={ItemName="Sweetheart",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=363150761",ItemType="Knife",Rarity="Uncommon"},
	["SweetheartG"]={ItemName="Sweetheart",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12359261717",ItemType="Gun",Rarity="Rare"},
	["SweetheartK"]={ItemName="Sweetheart",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=363150761",ItemType="Knife",Rarity="Uncommon"},
	["Swirl"]={ItemName="Swirly Axe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8304801000",ItemType="Knife",Rarity="Ancient"},
	["SwirlGun"]={ItemName="Glitch",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8578155859",ItemType="Knife",Rarity="Common"},
	["Swirly Axe"]={ItemName="Swirly Axe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9629152607",ItemType="Knife",Rarity="Ancient"},
	["SwirlyBlade"]={ItemName="Swirlyblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9748729537",ItemType="Knife",Rarity="Godly"},
	["SwirlyGun"]={ItemName="Swirly Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10125548451",ItemType="Gun",Rarity="Godly"},
	["Switchblade"]={ItemName="Switchblade",Image="http://www.roblox.com/asset/?id=11533086777",ItemType="Knife",Rarity="Godly"},
	["sword"]={ItemName="Sword",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=3197769392",ItemType="Knife",Rarity="Ancient"},
	["Tailslide"]={ItemName="Tailslide",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=305506822",ItemType="Knife",Rarity="Common"},
	["TealClover"]={ItemName="Gradient Clover",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12741435899",ItemType="Knife",Rarity="Uncommon"},
	["TealTech"]={ItemName="Teal Tech",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433233689",ItemType="Knife",Rarity="Uncommon"},
	["TechnicBlade"]={ItemName="Technic Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12481174130",ItemType="Knife",Rarity="Godly"},
	["TElderGun"]={ItemName="Trophy Elderwood Pack",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11363661530",ItemType="Gun",Rarity="Victim"},
	["TFL"]={ItemName="TFL",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2866284360",ItemType="Knife",Rarity="Common"},
	["TGoldenEdge"]={ItemName="Trophy Hallow Pack",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9561288313",ItemType="Knife",Rarity="Victim"},
	["TheSeer"]={ItemName="Seer",Image="http://www.roblox.com/asset/?id=3184139765",ItemType="Knife",Rarity="Godly"},
	["THH"]={ItemName="Portals",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10761315251",ItemType="Knife",Rarity="Rare"},
	["ThrexSC"]={ItemName="Cy's Nightblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10203337028",ItemType="Knife",Rarity="Custom"},
	["ThrexSC2"]={ItemName="Cy's Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10661798947",ItemType="Gun",Rarity="Custom"},
	["ThrexSC23"]={ItemName="Cy's Nightblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10203337028",ItemType="Knife",Rarity="Custom"},
	["ThunderKarambit"]={ItemName="Thunder's Karambit",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12661045359",ItemType="Knife",Rarity="Ancient"},
	["ThunderLuger"]={ItemName="Thunder's Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12661057517",ItemType="Gun",Rarity="Ancient"},
	["Tides"]={ItemName="Tides",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=3187398809",ItemType="Knife",Rarity="Godly"},
	["Tiger"]={ItemName="Tiger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9094262503",ItemType="Gun",Rarity="Uncommon"},
	["Tigris"]={ItemName="Tiger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6936860646",ItemType="Knife",Rarity="Uncommon"},
	["Tile"]={ItemName="Tile",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9094192638",ItemType="Gun",Rarity="Common"},
	["Time2"]={ItemName="Time",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14728391347",ItemType="Gun",Rarity="Ancient"},
	["TimeGun"]={ItemName="Time",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10761719484",ItemType="Gun",Rarity="Godly"},
	["TimeKnife"]={ItemName="Prince",Image="http://www.roblox.com/asset/?id=143917700",ItemType="Knife",Rarity="Classic"},
	["TNL"]={ItemName="TNL",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=201542790",ItemType="Knife",Rarity="Common"},
	["Toilet"]={ItemName="Toilet",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13129178028",ItemType="Knife",Rarity="Godly"},
	["Toxic"]={ItemName="Toxic",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10938015221",ItemType="Gun",Rarity="Rare"},
	["toxic"]={ItemName="Toxic",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11227108572",ItemType="Knife",Rarity="Rare"},
	["ToxicAxe"]={ItemName="Toxic Axe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13664884477",ItemType="Knife",Rarity="Godly"},
	["ToxicBlade2a"]={ItemName="Toxic Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13684818947",ItemType="Knife",Rarity="Victim"},
	["ToxicCore"]={ItemName="Toxic Core",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11090412061",ItemType="Knife",Rarity="Godly"},
	["ToxicG"]={ItemName="Toxic Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12489829739",ItemType="Gun",Rarity="Godly"},
	["ToxicGooKnife"]={ItemName="ToxicGoo",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12555071034",ItemType="Knife",Rarity="Ancient"},
	["ToxicH"]={ItemName="Toxic Heart",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12489746607",ItemType="Knife",Rarity="Godly"},
	["ToxicHammer"]={ItemName="Toxic Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13174129820",ItemType="Knife",Rarity="Dream"},
	["ToxicMech"]={ItemName="Toxic Mech",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13174153238",ItemType="Knife",Rarity="Dream"},
	["ToxicRayGun"]={ItemName="Toxic Ray Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13684753089",ItemType="Gun",Rarity="Victim"},
	["ToxicShark"]={ItemName="Toxic Shark",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154578034",ItemType="Gun",Rarity="Godly"},
	["ToxicSword"]={ItemName="Toxic Sword",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13174145187",ItemType="Knife",Rarity="Dream"},
	["TravellerEdge"]={ItemName="Traveller's Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10831056191",ItemType="Knife",Rarity="Ancient"},
	["Tree"]={ItemName="Tree",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=331745577",ItemType="Knife",Rarity="Legendary"},
	["Tree2"]={ItemName="Tree",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6676489935",ItemType="Knife",Rarity="Uncommon"},
	["Treeblade"]={ItemName="Treeblade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14408617799",ItemType="Knife",Rarity="Godly"},
	["TreeGun"]={ItemName="Tree",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332497688",ItemType="Gun",Rarity="Legendary"},
	["trees"]={ItemName="Trees",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6123336879",ItemType="Knife",Rarity="Common"},
	["Trees"]={ItemName="Trees",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6123336879",ItemType="Knife",Rarity="Common"},
	["Trident2"]={ItemName="Trident",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14166380128",ItemType="Knife",Rarity="Godly"},
	["Troll"]={ItemName="Troll",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7030500492",ItemType="Knife",Rarity="Uncommon"},
	["trophy1"]={ItemName="Trophy Harvester Pack",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11363654968",ItemType="Gun",Rarity="Victim"},
	["TrophyCandy"]={ItemName="Trophy Candy Pack",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8563597228",ItemType="Knife",Rarity="Victim"},
	["TrophyVamps"]={ItemName="Trophy Vampire Pack",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7871361074",ItemType="Knife",Rarity="Victim"},
	["Tulip"]={ItemName="Tulip",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=387874661",ItemType="Knife",Rarity="Uncommon"},
	["TurkeyCannon"]={ItemName="Turkey Cannon",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11556134695",ItemType="Gun",Rarity="Godly"},
	["UFOs"]={ItemName="UFO",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=12877363974",ItemType="Knife",Rarity="Legendary"},
	["UfoScythe"]={ItemName="UFO Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13074420583",ItemType="Knife",Rarity="Godly"},
	["Ukraine"]={ItemName="Ukraine",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12093411679",ItemType="Knife",Rarity="Godly"},
	["Ultra"]={ItemName="Mercury",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10034605049",ItemType="Knife",Rarity="Uncommon"},
	["UltraHammer"]={ItemName="Ultrahammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10940652974",ItemType="Knife",Rarity="Exotic"},
	["Uncanny"]={ItemName="Uncanny",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7030500492",ItemType="Knife",Rarity="Rare"},
	["Undead"]={ItemName="Undead",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11288179886",ItemType="Knife",Rarity="Common"},
	["UndervoidGalactic"]={ItemName="Undervoid Galactic",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13166663328",ItemType="Knife",Rarity="Godly"},
	["Universal"]={ItemName="Universe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2432568171",ItemType="Knife",Rarity="Godly"},
	["Universe"]={ItemName="Universe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238546660",ItemType="Gun",Rarity="Legendary"},
	["Valentine"]={ItemName="Valentine",Image="https://www.roblox.com/asset/?id=363362726",ItemType="Knife",Rarity="Uncommon"},
	["ValentineG"]={ItemName="Lover",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12363792036",ItemType="Gun",Rarity="Rare"},
	["ValentineK"]={ItemName="Valentine",Image="https://www.roblox.com/asset/?id=363362726",ItemType="Knife",Rarity="Uncommon"},
	["ValentinesG"]={ItemName="Valentine",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12359253939",ItemType="Gun",Rarity="Uncommon"},
	["vampg"]={ItemName="Vampire",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11227284289",ItemType="Gun",Rarity="Rare"},
	["Vampire"]={ItemName="Vampire",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873248",ItemType="Knife",Rarity="Uncommon"},
	["Vampire2"]={ItemName="Vampire",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10935524700",ItemType="Knife",Rarity="Rare"},
	["Vampire22"]={ItemName="Vampire",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11361659693",ItemType="Knife",Rarity="Legendary"},
	["Vampire3"]={ItemName="Vampire",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11288177859",ItemType="Knife",Rarity="Common"},
	["VampireE"]={ItemName="Vampire's Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7588377235",ItemType="Knife",Rarity="Godly"},
	["VampireGun"]={ItemName="Vampire",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11421123720",ItemType="Gun",Rarity="Legendary"},
	["Venus"]={ItemName="Venus",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11521367807",ItemType="Knife",Rarity="Common"},
	["VineKnife"]={ItemName="Vine",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13849656231",ItemType="Knife",Rarity="Common"},
	["Viper"]={ItemName="Viper",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=160299600",ItemType="Gun",Rarity="Legendary"},
	["Virtual"]={ItemName="Virtual",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=386276987",ItemType="Knife",Rarity="Godly"},
	["VirtualY"]={ItemName="Summer Virtual",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14455459194",ItemType="Knife",Rarity="Godly"},
	["Void"]={ItemName="Void",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11521382764",ItemType="Knife",Rarity="Uncommon"},
	["VoidBlade"]={ItemName="Corrupted Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10891990791",ItemType="Knife",Rarity="Godly"},
	["VoidBladeK"]={ItemName="Void Blade",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7429337166",ItemType="Knife",Rarity="Godly"},
	["Voidheat"]={ItemName="Void Heat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10190284022",ItemType="Knife",Rarity="Space"},
	["VoidHeat"]={ItemName="Void Heat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11460538916",ItemType="Knife",Rarity="Godly"},
	["VoidScy"]={ItemName="Void Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10675453553",ItemType="Knife",Rarity="v"},
	["VoidsGlow"]={ItemName="Void's Glow",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13156167881",ItemType="Knife",Rarity="Ancient"},
	["VoidSlash"]={ItemName="Void Slasher",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10179637257",ItemType="Knife",Rarity="Space"},
	["VoidSpider"]={ItemName="Void Spider",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12884438709",ItemType="Knife",Rarity="Ancient"},
	["VolcanicVortex"]={ItemName="Volcanic Vortex",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14319204674",ItemType="Knife",Rarity="Ancient"},
	["Volcano"]={ItemName="Volcano",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11086687995",ItemType="Knife",Rarity="Godly"},
	["Vortex"]={ItemName="Vortex",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235371508",ItemType="Knife",Rarity="Rare"},
	["Wanwood"]={ItemName="Wanwood",Image="http://www.roblox.com/asset/?id=192132094",ItemType="Knife",Rarity="Uncommon"},
	["Watcher"]={ItemName="Watcher",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10469650329",ItemType="Knife",Rarity="Rare"},
	["watcher"]={ItemName="Watcher",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=5866438542",ItemType="Knife",Rarity="Common"},
	["watcherg"]={ItemName="Watcher",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11230723356",ItemType="Gun",Rarity="Rare"},
	["Water"]={ItemName="Water Bottle",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13867616299",ItemType="Knife",Rarity="Ancient"},
	["WaterGun"]={ItemName="Water Gun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13011624818",ItemType="Gun",Rarity="Ancient"},
	["WaterGun2"]={ItemName="Watergun",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2300836754",ItemType="Gun",Rarity="Godly"},
	["WaterMaceaa"]={ItemName="Water Mace",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2300836754",ItemType="Knife",Rarity="Godly"},
	["WatermelonKnife"]={ItemName="Watermelon",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13849695972",ItemType="Knife",Rarity="Uncommon"},
	["WaterOverseer"]={ItemName="Water Overseer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14275895904",ItemType="Knife",Rarity="Godly"},
	["WaterSabera"]={ItemName="Water Saber",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13850039771",ItemType="Knife",Rarity="Godly"},
	["watta"]={ItemName="Water",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10034349764",ItemType="Knife",Rarity="Uncommon"},
	["WavesGK"]={ItemName="Green Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13973945340",ItemType="Knife",Rarity="Godly"},
	["WavesK"]={ItemName="Waves",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13957713621",ItemType="Knife",Rarity="Godly"},
	["WBClover"]={ItemName="White and Black Clover",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12741397961",ItemType="Knife",Rarity="Uncommon"},
	["WBioBlade"]={ItemName="BioBlade",Image="http://www.roblox.com/asset/?id=6905678498",ItemType="Knife",Rarity="Godly"},
	["Web"]={ItemName="Web",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315104004",ItemType="Knife",Rarity="Legendary"},
	["Webbed19"]={ItemName="Webbed",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7192746515",ItemType="Knife",Rarity="Common"},
	["Webs"]={ItemName="Webs",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11421208449",ItemType="Gun",Rarity="Common"},
	["WebsKNI"]={ItemName="Webs",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10702876817",ItemType="Knife",Rarity="Uncommon"},
	["wenned"]={ItemName="Webbed",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11230753287",ItemType="Knife",Rarity="Common"},
	["White Iceblaster"]={ItemName="Silver Iceblaster",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6738084734",ItemType="Gun",Rarity="Victim"},
	["White Icebreaker"]={ItemName="Silver Icebreaker",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6738084966",ItemType="Knife",Rarity="Victim"},
	["Whiteout"]={ItemName="Whiteout",Image="http://www.roblox.com/asset/?id=191788694",ItemType="Knife",Rarity="Common"},
	["WhiteUfo"]={ItemName="White UFO",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13074822045",ItemType="Knife",Rarity="Rare"},
	["Wind"]={ItemName="Wind",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10716705745",ItemType="Knife",Rarity="Godly"},
	["Wind22"]={ItemName="Wind",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=3526884281",ItemType="Knife",Rarity="Godly"},
	["Window"]={ItemName="Window",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11489061317",ItemType="Knife",Rarity="Common"},
	["WingedPhantom"]={ItemName="Winged Phantom",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13510588104",ItemType="Gun",Rarity="Ancient"},
	["WintersEdge"]={ItemName="Winter's Edge",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6676491441",ItemType="Knife",Rarity="Godly"},
	["Witch"]={ItemName="Witch",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873553",ItemType="Knife",Rarity="Common"},
	["Witchbrew"]={ItemName="Witchbrew",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11361651589",ItemType="Knife",Rarity="Uncommon"},
	["witched"]={ItemName="Witched",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11227045555",ItemType="Knife",Rarity="Legendary"},
	["WitherKnife"]={ItemName="Wither",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12700994666",ItemType="Knife",Rarity="Rare"},
	["Wolf"]={ItemName="Wolf",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873487",ItemType="Knife",Rarity="Uncommon"},
	["Wooden"]={ItemName="Wooden",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238546356",ItemType="Gun",Rarity="Uncommon"},
	["Wow"]={ItemName="Wow",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10761318793",ItemType="Knife",Rarity="Common"},
	["Wraith"]={ItemName="Wraith",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11359806380",ItemType="Gun",Rarity="Rare"},
	["WraithK"]={ItemName="Wraith",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11421386985",ItemType="Knife",Rarity="Rare"},
	["wraiths"]={ItemName="Wraiths",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10469647174",ItemType="Gun",Rarity="Uncommon"},
	["Wrap"]={ItemName="Wrap",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121854816",ItemType="Knife",Rarity="Uncommon"},
	["WrapG"]={ItemName="Wrap",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121867603",ItemType="Gun",Rarity="Uncommon"},
	["WrapGun"]={ItemName="Wrap",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121867603",ItemType="Gun",Rarity="Uncommon"},
	["Wrapped"]={ItemName="Wrapped",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=331745500",ItemType="Knife",Rarity="Uncommon"},
	["WrappedGun"]={ItemName="Wrapped",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332497103",ItemType="Gun",Rarity="Uncommon"},
	["WrappedKNI"]={ItemName="Wrapped",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2669640357",ItemType="Knife",Rarity="Common"},
	["Xbox"]={ItemName="Xbox",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=439325100",ItemType="Knife",Rarity="Victim"},
	["Xmas"]={ItemName="Xmas",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332077449",ItemType="Knife",Rarity="Godly"},
	["YAYAM"]={ItemName="Yay! Autumn",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11556168510",ItemType="Knife",Rarity="Legendary"},
	["YAYSM"]={ItemName="Yay! Summer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9819891945",ItemType="Knife",Rarity="Legendary"},
	["YAYSP"]={ItemName="Yay! Spring",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9215765778",ItemType="Knife",Rarity="Legendary"},
	["YBioBlade"]={ItemName="BioBlade",Image="http://www.roblox.com/asset/?id=6905660285",ItemType="Knife",Rarity="Godly"},
	["YeezySlide"]={ItemName="Yeezy Slide",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13157109762",ItemType="Knife",Rarity="Ancient"},
	["YellowBlizzard"]={ItemName="Yellow Blizzard",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433442298",ItemType="Knife",Rarity="Common"},
	["YellowHammer"]={ItemName="Yellow Hammer",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433306991",ItemType="Knife",Rarity="Common"},
	["YellowPrismatic"]={ItemName="Yellow Prismatic",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14274923008",ItemType="Knife",Rarity="Godly"},
	["YellowSeer"]={ItemName="Yellow Seer",Image="http://www.roblox.com/asset/?id=8346691369",ItemType="Knife",Rarity="Godly"},
	["YellowTech"]={ItemName="Yellow Tech",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433192151",ItemType="Knife",Rarity="Common"},
	["YellowUfo"]={ItemName="Yellow UFO",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13074711739",ItemType="Knife",Rarity="Common"},
	["Yeti"]={ItemName="Yeti",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=512&height=512&assetId=13433439704",ItemType="Knife",Rarity="Rare"},
	["YHeat"]={ItemName="Yellow Heat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2605646162",ItemType="Knife",Rarity="Godly"},
	["Zombie"]={ItemName="Zombie",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10935522793",ItemType="Knife",Rarity="Uncommon"},
	["zombie"]={ItemName="Zombie",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11227291013",ItemType="Gun",Rarity="Uncommon"},
	["ZombieDeath"]={ItemName="Zombie Deathshard",Image="http://www.roblox.com/asset/?id=9274835899",ItemType="Knife",Rarity="Godly"},
	["Zombiefied"]={ItemName="Zombiefied",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11421416168",ItemType="Knife",Rarity="Rare"},
	["zombiefied"]={ItemName="Zombified",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11231056063",ItemType="Gun",Rarity="Uncommon"},
	["zombiek"]={ItemName="Zombie",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11230829262",ItemType="Knife",Rarity="Uncommon"},
	["ZombieKNI"]={ItemName="Zombie",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10702861958",ItemType="Knife",Rarity="Common"},
	["Zombified19"]={ItemName="Zombified",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7192746840",ItemType="Knife",Rarity="Uncommon"},
	["ZyleaksHarvester"]={ItemName="Zyleak's Harvester",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14838122407",ItemType="Gun",Rarity="Ancient"},
	["ZyleaksHeat"]={ItemName="Zyleak's Heat",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14838379882",ItemType="Knife",Rarity="Ancient"},
	["ZyleaksLuger"]={ItemName="Zyleak's Luger",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14838160743",ItemType="Gun",Rarity="Ancient"},
	["ZyleaksScythe"]={ItemName="Zyleak's Scythe",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14838154042",ItemType="Knife",Rarity="Ancient"},
}

-- Real MM2 pets extracted from the place file (48).
local PetDB = {
	["0BV1CORALXO"]={Name="Pink",Image="",Rarity="Victim"},
	["123catgirlmeowxdrawr"]={Name="Emma",Image="",Rarity="Dream"},
	["1Fears1"]={Name="Fear",Image="",Rarity="Victim"},
	["1uhwharps"]={Name="Star",Image="",Rarity="Victim"},
	["<3"]={Name="<3",Image="363155463",Rarity="Common"},
	["ahdoure"]={Name="Vamps",Image="",Rarity="Victim"},
	["AliineGamesYT"]={Name="Aline Games",Image="",Rarity="Dream"},
	["AmericanEagle"]={Name="Sammy",Image="446052376",Rarity="Godly"},
	["AncientBox"]={Name="Ancient Box",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14646028853",Rarity="Ancient"},
	["Angelazz"]={Name="Angelazz",Image="",Rarity="Victim"},
	["Ant"]={Name="Ant (Youtuber)",Image="",Rarity="Legendary"},
	["AweChai"]={Name="Payton",Image="",Rarity="Victim"},
	["Badger"]={Name="Badger",Image="357817300",Rarity="Common"},
	["bbbesitos"]={Name="Cloud",Image="",Rarity="Dream"},
	["Bear"]={Name="Bear",Image="3215087365",Rarity="Rare"},
	["bekometoye"]={Name="Beko",Image="",Rarity="Victim"},
	["Bitsplosion"]={Name="Bitsplosion",Image="https://www.roblox.com/asset/?id=365367041",Rarity="Common"},
	["BlackCat"]={Name="Black Cat",Image="6695689974",Rarity="Rare"},
	["Blue_king1222"]={Name="Blue King",Image="",Rarity="Uncommon"},
	["BlueFire"]={Name="Blue Flaming Knife",Image="https://www.roblox.com/asset/?id=387182852",Rarity="Rare"},
	["bodygrave"]={Name="Bodygrave",Image="",Rarity="Dream"},
	["BooSign"]={Name="BooSign",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7808228583",Rarity="Common"},
	["Burn"]={Name="Flaming Knife",Image="https://www.roblox.com/asset/?id=387182858",Rarity="Common"},
	["BxJ524"]={Name="Jaden",Image="",Rarity="Victim"},
	["caimoo9"]={Name="Kaiden",Image="",Rarity="Victim"},
	["CertifiedBellaaaa"]={Name="Bella",Image="",Rarity="Victim"},
	["ChampulseV0"]={Name="ChampulseV0",Image="",Rarity="Victim"},
	["ChickenLeg"]={Name="Chicken Leg",Image="rbxassetid://11497892431",Rarity="Common"},
	["Chilly"]={Name="Chilly",Image="357821774",Rarity="Uncommon"},
	["Chloe"]={Name="Chloe",Image="",Rarity="Legendary"},
	["Chroma Fire Bat"]={Name="Chroma Fire Bat",Image="3215184228",Rarity="Godly"},
	["Chroma Fire Pig"]={Name="Chroma Fire Pig",Image="6575314430",Rarity="Godly"},
	["ClassicBox"]={Name="Vintage Box",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14703740451",Rarity="Classic"},
	["CoolUFO"]={Name="Galaxy UFO",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13174490980",Rarity="Godly"},
	["cutecrazyboy603"]={Name="Colin",Image="",Rarity="Dream"},
	["Darkfire"]={Name="Darkfire",Image="https://www.roblox.com/asset/?id=475504088",Rarity="Common"},
	["DBat"]={Name="Dominus Bat",Image="13529109389",Rarity="Godly"},
	["DBear"]={Name="Dominus Bear",Image="13529104420",Rarity="Legendary"},
	["DBunny"]={Name="Dominus Bunny",Image="13529080620",Rarity="Uncommon"},
	["DCat"]={Name="Dominus Cat",Image="13529043266",Rarity="Common"},
	["DDog"]={Name="Dominus Fox",Image="13529062563",Rarity="Uncommon"},
	["Deenis"]={Name="Denis (Youtuber)",Image="",Rarity="Legendary"},
	["DFox"]={Name="Dominus Fox",Image="13529053386",Rarity="Common"},
	["diedthatday"]={Name="Mason",Image="",Rarity="Victim"},
	["diya"]={Name="Diya",Image="",Rarity="Victim"},
	["Dog"]={Name="Dog",Image="3215085821",Rarity="Common"},
	["Dogey"]={Name="Dogey",Image="357823389",Rarity="Uncommon"},
	["DPig"]={Name="Dominus Pig",Image="13529088405",Rarity="Rare"},
	["Drea"]={Name="Drea",Image="",Rarity="Victim"},
	["Dtbswirve"]={Name="Dtbswirve",Image="",Rarity="Uncommon"},
	["Dual"]={Name="Dual Wield",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=237811060",Rarity="Legendary"},
	["Dylan"]={Name="Dylan from JD (Youtuber)",Image="",Rarity="Legendary"},
	["ekittendesi"]={Name="Kate",Image="",Rarity="Victim"},
	["ekittendestroyer763"]={Name="Jason",Image="",Rarity="Victim"},
	["Electro"]={Name="Electro",Image="386277688",Rarity="Godly"},
	["Elfy"]={Name="Elf",Image="585798235",Rarity="Common"},
	["Elitey"]={Name="Elitey",Image="357525407",Rarity="Legendary"},
	["Elitify"]={Name="Elite-ify",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=346681501",Rarity="Legendary"},
	["EWScythe"]={Name="HallowKNI",Image="rbxassetid://6484433812",Rarity="Ancient"},
	["Eye"]={Name="Eyeball",Image="358134944",Rarity="Rare"},
	["Fairy"]={Name="Fairy",Image="358125321",Rarity="Uncommon"},
	["Flamingo"]={Name="Flamingo",Image="",Rarity="Victim"},
	["floss"]={Name="Floss",Image="http://www.roblox.com/asset/?id=2474247282",Rarity="Rare"},
	["FlowEffect"]={Name="Flow Effect",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13957853725",Rarity="Legendary"},
	["Fox"]={Name="Fox",Image="3215086785",Rarity="Uncommon"},
	["GalaxyCandy"]={Name="Galactic Candy",Image="rbxassetid://11502808470",Rarity="Custom"},
	["GearStorm"]={Name="Gear Storm",Image="https://www.roblox.com/asset/?id=360666852",Rarity="Common"},
	["GhostBuster"]={Name="Test",Image="13710967765",Rarity="Godly"},
	["Ghostify"]={Name="Ghostify",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=415915771",Rarity="Common"},
	["Gingerbread Man"]={Name="Gingerbread Man",Image="6272847945",Rarity="Legendary"},
	["GingerBreadMan"]={Name="Gingerbread Man",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13873093708",Rarity="Legendary"},
	["GoatedRhavi"]={Name="Rhavi",Image="",Rarity="Victim"},
	["GodlyBox"]={Name="Godly Box",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14646026717",Rarity="Godly"},
	["GreenFire"]={Name="Green Flaming Knife",Image="https://www.roblox.com/asset/?id=387182851",Rarity="Rare"},
	["Grimace"]={Name="Grimace Shake",Image="https://www.roblox.com/asset/?id=13974902615",Rarity="Godly"},
	["headless"]={Name="Headless",Image="http://www.roblox.com/asset/?id=2513709230",Rarity="Uncommon"},
	["HeartBalloon"]={Name="<3",Image="363155463",Rarity="Common"},
	["Heartify"]={Name="Heartify",Image="https://www.roblox.com/asset/?id=416769271",Rarity="Common"},
	["huloshi"]={Name="Bee",Image="",Rarity="Victim"},
	["hwaunnted"]={Name="Hwaunnted",Image="",Rarity="Dream"},
	["Hyuvng"]={Name="Jack",Image="",Rarity="Dream"},
	["IceMagic"]={Name="Ice Magic",Image="https://www.roblox.com/asset/?id=8320233180",Rarity="Rare"},
	["IcePhoenix"]={Name="Ice Phoenix",Image="1268829924",Rarity="Godly"},
	["Icey"]={Name="Icey",Image="4528373379",Rarity="Godly"},
	["idstab"]={Name="Taylor",Image="",Rarity="Dream"},
	["iiiJxylx"]={Name="Ariel",Image="",Rarity="Victim"},
	["IJayd_nBeast"]={Name="Jay",Image="",Rarity="Victim"},
	["iLogan_nBeast"]={Name="Logan",Image="",Rarity="Victim"},
	["IPresx_nBeast"]={Name="OffSale",Image="",Rarity="Victim"},
	["ItsJustWata"]={Name="Blue Fog",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13873093708",Rarity="Common"},
	["ItsMeDeathBlade_ALT"]={Name="Death Blade",Image="",Rarity="Uncommon"},
	["Jetstream"]={Name="Jetstream",Image="358126292",Rarity="Rare"},
	["Joven"]={Name="Joven from JD (Youtuber)",Image="",Rarity="Legendary"},
	["jxalouus"]={Name="Zoey",Image="",Rarity="Dream"},
	["k4ig0tmyh3art"]={Name="Hana",Image="",Rarity="Victim"},
	["Knifeception"]={Name="Knifeception",Image="https://www.roblox.com/asset/?id=418207962",Rarity="Uncommon"},
	["kyzvure"]={Name="Kai",Image="",Rarity="Victim"},
	["Leeroy"]={Name="Leeroy",Image="",Rarity="Victim"},
	["maxownsmedttm"]={Name="Jaiden",Image="",Rarity="Victim"},
	["Mechbug"]={Name="Mechbug",Image="357789913",Rarity="Rare"},
	["MoneyEffect"]={Name="Monify",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238446940",Rarity="Common"},
	["Mr Snowman"]={Name="Mr Snowman",Image="6121720416",Rarity="Common"},
	["Mr. Reindeer"]={Name="Mr. Reindeer",Image="6121725088",Rarity="Rare"},
	["Nex5us"]={Name="Terror",Image="",Rarity="Dream"},
	["Nobledragon"]={Name="Nobledragon",Image="357813086",Rarity="Legendary"},
	["NuttyKashy"]={Name="Cashy",Image="",Rarity="Dream"},
	["over_comes"]={Name="over_comes",Image="",Rarity="Dream"},
	["Overseer Eye"]={Name="Overseer Eye",Image="358135658",Rarity="Legendary"},
	["Pengy"]={Name="Pengy",Image="357655751",Rarity="Common"},
	["Phoenix"]={Name="Phoenix",Image="365355267",Rarity="Godly"},
	["Pig"]={Name="Pig",Image="3215087054",Rarity="Uncommon"},
	["Piggy"]={Name="Piggy",Image="357816542",Rarity="Common"},
	["PinkFire"]={Name="Pink Flaming Knife",Image="https://www.roblox.com/asset/?id=387182855",Rarity="Rare"},
	["PLight"]={Name="Pink Lightning",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13869476059",Rarity="Common"},
	["PurpleAlien"]={Name="Purple Alien",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13154570086",Rarity="Godly"},
	["qt3a"]={Name="Reese",Image="",Rarity="Victim"},
	["Radioactive"]={Name="Radioactive",Image="https://www.roblox.com/asset/?id=416805902",Rarity="Rare"},
	["RadioactiveGun"]={Name="Radioactive",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14235594271",Rarity="Rare"},
	["rayhitta"]={Name="Rick",Image="",Rarity="Victim"},
	["ReaverSign"]={Name="Reaver Sign",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7808229175",Rarity="Common"},
	["Reindeer"]={Name="Reindeer",Image="585789096",Rarity="Common"},
	["Roblox"]={Name="Roblox",Image="",Rarity="Victim"},
	["SandKnifeModule"]={Name="Wrapped Sand Knife",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365568056",Rarity="Legendary"},
	["Seahorsey"]={Name="Seahorsey",Image="357818987",Rarity="Uncommon"},
	["senr4wr"]={Name="senzie",Image="",Rarity="Victim"},
	["Sev"]={Name="Sev",Image="",Rarity="Victim"},
	["SGMSouthh"]={Name="Ryan",Image="",Rarity="Dream"},
	["shefatal"]={Name="Scare",Image="",Rarity="Dream"},
	["Skelly"]={Name="Skelly",Image="475477388",Rarity="Godly"},
	["someoneis_GrAcE"]={Name="Grace",Image="",Rarity="Victim"},
	["SprayPaint"]={Name="Spray Paint",Image="342185593",Rarity="Rare"},
	["sskiey"]={Name="Layla",Image="",Rarity="Victim"},
	["St Patricks Tentacles"]={Name="St Patricks Tentacles",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=12741639869",Rarity="Godly"},
	["Steambird"]={Name="Steambird",Image="360615840",Rarity="Godly"},
	["Sunshine"]={Name="Sunshine",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=13867377847",Rarity="Godly"},
	["Tankie"]={Name="Tankie",Image="357793334",Rarity="Rare"},
	["tiarvn"]={Name="Tia",Image="",Rarity="Victim"},
	["TinyUFO"]={Name="UFO",Image="13174103904",Rarity="Godly"},
	["toooher"]={Name="toooher",Image="",Rarity="Victim"},
	["ToyCandy2021"]={Name="Toy Candy 3",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7808227101",Rarity="Common"},
	["ToyCandy2022"]={Name="Candy Emote",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11137521765",Rarity="Common"},
	["ToyCandyGalaxy"]={Name="Galactic Candy",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=11502808470",Rarity="Custom"},
	["Traveller"]={Name="Traveller",Image="7356692022",Rarity="Godly"},
	["UFO"]={Name="UFO",Image="357654905",Rarity="Common"},
	["UncommonOrnament"]={Name="Uncommon Ornament",Image="rbxassetid://2674907876",Rarity="Christmas"},
	["Ux_xUxoO"]={Name="Nat",Image="",Rarity="Dream"},
	["Victim"]={Name="Victim Box",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14687059374",Rarity="Victim"},
	["VictimTest"]={Name="Victim Box",Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=14646026717",Rarity="Godly"},
	["vootups"]={Name="Night",Image="",Rarity="Dream"},
	["vorcitss"]={Name="Heartz",Image="",Rarity="Victim"},
	["zeiiteu"]={Name="Sky",Image="",Rarity="Dream"},
	["zen"]={Name="Zen",Image="http://www.roblox.com/asset/?id=198273518",Rarity="Rare"},
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
	local data = invokeWithTimeout(gsd, name, 6)
	if type(data) == "table" then return data end
	return nil
end

local function countKeys(t)
	local n = 0; if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end; return n
end

-- Set by the panel; called once real data loads. Also reports the catalog state.
local onCatalogLoaded
local CatalogStatus = "catalog: embedded (" .. countKeys(ItemDB) .. " items) — spawn to add"
local RealCatalog = false  -- true once GetSyncData returns the real catalog

-- Fetch the real catalog + inventory. This may YIELD on InvokeServer, so it MUST
-- run in a background thread (never at load time) or it will freeze the script
-- before the menu is drawn.
-- Pull the LIVE catalog from the running game and MERGE it over the embedded
-- one, so the spawner offers every current item/skin the game has (the embedded
-- data is only an old Halloween snapshot). Retries a few times because the
-- RemoteFunction can be slow to answer right after injection.
local function mergeInto(dst, src)
	if type(src) ~= "table" then return 0 end
	local n = 0
	for k, v in pairs(src) do if type(v) == "table" then dst[k] = v; n = n + 1 end end
	return n
end
local function applyRealData()
	-- Probe the live catalog first (short timeout). If the server never answers
	-- this thread, fail fast and keep the embedded catalog — don't churn.
	local realItems, realPets, realRar
	for attempt = 1, 3 do
		realItems = realItems or tryGetSync("Item")
		if realItems then break end
		task.wait(1.5)  -- brief backoff, then retry the Item fetch
	end
	if realItems then
		realPets = tryGetSync("Pets")
		realRar  = tryGetSync("Rarity")
	end
	-- Merge (not replace): keep embedded items, add every live one on top.
	local added = mergeInto(ItemDB, realItems) + mergeInto(PetDB, realPets)
	if realRar then Rarity = realRar end
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
		CatalogStatus = ("live catalog merged: %d items, %d pets (+%d live)"):format(
			countKeys(ItemDB), countKeys(PetDB), added)
	else
		RealCatalog = false
		CatalogStatus = ("catalog: embedded only, %d items (live fetch: %s)"):format(
			countKeys(ItemDB), tostring(lastSyncError))
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

local TradeCandidatesInfo = "?"
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
	-- Record what we saw (name + enabled) so the Info tab can show which trade
	-- GUIs the game actually made — helps decide the table/phone binding.
	do
		local names = {}
		for _, g in ipairs(candidates) do
			names[#names + 1] = g.Name .. (g.Enabled and "(on)" or "(off)")
		end
		TradeCandidatesInfo = (#names > 0) and table.concat(names, ", ") or "none"
	end

	-- The game creates ONLY the trade GUI for the mode the player chose in-game
	-- (table vs phone) — the device/screen doesn't matter (you can pick "table" on
	-- a phone to test the PC layout). So pick whichever GUI the game actually made:
	-- prefer an Enabled one, then one that owns Container.Trade / Container.Items.
	local best, bestScore
	for _, gui in ipairs(candidates) do
		local s = 0
		if gui.Enabled then s = s + 100 end
		if resolve(gui, "Container.Trade") then s = s + 10 end
		if resolve(gui, "Container.Items") then s = s + 1 end
		if not bestScore or s > bestScore then best, bestScore = gui, s end
	end
	if best then return best end

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

-- Snapshot the trade GUI's authored transparency (Container + whole subtree) at
-- load, while it's still in its clean closed state. The close/complete animation
-- (ours in `terminate`, plus the game's own trade-finished fade) tweens frames to
-- BackgroundTransparency = 1; without a restore, the SECOND trade re-opens fully
-- see-through. `restoreTradeTransparency` (below) plays this snapshot back on open.
-- Stored on Runtime (keyed by instance) so it costs no top-level local.
Runtime.OrigTransparency = {}
if Container then
	local snap = { Container }
	for _, d in ipairs(Container:GetDescendants()) do
		if d:IsA("GuiObject") then snap[#snap + 1] = d end
	end
	for _, inst in ipairs(snap) do
		local rec = {}
		pcall(function() rec.bg = inst.BackgroundTransparency end)
		pcall(function() rec.img = inst.ImageTransparency end)
		pcall(function() rec.grp = inst.GroupTransparency end)
		Runtime.OrigTransparency[inst] = rec
	end
end

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

-- Phone MODE? Decided by which trade GUI the game made (the in-game table/phone
-- choice), NOT the device: the phone GUI is the "phone"-named one / the request
-- lives under the Lobby "Waiting" screen. On phone the native flow is: a "!"
-- badge appears on the leaderboard "+" button, request shows when the tab opens.
local IsPhone = (TradeGUI ~= nil and string.find(string.lower(TradeGUI.Name), "phone") ~= nil)
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

-- DIAGNOSTIC DUMP — writes the live trade-GUI tree (the Items picker, the Accept
-- action subtree and an offer frame) to `MollyHub_dump.txt` AND prints it, with
-- per-node props (Visible / ZIndex / AbsoluteSize / colours). Child lists are
-- capped so the ~200-slot grids stay short. Auto-runs shortly after a trade opens
-- (see startTrade) and is also exposed as _G.MHDump() for a manual re-dump.
-- GLOBAL so it can be called from anywhere without a top-level local.
function MH_Dump()
	local out = {}
	local function w(s) out[#out + 1] = s end
	local function col3(c)
		local ok, s = pcall(function()
			return string.format("#%02X%02X%02X",
				math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
		end)
		return ok and s or "?"
	end
	local function propsOf(d)
		local p = {}
		pcall(function()
			if d:IsA("GuiObject") then
				p[#p + 1] = "vis=" .. tostring(d.Visible)
				p[#p + 1] = "z=" .. tostring(d.ZIndex)
				local sz = d.AbsoluteSize
				p[#p + 1] = string.format("abs=%dx%d", math.floor(sz.X), math.floor(sz.Y))
				if d.BackgroundTransparency < 1 then p[#p + 1] = "bg=" .. col3(d.BackgroundColor3) end
			end
		end)
		pcall(function()
			if d:IsA("ImageLabel") or d:IsA("ImageButton") then
				if d.ImageTransparency < 1 then p[#p + 1] = "img=" .. col3(d.ImageColor3) end
			end
		end)
		local isText = false
		pcall(function() isText = d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") end)
		if isText then
			pcall(function()
				local t = tostring(d.Text)
				if #t > 20 then t = t:sub(1, 20) .. "~" end
				p[#p + 1] = 'txt="' .. t .. '"'
			end)
			-- Font in its OWN pcall so a FontFace getter error can't suppress it.
			pcall(function() p[#p + 1] = "font=" .. tostring(d.Font) end)
			pcall(function()
				if d.FontFace then p[#p + 1] = "face=" .. tostring(d.FontFace.Family) end
			end)
		end
		pcall(function() if d:IsA("UIGradient") then p[#p + 1] = "GRADIENT" end end)
		pcall(function()
			if d:IsA("UIStroke") then
				p[#p + 1] = "STROKE col=" .. col3(d.Color) .. " th=" .. tostring(d.Thickness)
					.. " on=" .. tostring(d.Enabled)
			end
		end)
		return (#p > 0) and ("  [" .. table.concat(p, ", ") .. "]") or ""
	end
	local function dump(node, depth, maxDepth, cap)
		if not node then w(string.rep("  ", depth) .. "<nil>") return end
		local ok, cn = pcall(function() return node.ClassName end)
		w(string.rep("  ", depth) .. (ok and cn or "?") .. ' "' .. tostring(node.Name) .. '"' .. propsOf(node))
		if depth >= maxDepth then return end
		local kids = {}
		pcall(function() kids = node:GetChildren() end)
		local n = #kids
		local lim = math.min(n, cap)
		for i = 1, lim do dump(kids[i], depth + 1, maxDepth, cap) end
		if n > lim then w(string.rep("  ", depth + 1) .. "... (" .. (n - lim) .. " more of " .. n .. ")") end
	end
	w("===== MollyHub DUMP =====")
	w("BUILD          = equip-v37 (inventory equip back, catalog untouched)")
	w("TradeGUI       = " .. fn(TradeGUI))
	w("TradeRoot      = " .. fn(TradeRoot))
	w("ItemsPicker    = " .. fn(ItemsPicker))
	w("Weapons grid   = " .. fn(InventoryFrame))
	w("Pets grid      = " .. fn(PetsFrame))
	-- FIRST (so a truncated paste still keeps it): every top-level GUI in PlayerGui
	-- (name + enabled), so the trade-reward / "you received" popup can be found.
	w("-- PlayerGui ScreenGuis --")
	pcall(function()
		for _, g in ipairs(PlayerGui:GetChildren()) do
			local en = ""
			pcall(function() if g:IsA("ScreenGui") or g:IsA("LayerCollector") then en = g.Enabled and " (on)" or " (off)" end end)
			local kids = 0
			pcall(function() kids = #g:GetChildren() end)
			w("  " .. g.ClassName .. ' "' .. tostring(g.Name) .. '"' .. en .. " kids=" .. kids)
		end
	end)
	-- EQUIP: where the weapon MODELS live + how an equipped one is attached.
	-- (0) ProfileData: where the "equipped knife/gun" is stored (client-side equip
	-- = set this + poke ProfileDataChanged, since the game already displays it).
	pcall(function()
		local rs0 = game:GetService("ReplicatedStorage")
		local mods = rs0:FindFirstChild("Modules")
		local pd = mods and mods:FindFirstChild("ProfileData")
		pd = pd and require(pd)
		if type(pd) == "table" then
			w("-- ProfileData top-level keys --")
			for k, v in pairs(pd) do
				w("  " .. tostring(k) .. " : " .. type(v) .. (type(v) ~= "table" and (" = " .. tostring(v)) or ""))
			end
			-- Show Weapons/Pets and, crucially, the CONTENTS of Equipped + a few Owned
			-- (so we know the exact format to write for a client-side equip).
			for _, kk in ipairs({ "Weapons", "Pets" }) do
				local sub = pd[kk]
				if type(sub) == "table" then
					w("-- ProfileData." .. kk .. " --")
					for k, v in pairs(sub) do
						if type(v) == "table" then
							local n, sample = 0, {}
							for ik, iv in pairs(v) do
								n = n + 1
								if #sample < 8 then sample[#sample + 1] = tostring(ik) .. "=" .. tostring(iv) end
							end
							w("    " .. tostring(k) .. " (table, " .. n .. "): " .. table.concat(sample, ", "))
						else
							w("    " .. tostring(k) .. " = " .. tostring(v))
						end
					end
				end
			end
		end
	end)
	-- MY equipped display's current mesh/texture (DisplayRefKnife/Gun -> Mesh).
	pcall(function()
		local char = LocalPlayer.Character
		for _, rn in ipairs({ "DisplayRefKnife", "DisplayRefGun" }) do
			local ov = char and char:FindFirstChild(rn)
			local part = ov and ov:IsA("ObjectValue") and ov.Value
			local m = part and (part:FindFirstChildWhichIsA("SpecialMesh") or part:FindFirstChildWhichIsA("MeshPart"))
			if m then
				local mid, tid = "", ""
				pcall(function() mid = tostring(m.MeshId) end)
				pcall(function() tid = tostring(m.TextureId) end)
				w("-- MY " .. rn .. ": mesh=" .. mid .. " tex=" .. tid .. " --")
			end
		end
	end)
	-- Every weapon mesh the client can already see + the replicated state that
	-- drives it. This is what tells us how to make the 3D model appear.
	pcall(function()
		w("-- weapon meshes visible on the client --")
		w("  " .. MH_harvestDisplays(24))
		local wd = workspace:FindFirstChild("WeaponDisplays")
		if wd then w("-- Workspace.WeaponDisplays --"); dump(wd, 0, 4, 10)
		else w("-- Workspace.WeaponDisplays: <none> --") end
		-- every distinct weapon mesh anywhere, with its path: if the game keeps a
		-- 3D shop stand or gallery, the path names the item it belongs to
		w("-- mesh gallery (distinct mesh+texture, anywhere) --")
		w(MH_meshGallery(40))
		for _, src in ipairs({ LocalPlayer, LocalPlayer.Character }) do
			if src then
				local ok, at = pcall(function() return src:GetAttributes() end)
				local list = {}
				if ok and type(at) == "table" then
					for k, v in pairs(at) do list[#list + 1] = tostring(k) .. "=" .. tostring(v) end
				end
				table.sort(list)
				w("-- attributes of " .. src.Name .. " (" .. src.ClassName .. "): "
					.. (#list > 0 and table.concat(list, ", ") or "<none>"))
			end
		end
		local vals = {}
		for _, src in ipairs({ LocalPlayer, LocalPlayer.Character }) do
			if src then
				for _, dd in ipairs(src:GetChildren()) do
					if dd:IsA("ValueBase") then
						vals[#vals + 1] = dd.ClassName .. " " .. dd.Name .. "=" .. tostring(dd.Value)
					end
				end
			end
		end
		w("-- Value objects on player/character: " .. (#vals > 0 and table.concat(vals, ", ") or "<none>"))
	end)
	-- Every client service and the keys it exposes — the weapon-display builder
	-- has to be one of these.
	pcall(function()
		local cs = game:GetService("ReplicatedStorage"):FindFirstChild("ClientServices")
		if not cs then return end
		w("-- ClientServices modules --")
		for _, m in ipairs(cs:GetChildren()) do
			if m:IsA("ModuleScript") then
				local okReq, mod = pcall(require, m)
				local keys = {}
				if okReq and type(mod) == "table" then
					for k, v in pairs(mod) do keys[#keys + 1] = tostring(k) .. ":" .. type(v) end
					table.sort(keys)
				end
				w("  " .. m.Name .. " -> " .. (#keys > 0 and table.concat(keys, ", ") or type(mod)))
			end
		end
	end)
	-- Item data fields for the equipped items — is there a Mesh/Texture/Model field?
	pcall(function()
		w("-- Item fields (Gingerscope / 2015 / Seer) --")
		local src = ItemDB
		for _, k in ipairs({ "Gingerscope", "2015", "Seer", "Chroma" }) do
			local d = src[k]
			if type(d) == "table" then
				local fs = {}
				for fk, fv in pairs(d) do fs[#fs + 1] = tostring(fk) .. "=" .. tostring(fv) end
				table.sort(fs)
				w("  [" .. k .. "] " .. table.concat(fs, ", "))
			end
		end
	end)
	-- Find WHERE weapon models/mesh-data live: search ReplicatedStorage (and, if
	-- reachable, ServerStorage) descendants for instances named like the equipped
	-- weapon keys, and list the module/service folders that likely hold them.
	pcall(function()
		local keys = { "Palms_K_2024", "Gingermint_G", "Gingerscope", "2015", "Seer", "Godly" }
		local roots = { game:GetService("ReplicatedStorage") }
		pcall(function() roots[#roots + 1] = game:GetService("ReplicatedFirst") end)
		w("-- weapon-key instances (by exact key name) --")
		local found = 0
		for _, root in ipairs(roots) do
			for _, d in ipairs(root:GetDescendants()) do
				local nm = tostring(d.Name)
				for _, k in ipairs(keys) do
					if nm == k then
						w("  " .. d.ClassName .. ' "' .. nm .. '" @ ' .. d:GetFullName())
						found = found + 1
						break
					end
				end
				if found > 24 then break end
			end
			if found > 24 then break end
		end
		if found == 0 then w("  (none — models likely built at runtime / server-side)") end
	end)
	pcall(function()
		local rs = game:GetService("ReplicatedStorage")
		for _, nm in ipairs({ "Modules", "Database", "ClientServices", "SharedServices", "Resources" }) do
			local f = rs:FindFirstChild(nm)
			if f then w("-- ReplicatedStorage." .. nm .. " (depth 2) --"); dump(f, 0, 2, 30) end
		end
	end)
	-- Require the equip-related client services and list their table keys (methods)
	-- so we can see the exact equip API (no source reading needed).
	pcall(function()
		local rs = game:GetService("ReplicatedStorage")
		local cs = rs:FindFirstChild("ClientServices")
		if not cs then return end
		for _, nm in ipairs({ "EquipService", "WeaponService", "InventoryService", "ItemService" }) do
			local m = cs:FindFirstChild(nm)
			if m then
				local okReq, mod = pcall(require, m)
				if okReq and type(mod) == "table" then
					local keys = {}
					for k, v in pairs(mod) do keys[#keys + 1] = tostring(k) .. ":" .. type(v) end
					table.sort(keys)
					w("-- require(ClientServices." .. nm .. ") keys --")
					w("  " .. table.concat(keys, ", "))
				else
					w("-- require(ClientServices." .. nm .. ") -> " .. type(mod) .. " --")
				end
			end
		end
	end)
	-- (1) ReplicatedStorage top level — find the weapon-model storage folder.
	pcall(function()
		local rs = game:GetService("ReplicatedStorage")
		w("-- ReplicatedStorage children --")
		for _, c in ipairs(rs:GetChildren()) do
			local kids = 0; pcall(function() kids = #c:GetChildren() end)
			w("  " .. c.ClassName .. ' "' .. tostring(c.Name) .. '" kids=' .. kids)
		end
		-- Shallow-dump likely weapon-storage folders so we can find a model by key.
		for _, nm in ipairs({ "Weapons", "Weapon", "Assets", "Knives", "Guns", "Items", "Skins", "WeaponModels", "Models" }) do
			local f = rs:FindFirstChild(nm)
			if f then w("-- ReplicatedStorage." .. nm .. " (children) --"); dump(f, 0, 1, 20) end
		end
	end)
	-- (2) The currently equipped weapon model (DisplayRefKnife/Gun -> Value) and its
	-- structure + parent, so we can replicate how the game welds it to the character.
	pcall(function()
		local char = LocalPlayer.Character
		if char then
			w("-- Character children --")
			for _, c in ipairs(char:GetChildren()) do w("  " .. c.ClassName .. ' "' .. tostring(c.Name) .. '"') end
			for _, rn in ipairs({ "DisplayRefKnife", "DisplayRefGun" }) do
				local ov = char:FindFirstChild(rn)
				local mdl = ov and ov:IsA("ObjectValue") and ov.Value
				if mdl then
					w("-- " .. rn .. ".Value = " .. mdl:GetFullName() .. " --")
					dump(mdl, 0, 3, 14)
				else
					w("-- " .. rn .. ".Value = <none> --")
				end
			end
		end
	end)
	w("-- Actions subtree (Accept button) --")
	dump(resolve(TradeRoot, "Actions"), 0, 6, 8)
	w("-- Container.Items subtree (picker) --")
	dump(ItemsPicker or (TradeGUI and resolve(TradeGUI, "Container.Items")), 0, 7, 4)
	w("-- YourOffer subtree (trimmed) --")
	dump(Offer1, 0, 3, 2)
	w("-- TheirOffer subtree (trimmed) --")
	dump(Offer2, 0, 3, 2)
	w("===== END DUMP =====")
	local text = table.concat(out, "\n")
	-- Three ways to get the dump off the device (no console needed):
	pcall(function() writefile("MollyHub_dump.txt", text) end)   -- (1) file in workspace
	pcall(function() setclipboard(text) end)                     -- (2) clipboard -> paste it
	pcall(function() for _, line in ipairs(out) do print(line) end end) -- (3) console if any
	-- (4) ON-SCREEN scrollable panel so it can just be screenshotted.
	pcall(function()
		local old = PlayerGui:FindFirstChild("MollyHubDump")
		if old then old:Destroy() end
		local g = Instance.new("ScreenGui")
		g.Name = "MollyHubDump"; g.ResetOnSpawn = false; g.IgnoreGuiInset = true
		g.DisplayOrder = 999999; g.Parent = PlayerGui
		local panel = Instance.new("Frame")
		panel.Size = UDim2.new(0.86, 0, 0.82, 0); panel.Position = UDim2.new(0.07, 0, 0.09, 0)
		panel.BackgroundColor3 = Color3.fromRGB(16, 18, 24); panel.BorderSizePixel = 0
		panel.Parent = g
		Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 8)
		local head = Instance.new("TextLabel")
		head.Size = UDim2.new(1, -70, 0, 26); head.Position = UDim2.new(0, 10, 0, 6)
		head.BackgroundTransparency = 1; head.TextColor3 = Color3.fromRGB(150, 210, 255)
		head.Font = Enum.Font.GothamBold; head.TextSize = 14; head.TextXAlignment = Enum.TextXAlignment.Left
		head.Text = "MollyHub dump — copied to clipboard + MollyHub_dump.txt. Paste it to Claude."
		head.TextWrapped = true; head.Parent = panel
		local close = Instance.new("TextButton")
		close.Size = UDim2.new(0, 52, 0, 26); close.Position = UDim2.new(1, -58, 0, 6)
		close.BackgroundColor3 = Color3.fromRGB(120, 60, 66); close.BorderSizePixel = 0
		close.TextColor3 = Color3.new(1, 1, 1); close.Font = Enum.Font.GothamBold; close.TextSize = 13
		close.Text = "Close"; close.Parent = panel
		Instance.new("UICorner", close).CornerRadius = UDim.new(0, 6)
		close.MouseButton1Click:Connect(function() g:Destroy() end)
		local scroll = Instance.new("ScrollingFrame")
		scroll.Size = UDim2.new(1, -16, 1, -44); scroll.Position = UDim2.new(0, 8, 0, 38)
		scroll.BackgroundColor3 = Color3.fromRGB(10, 11, 15); scroll.BorderSizePixel = 0
		scroll.ScrollBarThickness = 8; scroll.CanvasSize = UDim2.new(0, 0, 0, #out * 15 + 40)
		scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y; scroll.Parent = panel
		Instance.new("UICorner", scroll).CornerRadius = UDim.new(0, 6)
		local body = Instance.new("TextLabel")
		body.Size = UDim2.new(1, -12, 0, 0); body.Position = UDim2.new(0, 6, 0, 4)
		body.AutomaticSize = Enum.AutomaticSize.Y; body.BackgroundTransparency = 1
		body.TextColor3 = Color3.fromRGB(215, 220, 230); body.Font = Enum.Font.Code
		body.TextSize = 12; body.TextXAlignment = Enum.TextXAlignment.Left
		body.TextYAlignment = Enum.TextYAlignment.Top; body.TextWrapped = true
		body.Text = text; body.Parent = scroll
	end)
	return text
end
_G.MHDump = MH_Dump

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

-- OVERLAY mode: paint the fake inventory + fake items onto YOUR side of a REAL,
-- in-progress game trade. Purely visual on your client — nothing is sent, the
-- other player's real offer is never touched, and only YOUR side is (re)painted.
local OverlayMode = false

-- Items the user spawned into the inventory (key -> amount). Every MM2 inventory
-- starts with the two default starter items (Default Knife + Default Gun); they
-- are never tradeable and never consumed, and always sort to the front.
local SpawnedWeapons = { DefaultKnife = 1, DefaultGun = 1 }
local SpawnedPets = {}

-- Items scraped from the REAL game inventory rendered in PlayerGui
-- (category -> { key = { visual = {Image,Name,Color,Chroma}, amount } }).

-- Name captured when the request modal is shown; consumed when the native
-- green Accept button is clicked (mirrors AcceptRequest -> StartTrade).
local PendingP2Name = "Player2"

-- Hooks run at the start of every new trade (used to reset panel toggles etc.).
local onNewTrade = {}
-- Token that invalidates a pending "trade complete" close if a new trade starts.
local completeToken = 0
-- True only while a HARNESS-initiated fake trade is active. The native green
-- Accept button is only hijacked (→ our fake startTrade) when this is set, so
-- accepting a REAL trade with a real player is left completely untouched — the
-- harness never wipes or steals items from a genuine game trade.
local HarnessTradeActive = false
-- True only while OUR fake request modal is pending. The native request Accept is
-- hijacked (→ our fake startTrade) ONLY when this is set, and it is CONSUMED the
-- instant we hijack — so a real trade request accepted later is never stolen.
local HarnessRequestArmed = false
-- Forward decls so the request modal can (re)hook the native Accept button —
-- the game may rebuild that button between trades, so a one-time hook goes stale
-- (this is the "can't start a second trade" bug). We re-hook on every show.
local startTrade
local hookRequestAccept = function() end

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
-- Robustly find + set a slot's item-name TextLabel, whatever the structure
-- (ItemName.Label, or ItemName being the label itself, or a nested Label). This
-- is what kills the leftover template text ("Battleaxe") in filled offer slots.
local function setSlotLabelText(slot, text)
	local nameFrame = slot:FindFirstChild("ItemName")
	local label
	if nameFrame then
		-- this build names the label "Item" (NewFrame.ItemName.Item.Text); also
		-- handle "Label"/"Text", ItemName being the label itself, or any TextLabel.
		label = nameFrame:FindFirstChild("Item") or nameFrame:FindFirstChild("Label")
			or nameFrame:FindFirstChild("Text")
			or (nameFrame:IsA("TextLabel") and nameFrame)
			or nameFrame:FindFirstChildWhichIsA("TextLabel")
	end
	label = label or resolve(slot, "ItemName.Label") or slot:FindFirstChild("Label", true)
	if label and label:IsA("TextLabel") then
		-- Only set the text — keep the template's OWN font (it's the game's real
		-- item-name font now that Add-Items clones an offer slot), so it matches.
		pcall(function() label.Text = text end)
	end
	return nameFrame, label
end

local function renderOffer(sideKey, offerFrame)
	if not offerFrame then return end
	local offers = DebugTradeTable[sideKey].Offer

	-- Wipe EVERY slot (any class), clearing name/icon so no template text lingers.
	for _, frame in ipairs(offerFrame.Container:GetChildren()) do
		if frame:IsA("GuiObject") then
			setProp(frame, "Container.Icon", "Image", "")
			setSlotLabelText(frame, "")
			setProp(frame, "Container.Amount", "Text", "")
			setVisible(frame, "ItemName", false)
			setProp(frame, "Tags.Chroma", "Visible", false)
			frame.Visible = false
		end
	end

	-- Collect the slot frames in order (named NewItem1.. or otherwise), so we can
	-- fill them by index without depending on the exact naming.
	local slots = {}
	for _, s in ipairs(offerFrame.Container:GetChildren()) do
		if s:IsA("GuiObject") and (s:FindFirstChild("Container") or s:FindFirstChild("ItemName")) then
			slots[#slots + 1] = s
		end
	end
	table.sort(slots, function(a, b) return a.Name < b.Name end)

	for i, entry in ipairs(offers) do
		local itemKey, amount, category = entry[1], entry[2], entry[3]
		local visual = entry.visual
		local db = Database[category] or ItemDB
		local data = db[itemKey]
		local slot = slots[i]
		if slot and (data or visual) then
			local img  = (visual and visual.Image) or getImage(data and data.Image)
			local name = (visual and visual.Name) or (data and (data.ItemName or data.Name)) or itemKey
			local rarity = data and data.Rarity
			local plate = (rarity == "Common") and RARITY_GREY
				or (rarity and Rarity[rarity]) or (visual and visual.Color) or RARITY_GREY
			local chroma = (visual and visual.Chroma) or (data and data.Chroma ~= nil) or false
			slot.Visible = true
			setProp(slot, "Container.Icon", "Image", img)
			local nameFrame = setSlotLabelText(slot, name)
			setProp(slot, "ItemName.Label", "TextColor3", Color3.fromRGB(255, 255, 255))
			setProp(slot, "ItemName.RarityBar", "BackgroundColor3", plate)
			if nameFrame and nameFrame:IsA("GuiObject") then pcall(function() nameFrame.BackgroundColor3 = plate end) end
			setVisible(slot, "ItemName", true)
			setProp(slot, "Container.Amount", "Text", (amount and amount > 1) and ("x" .. amount) or "")
			-- Full tag pass (FX on high-tier, snowflake/year off, Chroma, …) so the
			-- offer slots match the inventory slots. Synthesize a data table when we
			-- only have a scraped visual so rarity-based FX still applies.
			applyTags(slot, data or { Rarity = rarity, Chroma = chroma or nil })

			-- Clicking an offer slot pulls ONE copy back out and returns it to the
			-- inventory — on EITHER side (you can take items off both offers).
			local removeBtn = resolve(slot, "Container.ActionButton")
				or resolve(slot, "Container.Button")
			if removeBtn then
				local idx = i  -- capture this slot's offer index
				trackRender(removeBtn.MouseButton1Click:Connect(function()
					unofferOne(sideKey, idx)
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

	-- OVERLAY: only paint YOUR side over a real trade. Do NOT touch the other
	-- player's offer, their name, or the accepted badges — that all belongs to the
	-- real game trade running underneath.
	if OverlayMode then
		renderOffer("Player1", Offer1)
		return
	end

	-- Second participant's display name (swept across all offer frames).
	setOfferUsername("their", "(" .. DebugTradeTable.Player2.Player.Name .. ")")

	-- Acceptance flags -> the green "Accepted" badges.
	showAcceptedBadge("your", DebugTradeTable.Player1.Accepted, "YOU HAVE ACCEPTED.")
	showAcceptedBadge("their", DebugTradeTable.Player2.Accepted, "OTHER PLAYER HAS ACCEPTED.")

	renderOffer("Player1", Offer1)
	renderOffer("Player2", Offer2)

	-- Grey the ACCEPT button on an empty trade, green once something is staged.
	updateAcceptButtonUI()
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

-- Build the offer "visual" for a catalog item (real image/name/rarity colour).
local function catalogVisual(key, category)
	local data = ((category == "Pets") and PetDB or ItemDB)[key]
	if not data then return nil end
	return {
		Image  = getImage(data.Image),
		Name   = data.ItemName or data.Name or key,
		Color  = Rarity[data.Rarity] or Color3.fromRGB(220, 220, 225),
		Chroma = data.Chroma == true,
	}
end

-- Offer an item into whichever side OfferMode currently targets. `visual` (from
-- a clicked real inventory slot) lets offers show real items with no catalog.
-- The inventory pool a category draws from (weapons vs pets).
local function invPool(category)
	return (category == "Pets") and SpawnedPets or SpawnedWeapons
end

-- NO-OP. Firing InventoryDataChanged made the GAME re-render the trade inventory
-- from its own data ON TOP of our clones, so offered counts snapped back and given
-- items never disappeared. Our renderInventory() already repaints the Add-Items
-- grid from the Spawned* pools, so no game poke is needed. Kept as a no-op so the
-- existing call sites stay valid. GLOBAL (no top-level local).
function MH_pokeInventory() end

-- Default starter items are never tradeable and never consumed (like the game).
local function isDefaultItem(key)
	return key == "DefaultKnife" or key == "DefaultGun"
end

-- Place ONE copy of an item into the current side's offer, CONSUMING it from the
-- inventory (Add Items) — exactly like the game moves an item out of your pack
-- and into the offer. Removing it later (tap the offer slot) returns it.
local function offerItemLocal(itemKey, category, visual)
	if isDefaultItem(itemKey) then return end       -- defaults can't be traded
	-- Inventory taps ALWAYS fill YOUR side. Player2's side is filled only by
	-- spawning with "Add to Player 2 side" on (see spawnEntry) — never from
	-- your own inventory.
	local side = DebugTradeTable.Player1
	local pool = invPool(category)
	if (pool[itemKey] or 0) <= 0 then return end     -- nothing left to offer

	-- Stack onto an existing entry or add a new one (mirrors Module.Trade.OfferItem).
	local existing
	for _, e in ipairs(side.Offer) do
		if e[1] == itemKey and e[3] == category then existing = e break end
	end
	if existing then
		existing[2] = existing[2] + 1
	else
		if #side.Offer >= 4 then return end          -- live cap: 4 stacks per side
		local e = { itemKey, 1, category }
		e.visual = visual
		table.insert(side.Offer, e)
	end

	-- Consume one from the inventory so the count drops (and it can run out).
	pool[itemKey] = pool[itemKey] - 1
	if pool[itemKey] <= 0 then pool[itemKey] = nil end

	-- Consume-and-render is shared, but in OVERLAY mode we must not touch the real
	-- trade's accept flow (flags, confirm/cancel, cooldown) — leave that to the game.
	if not OverlayMode then
		-- Any change to the table resets both acceptance flags, like the server does.
		DebugTradeTable.LastOffer = os.time()
		DebugTradeTable.Player1.Accepted = false
		DebugTradeTable.Player2.Accepted = false
		-- Editing an offer collapses the confirm/cancel steps, matching the live UI.
		setVisible(TradeRoot, "Actions.Accept.Confirm", false)
		setVisible(TradeRoot, "Actions.Accept.Cancel", false)
	end
	MH_pokeInventory()     -- re-render the native inventory GUI (count dropped)
	renderInventory()      -- refresh the inventory counts
	RenderTrade()
	if not OverlayMode then startAcceptCooldown() end  -- 6s "please wait before accepting"
end

-- Take ONE copy back out of a side's offer and RETURN it to the inventory.
-- Used by the offer-slot tap on BOTH sides (you can pull items off either side).
-- Global so renderOffer (defined earlier) can reference it.
function unofferOne(sideKey, index)
	local offer = DebugTradeTable[sideKey].Offer
	local entry = offer[index]
	if not entry then return end
	-- Only YOUR (Player1) items came out of your inventory, so only those return to
	-- it. Player2's items are the fake other player's — removing them just discards
	-- (they must NOT drop into your pack).
	if sideKey == "Player1" and not isDefaultItem(entry[1]) then
		local pool = invPool(entry[3])
		pool[entry[1]] = (pool[entry[1]] or 0) + 1
	end
	entry[2] = entry[2] - 1
	if entry[2] <= 0 then table.remove(offer, index) end
	if not OverlayMode then
		DebugTradeTable.Player1.Accepted = false
		DebugTradeTable.Player2.Accepted = false
		setVisible(TradeRoot, "Actions.Accept.Confirm", false)
		setVisible(TradeRoot, "Actions.Accept.Cancel", false)
	end
	MH_pokeInventory()     -- re-render the native inventory GUI (count went up)
	renderInventory()
	RenderTrade()
	if not OverlayMode and startAcceptCooldown then startAcceptCooldown() end
end

-- Return every staged item on a side back to the inventory pool it came from and
-- empty that side's offer. Used when a trade is ABANDONED (declined / a fresh
-- trade replaces an incomplete one) so the items you staged aren't lost — a
-- completed trade consumes them instead (see completeTradeIfBothAccepted).
-- GLOBAL so the request-Decline handler (defined far below) can call it without
-- spending a top-level local.
function returnOfferToInventory(sideKey)
	local side = DebugTradeTable and DebugTradeTable[sideKey]
	if not (side and side.Offer) then return end
	for _, entry in ipairs(side.Offer) do
		if not isDefaultItem(entry[1]) then
			local pool = invPool(entry[3])
			pool[entry[1]] = (pool[entry[1]] or 0) + (entry[2] or 1)
		end
	end
	side.Offer = {}
	MH_pokeInventory()     -- re-render the native inventory GUI so refunds show up
end

-- Grey the native ACCEPT button while the trade is empty (nothing to trade), and
-- restore its authored green once at least one item is staged on either side —
-- matching MM2, which won't let you accept an empty trade. Original colours are
-- cached per node on first run (while the button is still its native green).
-- GLOBAL (called from RenderTrade) to stay within the top-level local budget.
function updateAcceptButtonUI()
	if not TradeRoot then return end
	local acc = resolve(TradeRoot, "Actions.Accept")
	if not (acc and acc:IsA("GuiObject")) then return end
	local abtn0 = resolve(acc, "ActionButton") or acc
	-- NEVER touch a real trade: only manage the button during a HARNESS fake trade.
	-- Otherwise remove our cover and re-enable the native button so a real trade's
	-- Accept works normally (this was greying/disabling real trades).
	if not HarnessTradeActive then
		local c = acc:FindFirstChild("__MHacceptGrey")
		if c then c.Visible = false end
		pcall(function() abtn0.Active = true end)
		pcall(function() abtn0.AutoButtonColor = true end)
		return
	end
	local total = #DebugTradeTable.Player1.Offer + #DebugTradeTable.Player2.Offer
	local empty = total <= 0
	-- The green "outline" is the button's Gradient TEXTURE, and the game re-asserts
	-- the native colour every frame — recolouring it is a race we lose. Instead lay
	-- OUR OWN opaque grey button on top while the trade is empty; the game never
	-- touches it, so it stays grey. Hide it the moment something is staged.
	local cover = acc:FindFirstChild("__MHacceptGrey")
	if empty then
		if not cover then
			cover = Instance.new("Frame")
			cover.Name = "__MHacceptGrey"
			cover.Size = UDim2.new(1, 8, 1, 8)          -- cover the slight border overhang
			cover.Position = UDim2.new(0.5, 0, 0.5, 0)
			cover.AnchorPoint = Vector2.new(0.5, 0.5)
			cover.BackgroundColor3 = Color3.fromRGB(112, 116, 122)
			cover.BorderSizePixel = 0
			cover.ZIndex = 40
			local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = cover
			local lbl = Instance.new("TextLabel")
			lbl.Name = "Label"; lbl.Size = UDim2.new(1, 0, 1, 0)
			lbl.BackgroundTransparency = 1; lbl.Text = "ACCEPT"
			lbl.TextColor3 = Color3.fromRGB(205, 209, 216)
			lbl.Font = Enum.Font.SourceSansBold; lbl.TextSize = 20
			lbl.ZIndex = 41; lbl.Parent = cover
			cover.Parent = acc
		end
		cover.Visible = true
	elseif cover then
		cover.Visible = false
	end
	-- Block the click while empty (a plain Frame doesn't eat clicks, so also disable
	-- the native button so accepting an empty trade does nothing).
	local btn = resolve(acc, "ActionButton") or acc
	pcall(function() btn.Active = not empty end)
	pcall(function() btn.AutoButtonColor = not empty end)
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


-- Find the inventory container for a category + a real slot to clone (correct
-- size/style for the platform). Name-agnostic: uses any real slot in the picker.
-- Find ANY slot we can clone as a template. The inventory, the picker and the
-- offer NewItem frames all share the Container.Icon / ItemName.Label shape, so if
-- the inventory grid is empty (offline: the game never ran UpdateInventory) we can
-- still template off an offer slot and render correctly.
local function anyTemplateSlot()
	for _, root in ipairs({ InventoryFrame, PetsFrame, ItemsPicker, Offer1, Offer2 }) do
		if root then
			for _, slot in ipairs(root:GetDescendants()) do
				if slot:IsA("GuiObject")
					and (slot:FindFirstChild("Icon") or resolve(slot, "Container.Icon"))
					and (slot:FindFirstChild("ItemName") or resolve(slot, "ItemName.Label")) then
					return slot
				end
			end
		end
	end
	return nil
end

-- Resolve the trade GUI's own Weapons/Pets tab container (the "Add Items" grid),
-- even when it is EMPTY offline. We fill it ourselves from the catalog.
local function findTabContainer(category)
	local direct = (category == "Pets") and PetsFrame or InventoryFrame
	if direct and direct.AbsoluteSize.X >= 120 then return direct end
	local items = ItemsPicker or (TradeGUI and resolve(TradeGUI, "Container.Items")) or nil
	if items then
		-- The item grid is a WIDE scrolling/grid container (the tab button
		-- "Tabs.Weapons" is tiny ~92px). Pick the widest matching one.
		local best, bestArea
		for _, d in ipairs(items:GetDescendants()) do
			if (d:IsA("ScrollingFrame") or d:IsA("Frame")) and d.AbsoluteSize.X >= 150 and d.AbsoluteSize.Y >= 80 then
				local hasGrid = d:FindFirstChildWhichIsA("UIGridLayout") ~= nil
				local ln = string.lower(d:GetFullName())
				local isPet = string.find(ln, "pet") ~= nil
				local matches = ((category == "Pets") == isPet)
				if matches and (hasGrid or d:IsA("ScrollingFrame")) then
					local area = d.AbsoluteSize.X * d.AbsoluteSize.Y
					if not bestArea or area > bestArea then best, bestArea = d, area end
				end
			end
		end
		if best then return best end
		-- fall back to the named tab even if small
		local tabs = items:FindFirstChild("Tabs") or items
		local tab = tabs:FindFirstChild(category)
		if tab then return tab:FindFirstChildWhichIsA("ScrollingFrame") or tab end
	end
	return direct
end

local function findInventoryContainer(category)
	local cont = findTabContainer(category)
	if not cont then return nil, nil end
	-- Template: an existing slot in the container, else any slot in the tree
	-- (offer NewItem frames share the same shape and always exist).
	local tmpl
	for _, s in ipairs(cont:GetChildren()) do
		if s:IsA("GuiObject") and (s:FindFirstChild("ItemName") or resolve(s, "Container.Icon")) then
			tmpl = s; break
		end
	end
	tmpl = tmpl or anyTemplateSlot()
	if tmpl then return cont, tmpl end
	return nil, nil
end

-- Per-category cache of { container, template } captured from a real game slot
-- (correct size/style on phone). InvContainer kept for openItemsPicker reveal.
local InvCache = {}
local InvContainer

-- Stamp a catalog item onto a cloned slot. Matches the game's INVENTORY style:
-- the ItemName PLATE is coloured by rarity (grey for Common); the label text
-- keeps the template's own colour — this fixes the "wrong/too bright" colours.
-- Set the tag badges exactly like the game's GridFunctions / DisplayItem, reading
-- the SAME item fields the game uses (this build stores holidays in Event/Year):
--   Chroma    <- ItemData.Chroma == true
--   Evo       <- ItemData.EvoBaseID ~= nil        (the "evolved" badge)
--   Christmas <- ItemData.Event == "Christmas"    (+ Year text)   [or YearTag]
--   Halloween <- ItemData.Event == "Halloween"    (+ Year text)   [or YearTagHW]
--   Unique    <- ItemData.CustomAward / Leaderboard / Unique (+ owner PlayerName)
-- Each child is toggled defensively (setProp no-ops when the template lacks it),
-- so slots with only a subset of badge frames still render correctly.
-- Show a single badge frame by name: force IT and its children visible (the
-- cloned inventory template can carry a hidden badge subtree, which is why tags
-- showed in the offer but not in the Add Items grid).
local function showBadge(tags, name)
	local b = tags:FindFirstChild(name)
	if b then revealSubtree(b) end
	return b
end

-- Toggle the year/holiday "snowflake 2023" badges. The user asked for them OFF.
-- Flip to true to bring the Christmas/Halloween year badges back.
local SHOW_HOLIDAY_TAGS = false

-- FX shows on effect / high-tier items (Godly and above) — a faithful proxy for
-- MM2's FX badge, which marks effect skins.
-- FX only when the item's REAL data flags an effect — NOT by rarity (that showed
-- FX on every Godly). The live catalog carries the true flags; the game itself
-- renders FX for exactly these items, which is why the spawner path looks right.
local FX_FIELDS = { "FX", "Effect", "HasFX", "Effects", "Godlys", "Exclusive", "Animated",
	"Particle", "GodlyFX", "Particles", "Trail", "Glow", "Shine" }
local function itemHasFX(data)
	for _, f in ipairs(FX_FIELDS) do
		local v = data[f]
		if v ~= nil and v ~= false then return true end
	end
	-- Also catch items that REFERENCE an effect/particle module in a string field.
	for _, v in pairs(data) do
		if type(v) == "string" then
			local lv = v:lower()
			if lv:find("effect", 1, true) or lv:find("particle", 1, true) then return true end
		end
	end
	return false
end

-- Global so renderOffer (defined earlier) can reuse it for offer slots too.
function applyTags(slot, data)
	local tags = slot:FindFirstChild("Tags")
	if not tags then return end
	-- The Tags CONTAINER itself may be hidden on a cloned slot — un-hide it so the
	-- badges inside can render at all.
	if tags:IsA("GuiObject") then pcall(function() tags.Visible = true end) end
	-- Reset every badge first (mirrors the game's set-false pass), then light only
	-- what applies.
	for _, name in ipairs({ "Chroma", "Christmas", "Halloween", "Unique", "Evo", "FX" }) do
		setProp(tags, name, "Visible", false)
	end
	if data.Chroma ~= nil then showBadge(tags, "Chroma") end
	if data.EvoBaseID ~= nil or data.Evo ~= nil then showBadge(tags, "Evo") end
	-- FX: reveal ONLY the game's own native FX frame (no drawn badge). The
	-- Add-Items grid now clones an offer slot, which carries the real FX frame.
	if itemHasFX(data) then showBadge(tags, "FX") end
	-- Holiday "snowflake + year" badges — OFF by default (user request).
	if SHOW_HOLIDAY_TAGS then
		if data.Event == "Christmas" or data.YearTag ~= nil or data.Christmas ~= nil then
			local xmas = showBadge(tags, "Christmas")
			if xmas and data.Year then setProp(xmas, "Year", "Text", tostring(data.Year)) end
		end
		if data.Event == "Halloween" or data.YearTagHW ~= nil or data.Halloween ~= nil then
			local hw = showBadge(tags, "Halloween")
			if hw and data.Year then setProp(hw, "Year", "Text", tostring(data.Year)) end
		end
	end
	if data.CustomAward ~= nil or data.Leaderboard ~= nil or data.Unique ~= nil then
		local uniq = showBadge(tags, "Unique")
		local owner = data.CustomAward or data.Leaderboard
		if uniq and type(owner) == "string" then setProp(uniq, "PlayerName", "Text", owner) end
	end
end


local function paintSlot(slot, data, amount)
	slot.Name = data.ItemName or data.Name or "Item"
	slot.Visible = true
	slot:SetAttribute("__MHSpawn", true)
	-- The template (an offer slot) carries an absolute Position/AnchorPoint that
	-- makes clones "float". Reset them so the container's UIGridLayout places it.
	pcall(function()
		slot.Position = UDim2.new(0, 0, 0, 0)
		slot.AnchorPoint = Vector2.new(0, 0)
	end)
	local icon = slot:FindFirstChild("Icon") or resolve(slot, "Container.Icon")
		or slot:FindFirstChildWhichIsA("ImageLabel", true)
	if icon then pcall(function() icon.Image = getImage(data.Image) end) end
	-- Name (robust: kills the template default like "Battleaxe" — the label is
	-- ItemName.Item in this build).
	local nameFrame = setSlotLabelText(slot, data.ItemName or data.Name or slot.Name)
	nameFrame = nameFrame or slot:FindFirstChild("ItemName")
	-- Rarity plate colour. Colour whichever element is the visible plate: the
	-- ItemName frame itself AND a RarityBar/Item child, so the right one shows.
	local col = (data.Rarity == "Common") and RARITY_GREY or (Rarity[data.Rarity] or RARITY_GREY)
	if typeof(col) == "Color3" and nameFrame and nameFrame:IsA("GuiObject") then
		pcall(function() nameFrame.BackgroundColor3 = col end)
		-- the visible plate in this build is ItemName.BG (an ImageLabel) — tint it.
		for _, ch in ipairs(nameFrame:GetChildren()) do
			if ch.Name == "BG" or ch.Name == "RarityBar" or ch.Name == "Bar"
				or ch.Name == "Plate" or ch.Name == "Background" then
				if ch:IsA("ImageLabel") or ch:IsA("ImageButton") then
					pcall(function() ch.ImageColor3 = col end)
					pcall(function() ch.BackgroundColor3 = col end)
				elseif ch:IsA("GuiObject") then
					pcall(function() ch.BackgroundColor3 = col end)
				end
			end
		end
	end
	local amt = resolve(slot, "Container.Amount") or slot:FindFirstChild("Amount", true)
	if amt and amt:IsA("TextLabel") then amt.Text = (amount and amount > 1) and ("x" .. amount) or "" end
	applyTags(slot, data)
end

-- Paint a slot straight from a scraped real-inventory visual (no catalog needed).
-- Resolve a slot's clickable button (or the slot itself).
local function slotButton(slot)
	return resolve(slot, "Container.Button") or resolve(slot, "Container.ActionButton")
		or slot:FindFirstChild("Button") or (slot:IsA("GuiButton") and slot) or nil
end

-- Find the slot's item-NAME label. The instance name (d.Name) is unreliable in
-- some builds (all slots keep the template's name, e.g. "Battleaxe"), so we look
-- for the real label: explicit ItemName paths first, then any TextLabel whose
-- text is NOT the amount ("x67" / a bare number).
local function slotNameLabel(d)
	local n = resolve(d, "ItemName.Label")
		or (d:FindFirstChild("ItemName") and d.ItemName:IsA("TextLabel") and d.ItemName)
		or (d:FindFirstChild("ItemName") and d.ItemName:FindFirstChildWhichIsA("TextLabel"))
	if n and n:IsA("TextLabel") and tostring(n.Text) ~= "" then return n end
	for _, t in ipairs(d:GetDescendants()) do
		if t:IsA("TextLabel") then
			local s = tostring(t.Text)
			if s ~= "" and not s:match("^x?%s*%d+$") then return t end
		end
	end
	return n and n:IsA("TextLabel") and n or nil
end

-- Scan PlayerGui for the player's REAL inventory slots WHEREVER the game
-- rendered them (the big Weapons/Pets menu holds ~200 slots; the trade GUI's
-- own inventory may hold only a couple). We (a) hook each real slot in place so
-- a tap adds it to the offer, and (b) collect its {name, visual, amount} so we
-- can also mirror it into the trade's own "Add Items" panel. Returns the
-- collected table + slot count. Our own clones (__MHSpawn) are skipped.
-- Per-category { container, template, cell } captured from a real slot.
local function getInvCache(category)
	local cache = InvCache[category]
	if not (cache and cache.container and cache.template) then
		local container, sample = findInventoryContainer(category)
		if not container then return nil end
		-- Prefer an OFFER slot as the template: its native badge frames (Chroma /
		-- Evo / …) actually render when cloned, whereas the inventory slot's don't —
		-- so the Add-Items grid gets the SAME real game badges as the offer.
		local tmplSrc = sample
		for _, off in ipairs({ Offer1, Offer2 }) do
			if off then
				for _, s in ipairs(off:GetDescendants()) do
					if s:IsA("GuiObject") and (resolve(s, "Container.Icon") or s:FindFirstChild("Icon"))
						and s:FindFirstChild("ItemName") and s:FindFirstChild("Tags") then
						tmplSrc = s; break
					end
				end
			end
			if tmplSrc ~= sample then break end
		end
		cache = { container = container, template = tmplSrc:Clone(), cell = sample.AbsoluteSize }
		InvCache[category] = cache
	end
	return cache
end

-- Make sure the container arranges children in a grid (some builds position
-- slots absolutely; if there is no layout we add one so clones don't overlap).
-- Inventory icons were too small (the game's trade grid cell is only 84x96). Use
-- a bigger cell so the icons match the offer slots — clamp into [MIN, MAX].
local INV_CELL_MIN, INV_CELL_MAX = 108, 132
local function clampCell(v, fallback)
	if not v or v < 8 then return fallback end
	if v < INV_CELL_MIN then return INV_CELL_MIN end
	if v > INV_CELL_MAX then return INV_CELL_MAX end
	return v
end
local function ensureLayout(container, cell)
	local cx = clampCell(cell and cell.X, 112)
	local cy = clampCell(cell and cell.Y, 120)
	for _, c in ipairs(container:GetChildren()) do
		if c:IsA("UIGridLayout") then
			-- Enlarge the game's tiny grid cell so icons read at a comfortable size.
			c.CellSize = UDim2.new(0, cx, 0, cy)
			return
		end
		if c:IsA("UIListLayout") then return end
	end
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(0, cx, 0, cy)
	grid.CellPadding = UDim2.new(0, 6, 0, 6)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = container
end

-- The "Add Items" panel is YOUR INVENTORY: it shows the items you spawned (and
-- your real owned items), filtered by the search box, sorted by rarity. You tap
-- an item HERE to place it into the trade offer.
local CurrentQuery = ""
local ADD_CAP = 200

-- Build a sorted array of OWNED items (spawned + real), joined to catalog data.
local function invArr(owned, db, query)
	local q = tostring(query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	local arr = {}
	for key, amount in pairs(owned) do
		local v = db[key]
		local nm = tostring((v and (v.ItemName or v.Name)) or key)
		if q == "" or nm:lower():find(q, 1, true) or tostring(key):lower():find(q, 1, true) then
			arr[#arr + 1] = { key = key, name = nm, rarity = v and v.Rarity, amount = amount }
		end
	end
	table.sort(arr, function(a, b)
		-- Default Knife then Default Gun always lead (mirrors the game's sort).
		if a.key == "DefaultKnife" then return true elseif b.key == "DefaultKnife" then return false
		elseif a.key == "DefaultGun" then return true elseif b.key == "DefaultGun" then return false end
		local ra = RarityValue[a.rarity or "Common"] or 0
		local rb = RarityValue[b.rarity or "Common"] or 0
		if ra ~= rb then return ra > rb end
		return a.name:lower() < b.name:lower()
	end)
	return arr
end

local function renderPaneInventory(category, owned, db, query)
	local cache = getInvCache(category)
	if not cache then return 0 end
	local container, template = cache.container, cache.template
	if category == "Weapons" then InvContainer = container end

	for _, c in ipairs(container:GetChildren()) do
		if c:IsA("GuiObject") then c:Destroy() end
	end
	ensureLayout(container, cache.cell)
	if container:IsA("ScrollingFrame") then
		pcall(function() container.AutomaticCanvasSize = Enum.AutomaticSize.Y end)
		pcall(function() container.ScrollingEnabled = true end)
	end

	local arr = invArr(owned, db, query)
	local shown = 0
	for _, e in ipairs(arr) do
		if shown >= ADD_CAP then break end
		local data = db[e.key] or { ItemName = e.name, Rarity = e.rarity or "Common", Image = "" }
		local slot = template:Clone()
		paintSlot(slot, data, e.amount)
		slot.LayoutOrder = shown + 1
		slot.Parent = container
		local key = e.key
		local vis = catalogVisual(key, category) or { Image = getImage(data.Image), Name = e.name,
			Color = Rarity[e.rarity or "Common"] or RARITY_GREY, Chroma = false }
		local btn = slotButton(slot)
		if btn then
			track(btn.MouseButton1Click:Connect(function()
				offerItemLocal(key, category, vis)
			end))
		end
		shown = shown + 1
	end
	return #arr
end

-- Global (not local) so offerItemLocal / unofferOne, defined earlier, can call it.
function renderInventory()
	pcall(renderPaneInventory, "Weapons", SpawnedWeapons, ItemDB, CurrentQuery)
	pcall(renderPaneInventory, "Pets", SpawnedPets, PetDB, CurrentQuery)
end

-- Default the Add-Items picker to the WEAPONS tab: show Weapons, HIDE Pets. Both
-- panes share the same slot and are revealed together for rendering, so leaving
-- Pets visible parks it ON TOP of Weapons — swallowing the clicks (inventory felt
-- dead until you toggled tabs) and hiding refunded items after a decline. GLOBAL
-- (no top-level local); mirrors the Weapons tab button handler.
function MH_showWeaponsTab()
	setVisible(TradeGUI, "Container.Items.Main.Weapons", true)
	setVisible(TradeGUI, "Container.Items.Main.Pets", false)
	if InventoryFrame then revealAncestors(InventoryFrame) end
end

-- Wire the trade's native search box (once) so typing filters the Add Items grid.
local function wireSearchBox()
	local root = ItemsPicker or (TradeGUI and resolve(TradeGUI, "Container.Items"))
	if not root or root:GetAttribute("__MHSearchWired") then return end
	local box = root:FindFirstChild("SearchText", true)
	if not (box and box:IsA("TextBox")) then
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("TextBox") then box = d; break end
		end
	end
	if box and box:IsA("TextBox") then
		root:SetAttribute("__MHSearchWired", true)
		track(box:GetPropertyChangedSignal("Text"):Connect(function()
			CurrentQuery = tostring(box.Text)
			renderInventory()
		end))
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
	HarnessRequestArmed = true  -- arm the native-request-Accept hijack for OUR fake flow
	-- Re-resolve the request frame every time: after a trade the game can REBUILD
	-- its TradeRequest UI, leaving our cached reference pointing at a destroyed
	-- frame — which is why the SECOND request wouldn't show. Take the fresh one.
	local fresh = findRequestFrame()
	if fresh then RequestFrame = fresh end
	if not RequestFrame then
		warn("[TradeDebug] TradeRequest frame not found in PlayerGui — cannot show request.")
		return
	end
	-- Tear down leftover state from a PREVIOUS trade so a second (and third, …)
	-- incoming request presents cleanly — the fix for "can't send the trade a
	-- second time". Cancel a pending "trade complete" close, stop the cooldown,
	-- clear accepted badges and the Processing overlay. NOTE: do NOT hide TradeRoot
	-- here — startTrade (on Accept) is what re-shows it, and hiding it could leave
	-- the trade GUI invisible after accepting. The previous trade already hid the
	-- trade panel via completeTradeIfBothAccepted.
	completeToken = completeToken + 1
	stopAcceptCooldown()
	showAcceptedBadge("your", false); showAcceptedBadge("their", false)
	local processing = resolve(TradeGUI, "Container.Processing")
		or (Container and Container:FindFirstChild("Processing"))
	if processing then pcall(function() processing.Visible = false end) end
	-- Always bring the request on-screen so it actually appears (on phone this
	-- also un-hides the leaderboard/Waiting screen it lives in). Reveal ancestors
	-- FIRST, then configureRequest sets Visible + shows exactly one variant.
	revealAncestors(RequestFrame)
	configureRequest(player2Name, isIncoming)
	hookRequestAccept()  -- (re)bind the CURRENT native Accept button each show
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
		ItemsPicker.Visible = true
	end
	-- Phone: the picker replaces the offers (they'd overlap on the small screen).
	-- Desktop: the inventory sits beside the offers, so keep BOTH visible.
	if IsPhone and TradeRoot then TradeRoot.Visible = false end
	wireSearchBox()
	renderInventory()  -- fill the Add Items grid from the full catalog
	if InvContainer then revealAncestors(InvContainer) end
	if InventoryFrame then revealAncestors(InventoryFrame) end
	MH_showWeaponsTab()  -- park on Weapons so Pets can't overlay + swallow clicks
end

-- Close the picker and return to the Trade panel.
local function closeItemsPicker()
	if IsPhone and ItemsPicker then ItemsPicker.Visible = false end
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
		-- Capture what YOU receive (the other side's offer) so we can trigger the
		-- game's native "you received" popup once the trade closes.
		local received = {}
		for _, e in ipairs(DebugTradeTable.Player2.Offer) do
			received[#received + 1] = { key = e[1], cat = e[3], amount = e[2] }
		end
		task.delay(2, function()
			-- Abort if a new trade started in the meantime.
			if myToken ~= completeToken then return end
			if processing then processing.Visible = false end
			if TradeGUI and TradeGUI:IsA("ScreenGui") then TradeGUI.Enabled = false end
			if Container then Container.Visible = false end
			-- Reset accepted state so the NEXT trade starts clean.
			DebugTradeTable.Player1.Accepted = false
			DebugTradeTable.Player2.Accepted = false
			-- Trade SUCCEEDED: the staged items were traded away, so drop them (do
			-- NOT return to inventory). An ABANDONED trade returns them instead.
			DebugTradeTable.Player1.Offer = {}
			DebugTradeTable.Player2.Offer = {}
			HarnessTradeActive = false; HarnessRequestArmed = false  -- disarm; re-shown request re-arms it
			showAcceptedBadge("your", false); showAcceptedBadge("their", false)
			for _, f in ipairs(onNewTrade) do pcall(f) end
			-- Fire the game's OWN item-received popup for each item you got.
			pcall(function() MH_fireReceived(received) end)
		end)
	end
end

-- Drive the LOCAL (your) accept UI to match MM2: on accept the green button
-- turns into "Cancel" (Confirm hidden, Cancel shown); on cancel it reverts.
local function setYourAcceptedUI(accepted)
	-- Refuse to accept an EMPTY trade (nothing staged on either side) — the button
	-- is greyed, so this makes every accept path (button, confirm, Rubis toggle,
	-- native-hijack) a no-op, matching MM2. Cancelling (accepted=false) still works.
	if accepted and (#DebugTradeTable.Player1.Offer + #DebugTradeTable.Player2.Offer) <= 0 then
		return
	end
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

-- Replay the load-time transparency snapshot so a trade re-opens fully opaque.
-- The close/complete fade leaves Container (and its subtree) at transparency 1;
-- this puts every captured frame back to its authored value. Only instances that
-- still exist are touched, and harness-added children (never snapshotted) are
-- left alone. GLOBAL to stay within the top-level local budget.
function restoreTradeTransparency()
	local snap = Runtime and Runtime.OrigTransparency
	if not snap then return end
	for inst, rec in pairs(snap) do
		pcall(function()
			if inst.Parent == nil then return end
			if rec.bg  ~= nil then inst.BackgroundTransparency = rec.bg end
			if rec.img ~= nil then inst.ImageTransparency      = rec.img end
			if rec.grp ~= nil then inst.GroupTransparency      = rec.grp end
		end)
	end
end

-- Begin the offline trade: hide the request, reset offers, open the Trade panel.
-- Invoked by the native MM2 Accept button, mirroring the real
-- AcceptRequest -> StartTrade -> UpdateTrade lifecycle.
function startTrade(player2Name)
	completeToken = completeToken + 1  -- cancel any pending "trade complete" close
	HarnessTradeActive = true          -- a fake trade is now open (gates Accept-button UI)
	DebugTradeTable.Player2.Player = { Name = player2Name, __fake = true }
	-- If the PREVIOUS trade was abandoned (offer still holds staged items because it
	-- never completed), give YOUR items back to the inventory before wiping — so
	-- starting a new trade never eats them.
	returnOfferToInventory("Player1")
	DebugTradeTable.Player1.Offer = {}
	DebugTradeTable.Player2.Offer = {}
	DebugTradeTable.Player1.Accepted = false
	DebugTradeTable.Player2.Accepted = false
	if RequestFrame then RequestFrame.Visible = false end
	if IsPhone then local b = findPlusBadge(); if b then pcall(function() b.Visible = false end) end end
	-- Clear any leftover accepted badges + reset panel toggles for a fresh trade.
	showAcceptedBadge("your", false); showAcceptedBadge("their", false)
	stopAcceptCooldown()
	-- Reset the Accept button to its base state: a leftover "ARE YOU SURE?" (Confirm)
	-- or Cancel from a trade you declined mid-confirm must not carry into this one.
	setVisible(TradeRoot, "Actions.Accept.Confirm", false)
	setVisible(TradeRoot, "Actions.Accept.Cancel", false)
	for _, f in ipairs(onNewTrade) do pcall(f) end

	-- Open the Trade panel. Bring the trade ScreenGui + ancestor chain on-screen.
	if TradeGUI and TradeGUI:IsA("ScreenGui") then TradeGUI.Enabled = true end
	revealAncestors(Offer1 or TradeRoot or Container)
	if Container then Container.Visible = true end
	if TradeRoot then TradeRoot.Visible = true end
	-- Undo any leftover fade from the previous trade's close so this one is opaque.
	restoreTradeTransparency()
	-- Desktop shows the inventory beside the offers (screenshot layout); phone
	-- keeps it hidden behind the native "Add Items" button until tapped.
	if ItemsPicker then
		ItemsPicker.Visible = not IsPhone
		if not IsPhone then revealAncestors(ItemsPicker) end
	end
	if not IsPhone then
		if InventoryFrame then revealAncestors(InventoryFrame) end
		if PetsFrame then revealAncestors(PetsFrame) end
	end

	-- Stamp usernames onto every offer frame (overrides "OnlyTwoChracter").
	setOfferUsername("their", "(" .. player2Name .. ")")
	setOfferUsername("your", "(" .. LocalPlayer.Name .. ")")

	RenderTrade()
	pcall(renderInventory)  -- hook the real inventory slots + append spawned items
	MH_showWeaponsTab()     -- park on Weapons so Pets can't overlay + eat the clicks
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
	HarnessTradeActive = false; HarnessRequestArmed = false  -- disarm the native-Accept hijack
	OverlayMode = false         -- idle the overlay refresh loop
	-- Unpin the real-inventory render-step bindings created by the spawner.
	pcall(function()
		for key in pairs(Runtime.InvPins or {}) do
			pcall(function() game:GetService("RunService"):UnbindFromRenderStep("MHInvPin_" .. key) end)
		end
		Runtime.InvPins = nil
	end)
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
-- ┌──────────────────────────────────────────────────────────────────────────┐
-- │  PASTE YOUR BACKGROUND IMAGE ID HERE.                                       │
-- │  Upload the image to Roblox, then put its asset id below (keep the          │
-- │  "rbxassetid://" prefix). Set to "" for no image. The picture shows at      │
-- │  ~50% transparency with a slight dark tint so the menu stays readable.      │
-- └──────────────────────────────────────────────────────────────────────────┘
local BG_IMAGE = "rbxassetid://97579398996288"

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

-- The built-in fallback panel was removed; Rubis is the only menu now. These are
-- the few shared bits the Rubis widgets / native-accept wiring still reference.
local NameBox = { Text = "Player2" }   -- plain holder: Rubis sets .Text, currentName reads it
local function currentName()
	local n = tostring(NameBox and NameBox.Text)
	if n == "" or n == "nil" then n = "Player2" end
	return n
end
table.insert(onNewTrade, function() OfferMode = "Player1" end)
-- Re-paint your fake side a few times a second so the real game's own trade
-- render can't overwrite the fake items while Overlay is on.
task.spawn(function()
	while true do
		if OverlayMode then pcall(RenderTrade) end
		task.wait(0.4)
	end
end)
-- (No continuous Accept-button loop: it ran on EVERY trade — including real ones —
-- and greyed/disabled the native button. The grey cover is an opaque frame the game
-- never touches, so RenderTrade setting it once is enough; and updateAcceptButtonUI
-- now no-ops unless a HARNESS fake trade is active, so real trades are left alone.)
-- Flat, name-sorted index of the whole catalog (weapons + pets), rebuildable
-- when the real catalog finishes loading in the background.
local spawnIndex = {}
local function buildSpawnIndex()
	spawnIndex = {}
	_G.MH_NameToKey = nil        -- rebuilt from whatever catalog we have now
	for k, v in pairs(ItemDB) do
		-- Only real, individually-tradeable weapons (Knife / Gun). This drops the
		-- non-tradeable "Item Pack" / Misc bundles that showed as fake entries.
		if type(v) == "table" and (v.ItemType == "Knife" or v.ItemType == "Gun") then
			local nm = tostring(v.ItemName or v.Name or k)
			-- The LIVE catalog stores chroma skins as the BASE name + Chroma flag
			-- ("Seer" + Chroma=true) — prefix it so "chroma" searches actually match.
			if v.Chroma ~= nil and not nm:lower():find("chroma", 1, true) then
				nm = "Chroma " .. nm
			end
			table.insert(spawnIndex, { key = k, name = nm, cat = "Weapons", rarity = v.Rarity })
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
-- Look like an item DB? (a table whose values carry ItemType / Rarity).
local function looksLikeItemDB(t)
	if type(t) ~= "table" then return false end
	local n = 0
	for _, v in pairs(t) do
		n = n + 1
		if type(v) == "table" and (rawget(v, "ItemType") or rawget(v, "Rarity") or rawget(v, "Image")) then return true end
		if n > 4 then break end
	end
	return false
end

-- Try to require the game's item-database ModuleScript directly (client-side,
-- no remote) — the cleanest source, exactly like the reference spawner:
--   require(ReplicatedStorage.Database.Sync.Item)
local function requireItemDB()
	local rs = game:GetService("ReplicatedStorage")
	local paths = {
		{ "Database", "Sync", "Item" }, { "Sync", "Item" }, { "Database", "Item" },
		{ "Modules", "Sync", "Item" }, { "Item" },
	}
	for _, p in ipairs(paths) do
		local node = rs
		for _, seg in ipairs(p) do node = node and node:FindFirstChild(seg) end
		if node and node:IsA("ModuleScript") then
			local ok, mod = pcall(require, node)
			if ok and looksLikeItemDB(mod) then return mod, node.Parent end
		end
	end
	-- last resort: scan for any ModuleScript named Item that requires to an item DB
	for _, m in ipairs(rs:GetDescendants()) do
		if m:IsA("ModuleScript") and (m.Name == "Item" or m.Name == "Items") then
			local ok, mod = pcall(require, m)
			if ok and looksLikeItemDB(mod) then return mod, m.Parent end
		end
	end
	return nil
end

-- Read the LIVE catalog. First try require() on the item ModuleScript; if that
-- fails, scan memory (getgc) for the SyncedData table the game already cached.
local function loadLiveCatalog()
	local src
	local reqItem, parent = requireItemDB()
	if reqItem then
		src = { Item = reqItem }
		-- Also require the sibling Pets / Rarity modules so colours + pets are LIVE
		-- too (require Item alone left rarity colours on the embedded fallback).
		if parent then
			local function reqSib(...)
				for _, name in ipairs({ ... }) do
					local n = parent:FindFirstChild(name)
					if n and n:IsA("ModuleScript") then
						local ok, m = pcall(require, n)
						if ok and type(m) == "table" then return m end
					end
				end
			end
			src.Pets = reqSib("Pets", "Pet")
			src.Rarity = reqSib("Rarity", "RarityColor", "RarityColors", "Rarities")
		end
	else
		local getgcf = (type(getgc) == "function" and getgc)
			or (rawget(_G, "getgc")) or (getgenv and type(getgenv().getgc) == "function" and getgenv().getgc) or nil
		if getgcf then
			pcall(function()
				for _, o in pairs(getgcf(true)) do
					if type(o) == "table" and looksLikeItemDB(rawget(o, "Item")) then
						src = { Item = rawget(o, "Item"), Pets = rawget(o, "Pets"), Rarity = rawget(o, "Rarity") }
						break
					end
				end
			end)
		end
	end
	-- If Pets/Rarity are still missing (require only got Item), grab them from
	-- memory so rarity COLOURS and pets are the game's real ones too.
	if src and (type(src.Pets) ~= "table" or type(src.Rarity) ~= "table") then
		local getgcf2 = (type(getgc) == "function" and getgc)
			or (getgenv and type(getgenv().getgc) == "function" and getgenv().getgc) or nil
		if getgcf2 then
			pcall(function()
				for _, o in pairs(getgcf2(true)) do
					if type(o) == "table" and looksLikeItemDB(rawget(o, "Item")) then
						if type(src.Pets) ~= "table" then src.Pets = rawget(o, "Pets") end
						if type(src.Rarity) ~= "table" then src.Rarity = rawget(o, "Rarity") end
						break
					end
				end
			end)
		end
	end
	if src and looksLikeItemDB(src.Item) then
		ItemDB = src.Item
		Database.Weapons = ItemDB
		if type(src.Pets) == "table" then PetDB = src.Pets; Database.Pets = PetDB end
		-- Merge live rarity COLOURS in per-tier, keeping the embedded colour for
		-- any tier the live table lacks or stores in a shape we can't read. This
		-- avoids wiping every plate to grey if the module's format is unexpected.
		if type(src.Rarity) == "table" then
			for tier, v in pairs(src.Rarity) do
				local c = toColor3(v)
				if c then Rarity[tier] = c end
			end
		end
		RealCatalog = true
		CatalogStatus = "LIVE catalog: " .. countKeys(ItemDB) .. " items"
		buildSpawnIndex()
		renderInventory()
		if onCatalogLoaded then pcall(onCatalogLoaded) end
		return src
	end
	return nil, "item DB not found (require + getgc both failed) — open inventory once, retry"
end


-- Spawn `amount` copies.
--  · Normal mode: into the trade's Add Items inventory AND the game's own
--    (client-side) inventory: the ProfileData count is set and PINNED every
--    frame so the game can't reset it, then the game's inventory-refresh
--    Bindable is poked — the game then renders the item natively (FX badges,
--    rarity, everything). Nothing is sent to the server.
--  · "Add to Player 2 side" ON: the item goes STRAIGHT into Player2's offer —
--    the fake player's side is filled ONLY by spawning, never from your
--    inventory. (Your side is filled by tapping your inventory as usual.)
-- The inventory panel is NOT auto-opened here.
local function spawnEntry(it, amount)
	amount = math.max(1, math.floor(tonumber(amount) or 1))
	-- DIAGNOSTIC: print the spawned item's real fields to the console (F9). Lets us
	-- identify the exact flag the game uses for the FX badge. Remove once pinned.
	pcall(function()
		local db = (it.cat == "Pets") and PetDB or ItemDB
		local d = db and db[it.key]
		if type(d) == "table" then
			local fs = {}
			for k, v in pairs(d) do fs[#fs + 1] = tostring(k) .. "=" .. tostring(v) end
			table.sort(fs)
			print("[MHFields] " .. tostring(it.key) .. " | " .. table.concat(fs, ", "))
		end
	end)
	if OfferMode == "Player2" and not OverlayMode then
		local offer = DebugTradeTable.Player2.Offer
		local entry
		for _, e in ipairs(offer) do
			if e[1] == it.key and e[3] == it.cat then entry = e break end
		end
		if entry then entry[2] = entry[2] + amount
		elseif #offer >= 4 then return 0                 -- live cap: 4 stacks
		else entry = { it.key, amount, it.cat }; table.insert(offer, entry) end
		DebugTradeTable.Player1.Accepted = false
		DebugTradeTable.Player2.Accepted = false
		RenderTrade()
		if startAcceptCooldown then startAcceptCooldown() end
		return entry[2]
	end
	local list = (it.cat == "Pets") and SpawnedPets or SpawnedWeapons
	list[it.key] = (list[it.key] or 0) + amount
	-- Mirror into the game's REAL inventory GUI (client-side ProfileData pin).
	pcall(function()
		local rs = game:GetService("ReplicatedStorage")
		local mods = rs:FindFirstChild("Modules")
		local prof = mods and mods:FindFirstChild("ProfileData")
		prof = prof and require(prof)
		local bucket = prof and ((it.cat == "Pets") and prof.Pets or prof.Weapons)
		if type(bucket) ~= "table" or type(bucket.Owned) ~= "table" then return end
		bucket.Owned[it.key] = list[it.key]
		-- Remember it as ours: the skin learner walks Owned and must not waste a
		-- server round-trip on an item that only exists inside this harness.
		_G.MH_FakeOwned = _G.MH_FakeOwned or {}
		_G.MH_FakeOwned[it.key] = true
		Runtime.InvPins = Runtime.InvPins or {}
		if not Runtime.InvPins[it.key] then
			Runtime.InvPins[it.key] = true
			-- Re-assert every frame so the game's own sync can't wipe the count.
			game:GetService("RunService"):BindToRenderStep("MHInvPin_" .. it.key, 0, function()
				bucket.Owned[it.key] = ((it.cat == "Pets") and SpawnedPets or SpawnedWeapons)[it.key]
			end)
		end
		-- Poke the game's local inventory-refresh event so its GUI re-renders.
		pcall(function() rs.Remotes.Inventory.InventoryDataChanged:Fire() end)
	end)
	renderInventory()     -- refresh the trade's Add Items grid (not opened here)
	return list[it.key]
end

--==============================================================================
-- CONFIGS — save the whole Add-Items inventory as a named preset and spawn it
-- back with one press. Persisted to a file (executor file API) + an in-session
-- global so they survive re-runs; a built-in preset is always available.
-- All GLOBAL so both the Rubis menu and the built-in panel can call them.
--==============================================================================
function MH_Presets()
	-- No built-in preset: the old "Godly Pack" used display NAMES as keys (e.g.
	-- SharkSeeker, whose real catalog key is NERFGUN), so its items rendered without
	-- icons and never spawned into the real inventory. Configs now contain ONLY what
	-- you save yourself (real spawned keys), which apply correctly.
	return {}
end
function MH_LoadConfigs()
	local out = {}
	for k, v in pairs(MH_Presets()) do out[k] = v end               -- presets first
	pcall(function()
		if isfile and isfile("MollyHub_configs.json") and readfile then
			local d = game:GetService("HttpService"):JSONDecode(readfile("MollyHub_configs.json"))
			if type(d) == "table" then for k, v in pairs(d) do out[k] = v end end
		end
	end)
	local g = (getgenv and getgenv()) or _G                          -- in-session copy
	if type(g.MollyHubConfigs) == "table" then for k, v in pairs(g.MollyHubConfigs) do out[k] = v end end
	return out
end
function MH_SaveConfigs(t)
	local presets = MH_Presets()
	local save = {}
	for k, v in pairs(t) do if presets[k] == nil then save[k] = v end end  -- don't persist presets
	local g = (getgenv and getgenv()) or _G
	g.MollyHubConfigs = save
	pcall(function() writefile("MollyHub_configs.json", game:GetService("HttpService"):JSONEncode(save)) end)
end
function MH_ConfigNames()
	local names = {}
	for k in pairs(MH_LoadConfigs()) do names[#names + 1] = k end
	table.sort(names)
	return names
end
function MH_SaveCurrent(name)
	if not name or name == "" then return false end
	local cfgs = MH_LoadConfigs()
	local w, p = {}, {}
	for k, a in pairs(SpawnedWeapons) do if k ~= "DefaultKnife" and k ~= "DefaultGun" then w[k] = a end end
	for k, a in pairs(SpawnedPets) do p[k] = a end
	cfgs[name] = { Weapons = w, Pets = p }
	MH_SaveConfigs(cfgs)
	return true
end
function MH_DeleteConfig(name)
	if MH_Presets()[name] ~= nil then return false end               -- can't delete a preset
	local cfgs = MH_LoadConfigs()
	cfgs[name] = nil
	MH_SaveConfigs(cfgs)
	return true
end
function MH_ApplyConfig(name)
	local c = MH_LoadConfigs()[name]
	if type(c) ~= "table" then return false end
	local prev = OfferMode
	OfferMode = "Player1"  -- config items go into YOUR inventory, not P2's offer
	for k, a in pairs(c.Weapons or {}) do pcall(spawnEntry, { key = k, cat = "Weapons", name = k }, a) end
	for k, a in pairs(c.Pets or {}) do pcall(spawnEntry, { key = k, cat = "Pets", name = k }, a) end
	OfferMode = prev
	return true
end

-- Show the GAME'S OWN "you received an item" popup (CrossPlatform.NewItem.Medium)
-- DIRECTLY — set its icon / name / rarity plate / tags and reveal it, one item at
-- a time, advancing on the native Claim button. Uses the real game GUI (no custom
-- popup). GLOBAL (no top-level local).
function MH_fireReceived(list)
	if type(list) ~= "table" or #list == 0 then return end
	-- Resolve the native popup (prefer the CrossPlatform one, fall back to MainGUI).
	local pop
	pcall(function()
		local cp = PlayerGui:FindFirstChild("CrossPlatform")
		pop = cp and cp:FindFirstChild("NewItem")
		if not (pop and pop:FindFirstChild("Medium")) then
			local mg = PlayerGui:FindFirstChild("MainGUI")
			local gn = mg and mg:FindFirstChild("Game")
			pop = gn and gn:FindFirstChild("NewItem")
		end
	end)
	local medium = pop and pop:FindFirstChild("Medium")
	if not medium then return end
	local card  = resolve(medium, "Container.NewItem")   -- item slot: Icon / ItemName / Tags
	local title = resolve(medium, "Container.Title")
	local claim = resolve(medium, "Container.Claim")
	local scale = resolve(medium, "Container.UIScale")
	-- Resolve the queue of items to reveal.
	local queue = {}
	for _, e in ipairs(list) do
		local key = e.key or e[1]
		local cat = e.cat or e[3] or "Weapons"
		local amount = e.amount or e[2] or 1
		if key and key ~= "DefaultKnife" and key ~= "DefaultGun" then
			local db = (cat == "Pets") and PetDB or ItemDB
			queue[#queue + 1] = { key = key, amount = amount, data = db[key] }
		end
	end
	if #queue == 0 then return end
	if Runtime.ClaimConn then pcall(function() Runtime.ClaimConn:Disconnect() end); Runtime.ClaimConn = nil end
	local idx = 0
	local function hide()
		pcall(function() medium.Visible = false end)
		if Runtime.ClaimConn then pcall(function() Runtime.ClaimConn:Disconnect() end); Runtime.ClaimConn = nil end
	end
	local function showNext()
		idx = idx + 1
		local it = queue[idx]
		if not it then hide(); return end
		local d = it.data or { ItemName = it.key, Rarity = "Common", Image = "" }
		if card then
			-- Paint the native card WITHOUT paintSlot (it would reset the card's position).
			setProp(card, "Container.Icon", "Image", getImage(d.Image))
			setProp(card, "ItemName.Label", "Text", d.ItemName or d.Name or it.key)
			local plate = (d.Rarity == "Common") and RARITY_GREY or (Rarity[d.Rarity] or RARITY_GREY)
			setProp(card, "ItemName", "BackgroundColor3", plate)
			setProp(card, "ItemName.BG", "ImageColor3", plate)
			setProp(card, "Container.Amount", "Text", (it.amount and it.amount > 1) and ("x" .. it.amount) or "")
			pcall(function() applyTags(card, d) end)
		end
		if title and title:IsA("TextLabel") then pcall(function() title.Text = tostring(d.Rarity or "") end) end
		if scale then pcall(function() scale.Scale = 1 end) end  -- native anim may leave it at 0
		pcall(function() pop.Visible = true end)
		pcall(function() medium.Visible = true end)
	end
	if claim then
		pcall(function() claim.Active = true end)
		-- Advance on the native Claim; defer a frame so the game's own handler (which
		-- may hide Medium) runs first and our next-item reveal wins.
		Runtime.ClaimConn = claim.MouseButton1Click:Connect(function()
			task.spawn(function() task.wait() showNext() end)
		end)
	end
	showNext()
end

-- Compact structural dump of a table (2 levels), for diagnosing item records.
-- GLOBAL.
function MH_infoDump(info, depth)
	depth = depth or 0
	if type(info) ~= "table" then return tostring(info) end
	local out, n = {}, 0
	for k, v in pairs(info) do
		n = n + 1
		if n > 24 then out[#out + 1] = "..."; break end
		local t = typeof(v)
		local extra = ""
		if t == "Instance" then pcall(function() extra = v.ClassName .. "/" .. v.Name end)
		elseif t == "string" then extra = tostring(v):sub(1, 28)
		elseif t == "number" or t == "boolean" then extra = tostring(v)
		elseif t == "Color3" then extra = "color"
		elseif t == "table" and depth < 1 then extra = MH_infoDump(v, depth + 1)
		elseif t == "table" then extra = "{..}" end
		out[#out + 1] = tostring(k) .. "=" .. t .. (extra ~= "" and "(" .. extra .. ")" or "")
	end
	return "{" .. table.concat(out, " ") .. "}"
end

-- Pull the game's OWN item record for a key. The item DATABASE is an upvalue of
-- the ItemUtil helper functions (ItemUtil = EquipService.EquipItem upvalue #1),
-- so we search those upvalue tables directly for the key — no need to guess the
-- getter's (category,name) signature. Returns (info, detail). GLOBAL.
function MH_getItemInfo(key)
	local rs = game:GetService("ReplicatedStorage")
	local cs = rs:FindFirstChild("ClientServices")
	local esM = cs and cs:FindFirstChild("EquipService")
	if not esM then return nil, "no ES module" end
	local okReq, ES = pcall(require, esM)
	if not okReq or type(ES) ~= "table" then return nil, "ES require fail" end
	if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then
		return nil, "no debug.getupvalue"
	end
	local IU
	if type(ES.EquipItem) == "function" then
		pcall(function() IU = debug.getupvalue(ES.EquipItem, 1) end)
	end
	if type(IU) ~= "table" then return nil, "no ItemUtil" end
	local wantLow = tostring(key):lower()
	local function looksLikeItem(v)
		return type(v) == "table" and (v.ItemType ~= nil or v.Rarity ~= nil
			or v.Value ~= nil or v.Chroma ~= nil or v.Name ~= nil)
	end
	-- collect every key-matching sub-table across the DB (bounded depth)
	local best, any, where
	local function walk(t, depth, seen, tag)
		if seen[t] then return end
		seen[t] = true
		local ok = pcall(function()
			for k, v in pairs(t) do
				if type(v) == "table" then
					if type(k) == "string" and k:lower() == wantLow then
						any = any or v; where = where or tag
						if looksLikeItem(v) and not best then best = v; where = tag end
					end
					if depth < 3 and not best then walk(v, depth + 1, seen, tag) end
				end
			end
		end)
		return ok
	end
	-- 1) DBs closed over by the util functions
	for _, fname in ipairs({ "GetItemInfo", "FindItemInfo", "GetItemImage",
		"ItemExists", "GetDisplayName", "GetRarityColor" }) do
		local f = IU[fname]
		if type(f) == "function" then
			for i = 1, 20 do
				local okv, uv = pcall(debug.getupvalue, f, i)
				if not okv then break end
				if type(uv) == "table" then
					walk(uv, 0, {}, fname .. "#" .. i)
					if best then return best, "db:" .. where end
				end
			end
		end
	end
	if best then return best, "db:" .. tostring(where) end
	if any then return any, "any:" .. tostring(where) end
	-- 2) last resort: try calling the getters a few plausible ways
	for _, fname in ipairs({ "GetItemInfo", "FindItemInfo" }) do
		local g = IU[fname]
		if type(g) == "function" then
			local tries = { { key }, { IU, key } }
			for _, c in ipairs({ "Gun", "Guns", "Knife", "Knives", "Weapon", "Weapons" }) do
				tries[#tries + 1] = { c, key }; tries[#tries + 1] = { key, c }
			end
			for _, a in ipairs(tries) do
				local ok, res = pcall(function() return g(table.unpack(a)) end)
				if ok and type(res) == "table" then return res, "call:" .. fname end
			end
		end
	end
	return nil, "key not in any DB upvalue"
end

-- Load a Roblox asset id into a hand-holdable Instance, trying every load method
-- the executor may allow. Returns (instance, detail). GLOBAL.
function MH_loadAssetModel(assetId)
	local idNum
	if type(assetId) == "number" then idNum = math.floor(assetId)
	else idNum = tonumber(tostring(assetId):match("%d+")) end
	if not idNum or idNum <= 0 then return nil, "bad asset id" end
	local idStr = "rbxassetid://" .. string.format("%d", idNum)
	local loaded, how
	local objs
	if pcall(function() objs = game:GetObjects(idStr) end) and type(objs) == "table" and objs[1] then
		local f = Instance.new("Folder")
		for _, o in ipairs(objs) do pcall(function() o.Parent = f end) end
		loaded, how = f, "GetObjects"
	end
	if not loaded then
		local cont
		if pcall(function() cont = game:GetService("InsertService"):LoadAsset(idNum) end) and cont then
			loaded, how = cont, "LoadAsset"
		end
	end
	if not loaded then
		local cont
		if pcall(function() cont = game:GetService("InsertService"):LoadAssetVersion(idNum) end) and cont then
			loaded, how = cont, "LoadAssetVersion"
		end
	end
	if not loaded then return nil, "asset load failed:" .. string.format("%d", idNum) end
	local pick
	if loaded:IsA("Tool") or loaded:IsA("Model") or loaded:IsA("BasePart") then pick = loaded end
	if not pick then
		for _, o in ipairs(loaded:GetDescendants()) do
			if o:IsA("Tool") or o:IsA("Model") then pick = o; break end
		end
	end
	if not pick then
		for _, o in ipairs(loaded:GetDescendants()) do
			if o:IsA("BasePart") then pick = o; break end
		end
	end
	if pick then
		return pick, how .. ":" .. string.format("%d", idNum) .. "[" .. pick.ClassName .. "]"
	end
	local kinds = {}
	for _, o in ipairs(loaded:GetDescendants()) do
		kinds[#kinds + 1] = o.ClassName
		if #kinds >= 8 then break end
	end
	return nil, how .. ":no part{" .. table.concat(kinds, ",") .. "}"
end

-- Build a hand-holdable Instance from an item record: a renderable Instance in
-- the record, else its asset id loaded client-side, else a Part+SpecialMesh from
-- its MeshId/TextureId. Returns (clone, detail). GLOBAL.
function MH_buildHandleFromInfo(info)
	if type(info) ~= "table" then return nil, "no info" end
	-- a) any renderable Instance inside the record (2 levels)
	local function findInst(t, depth)
		for _, v in pairs(t) do
			if typeof(v) == "Instance" then
				if v:IsA("Model") or v:IsA("Tool") or v:IsA("BasePart") then return v end
			elseif type(v) == "table" and depth < 2 then
				local r = findInst(v, depth + 1)
				if r then return r end
			end
		end
		return nil
	end
	local inst = findInst(info, 0)
	if inst then return inst:Clone(), "instance:" .. inst.ClassName .. "/" .. inst.Name end
	-- b) a Roblox asset id (the item's own model) -> load it client-side
	local assetId
	for k, v in pairs(info) do
		local lk = tostring(k):lower()
		if type(v) == "number" and v > 100000
			and (lk == "itemid" or lk == "assetid" or lk == "modelid" or lk == "id") then
			assetId = assetId or v
		end
	end
	if assetId then
		-- b1) try it as a MODEL (GetObjects/LoadAsset) — ownership-gated
		local m, md = MH_loadAssetModel(assetId)
		if m then return m, md end
		-- b2) model load blocked → try it as a MESH. Mesh & texture assets render
		-- on ANY account (not ownership-gated like models), which is how a spawner
		-- can work "on all accounts". Texture comes from the item's Image asset id.
		local idNum = math.floor(assetId)
		local part = Instance.new("Part")
		part.Size = Vector3.new(1, 1, 1)
		part.CanCollide = false
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.FileMesh
		mesh.MeshId = "rbxassetid://" .. string.format("%d", idNum)
		local img = tostring(info.Image or "")
		local texNum = img:match("[?&]id=(%d+)") or img:match("(%d%d%d%d%d+)")
		if texNum then mesh.TextureId = "rbxassetid://" .. texNum end
		mesh.Parent = part
		return part, "meshTry:" .. string.format("%d", idNum) .. (texNum and ("+tex" .. texNum) or "")
	end
	-- c) MeshId / TextureId strings in the record
	local meshId, texId, color
	local function scan(t, depth)
		for k, v in pairs(t) do
			local lk = tostring(k):lower()
			if type(v) == "string" then
				local looksAsset = v:find("rbxasset") ~= nil or v:match("^%d+$") ~= nil
				if looksAsset and lk:find("mesh") then meshId = meshId or v end
				if looksAsset and (lk:find("tex") or lk:find("decal")) then texId = texId or v end
			elseif typeof(v) == "Color3" and lk:find("col") then color = color or v
			elseif type(v) == "table" and depth < 2 then scan(v, depth + 1) end
		end
	end
	scan(info, 0)
	if meshId then
		if meshId:match("^%d+$") then meshId = "rbxassetid://" .. meshId end
		if texId and texId:match("^%d+$") then texId = "rbxassetid://" .. texId end
		local part = Instance.new("Part")
		part.Size = Vector3.new(1, 1, 1)
		local m = Instance.new("SpecialMesh")
		m.MeshType = Enum.MeshType.FileMesh
		m.MeshId = meshId
		if texId then m.TextureId = texId end
		m.Parent = part
		if color then pcall(function() part.Color = color end) end
		return part, "mesh:" .. meshId
	end
	return nil, "no model/mesh in record"
end

-- Neutralise a clone (scripts off, non-colliding, massless) and attach it to
-- YOUR character's hand (Tool auto-equips; else welds to the right hand). Client
-- side only. Returns (ok, detail). GLOBAL.
function MH_attachToHand(clone)
	local plr = game:GetService("Players").LocalPlayer
	local char = plr and plr.Character
	if not char then if clone then clone:Destroy() end return false, "no character" end
	local old = char:FindFirstChild("__MHequip"); if old then old:Destroy() end
	clone.Name = "__MHequip"
	for _, s in ipairs(clone:GetDescendants()) do
		if s:IsA("BaseScript") then pcall(function() s.Disabled = true end)
		elseif s:IsA("BasePart") then
			pcall(function() s.CanCollide = false; s.Massless = true; s.Anchored = false end)
		end
	end
	if clone:IsA("BasePart") then
		pcall(function() clone.CanCollide = false; clone.Massless = true; clone.Anchored = false end)
	end
	if clone:IsA("Tool") then
		if not clone:FindFirstChild("Handle") then pcall(function() clone.RequiresHandle = false end) end
		clone.Parent = char
		return true, "tool in hand"
	end
	local hand = char:FindFirstChild("RightHand") or char:FindFirstChild("Right Arm")
	if not hand then clone:Destroy(); return false, "no right hand" end
	-- NB: .PrimaryPart only exists on Model — a Folder/Part clone would throw.
	local prim
	if clone:IsA("BasePart") then
		prim = clone
	else
		pcall(function() prim = clone.PrimaryPart end)
		if not prim then
			local h = clone:FindFirstChild("Handle")
			if h and h:IsA("BasePart") then prim = h end
		end
		prim = prim or clone:FindFirstChildWhichIsA("BasePart", true)
	end
	if not prim then clone:Destroy(); return false, "no primary part" end
	if clone:IsA("Model") and not clone.PrimaryPart then pcall(function() clone.PrimaryPart = prim end) end
	-- unanchor everything, otherwise the weld can't move it with the arm
	for _, p in ipairs(clone:GetDescendants()) do
		if p:IsA("BasePart") then pcall(function() p.Anchored = false end) end
	end
	pcall(function() prim.Anchored = false end)
	local o = _G.MH_HandOffset or { 0, -1, 0, 0, 0, 0 }
	local w = Instance.new("Weld")
	w.Part0 = hand
	w.Part1 = prim
	w.C0 = CFrame.new(o[1] or 0, o[2] or -1, o[3] or 0)
		* CFrame.Angles(math.rad(o[4] or 0), math.rad(o[5] or 0), math.rad(o[6] or 0))
	w.Parent = prim
	clone.Parent = char
	return true, "welded to hand"
end

-- "rbxassetid://123" / "...?assetId=123" / 123 -> "123" ("" if none).
-- NB: never take the FIRST number. MM2 icons look like
-- "...Asset.ashx?format=png&width=250&height=250&assetId=238546577", so the
-- first run of digits is the image WIDTH — using it set TextureId to asset 250
-- and the weapon rendered white. Prefer the explicit id parameter, then fall
-- back to the LONGEST run of digits. GLOBAL.
function MH_shortId(s)
	local t = tostring(s or "")
	local id = t:match("[Aa]sset[Ii][Dd]=(%d+)") or t:match("[?&]id=(%d+)")
		or t:match("rbxassetid://(%d+)") or t:match("rbxasset://.-(%d+)")
	if id then return id end
	local best = ""
	for run in t:gmatch("%d+") do
		if #run > #best then best = run end
	end
	return best
end

-- MY character's weapon display for one slot (Character.DisplayRefKnife/Gun ->
-- a Part carrying the weapon's SpecialMesh). This is how MM2 shows the equipped
-- weapon on the body, so its mesh ids are REAL weapon meshes.
-- Returns (part, meshId, texId). GLOBAL.
function MH_displayPart(itemType)
	local plr = game:GetService("Players").LocalPlayer
	local char = plr and plr.Character
	if not char then return nil, "", "" end
	return MH_displayPart2(char, itemType)
end

-- Read a display's mesh id, texture id AND its SCALE. The scale matters: a
-- SpecialMesh renders at (native mesh size x Scale), and MM2 sets a different
-- Scale per weapon — so repointing MeshId while leaving the previous item's
-- Scale in place is what made a swapped-in knife come out huge.
-- Returns (mesh, tex, sx, sy, sz). GLOBAL.
function MH_meshFieldsOf(part)
	local mid, tid, sx, sy, sz, kind = "", "", nil, nil, nil, nil
	if not part then return mid, tid end
	local m = (part:IsA("SpecialMesh") and part) or part:FindFirstChildWhichIsA("SpecialMesh", true)
	if m then
		pcall(function()
			mid, tid = tostring(m.MeshId), tostring(m.TextureId)
			sx, sy, sz = m.Scale.X, m.Scale.Y, m.Scale.Z
			kind = "scale"                       -- a MULTIPLIER over the mesh
		end)
	elseif part:IsA("MeshPart") then
		pcall(function()
			mid, tid = tostring(part.MeshId), tostring(part.TextureID)
			sx, sy, sz = part.Size.X, part.Size.Y, part.Size.Z
			kind = "size"                        -- ABSOLUTE studs, not a multiplier
		end)
	end
	return mid, tid, sx, sy, sz, kind
end

-- CFrame <-> a plain array of its 12 components, so it survives JSON. GLOBAL.
function MH_cfTo(cf)
	local t
	pcall(function() t = { cf:GetComponents() } end)
	return t
end
function MH_cfFrom(t)
	if type(t) ~= "table" or #t < 12 then return nil end
	local cf
	pcall(function() cf = CFrame.new(table.unpack(t)) end)
	return cf
end

-- Read EVERYTHING that makes a weapon look like itself, not just its mesh:
-- the mesh's Offset and VertexColor, and the Attachment CFrame that decides
-- where the weapon sits on the body. Skipping these is why a swapped weapon
-- could sit at the wrong angle even with the right mesh. GLOBAL.
function MH_readSkin(part)
	if not part then return nil end
	local mid, tid, sx, sy, sz, kind = MH_meshFieldsOf(part)
	local rec = MH_skinRecord(mid, tid, sx, sy, sz, kind)
	if not rec then return nil end
	local m = (part:IsA("SpecialMesh") and part) or part:FindFirstChildWhichIsA("SpecialMesh", true)
	if m then
		pcall(function()
			rec.ox, rec.oy, rec.oz = m.Offset.X, m.Offset.Y, m.Offset.Z
			rec.vx, rec.vy, rec.vz = m.VertexColor.X, m.VertexColor.Y, m.VertexColor.Z
		end)
	end
	pcall(function()
		local at = part:FindFirstChildWhichIsA("Attachment")
		if at then rec.cf = MH_cfTo(at.CFrame) end
	end)
	return rec
end

-- Collect the mesh/texture ids of every weapon display the client can already
-- see (Workspace.WeaponDisplays + every character's DisplayRef parts). Pure
-- diagnostics: it proves whether real weapon meshes exist client-side and shows
-- their ids. Returns a short string. GLOBAL.
function MH_harvestDisplays(limit)
	limit = limit or 10
	local out, seen = {}, {}
	local function grab(tag, root)
		if not root then return end
		local list = {}
		local okd, ds = pcall(function() return root:GetDescendants() end)
		if okd then for _, dd in ipairs(ds) do list[#list + 1] = dd end end
		if root:IsA("BasePart") then list[#list + 1] = root end
		for _, dd in ipairs(list) do
			if #out >= limit then return end
			local mid, tid = "", ""
			if dd:IsA("SpecialMesh") then
				pcall(function() mid = tostring(dd.MeshId); tid = tostring(dd.TextureId) end)
			elseif dd:IsA("MeshPart") then
				pcall(function() mid = tostring(dd.MeshId); tid = tostring(dd.TextureID) end)
			end
			mid = MH_shortId(mid)
			if mid ~= "" and not seen[mid] then
				seen[mid] = true
				local nm = tostring((dd.Parent and dd.Parent.Name) or dd.Name)
				out[#out + 1] = tag .. "/" .. nm .. "=" .. mid
					.. (MH_shortId(tid) ~= "" and ("+" .. MH_shortId(tid)) or "")
			end
		end
	end
	pcall(function() grab("WD", workspace:FindFirstChild("WeaponDisplays")) end)
	pcall(function()
		for _, p in ipairs(game:GetService("Players"):GetPlayers()) do
			local c = p.Character
			if c then
				for _, rn in ipairs({ "DisplayRefKnife", "DisplayRefGun" }) do
					local ov = c:FindFirstChild(rn)
					if ov and ov:IsA("ObjectValue") and ov.Value then
						grab(p.Name .. ":" .. rn:sub(11), ov.Value)
					end
				end
			end
		end
	end)
	if #out == 0 then return "none" end
	return table.concat(out, " ")
end

-- The 3D display is driven by REPLICATED state, not by ProfileData — so find
-- whatever attribute / StringValue currently holds the really-equipped key and
-- overwrite it locally with ours. If the display builder is client-side it will
-- rebuild the weapon FROM THE GAME'S OWN mesh database (which knows every item),
-- which is exactly what we can't do by hand. Client-only: writes to replicated
-- values never travel back up. Returns (hits, detail). GLOBAL.
function MH_markerSwap(realKey, newKey, itemType)
	local plr = game:GetService("Players").LocalPlayer
	if not plr then return 0, "no player" end
	local hits = {}
	local targets = { plr }
	for _, c in ipairs(plr:GetChildren()) do
		if not c:IsA("PlayerGui") and not c:IsA("StarterGear") then targets[#targets + 1] = c end
	end
	local char = plr.Character
	if char then
		targets[#targets + 1] = char
		local okd, ds = pcall(function() return char:GetDescendants() end)
		if okd then for _, dd in ipairs(ds) do targets[#targets + 1] = dd end end
	end
	pcall(function()
		local wd = workspace:FindFirstChild("WeaponDisplays")
		if wd then for _, dd in ipairs(wd:GetDescendants()) do targets[#targets + 1] = dd end end
	end)
	local realLow = realKey and tostring(realKey):lower() or nil
	local slotLow = tostring(itemType):lower()
	for _, inst in ipairs(targets) do
		-- (a) attributes holding the equipped key
		local oka, attrs = pcall(function() return inst:GetAttributes() end)
		if oka and type(attrs) == "table" then
			for an, av in pairs(attrs) do
				local aLow = tostring(an):lower()
				local matchVal = realLow and type(av) == "string" and av:lower() == realLow
				local matchName = (aLow == slotLow or aLow == "equipped" .. slotLow
					or aLow == slotLow .. "skin" or aLow == "current" .. slotLow)
					and type(av) == "string"
				if matchVal or matchName then
					if pcall(function() inst:SetAttribute(an, newKey) end) then
						hits[#hits + 1] = "@" .. inst.Name .. "." .. tostring(an)
					end
				end
			end
		end
		-- (b) StringValues holding the equipped key
		if inst:IsA("StringValue") then
			local nLow = inst.Name:lower()
			if (realLow and tostring(inst.Value):lower() == realLow)
				or nLow == slotLow or nLow == "equipped" .. slotLow then
				if pcall(function() inst.Value = newKey end) then
					hits[#hits + 1] = "$" .. inst.Name
				end
			end
		end
		if #hits >= 12 then break end
	end
	if #hits == 0 then return 0, "no marker (real=" .. tostring(realKey) .. ")" end
	return #hits, table.concat(hits, ",")
end

-- Hunt the CLIENT's own module tree for a mesh/texture id filed under this item.
-- MM2's item cards carry no mesh field, but the code that builds weapon displays
-- must get the mesh from somewhere client-side, so look inside every plausible
-- ModuleScript (its returned table AND its functions' upvalue tables, which is
-- where MM2 hides its databases). Returns (meshId, texId, detail). GLOBAL.
function MH_scanMeshDB(key, names)
	local want = { [tostring(key):lower()] = true }
	for _, n in ipairs(names or {}) do
		if n ~= nil and tostring(n) ~= "" then want[tostring(n):lower()] = true end
	end
	local mods = {}
	pcall(function()
		for _, dd in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
			if dd:IsA("ModuleScript") then
				local ln = dd.Name:lower()
				if ln:find("weapon") or ln:find("mesh") or ln:find("display") or ln:find("skin")
					or ln:find("cosmetic") or ln:find("item") or ln:find("asset")
					or ln:find("model") or ln:find("knife") or ln:find("gun") or ln:find("equip") then
					mods[#mods + 1] = dd
					if #mods >= 30 then break end
				end
			end
		end
	end)
	local meshId, texId, where
	local function harvest(rec, tag)
		if type(rec) ~= "table" then return end
		for k, v in pairs(rec) do
			local lk = tostring(k):lower()
			if type(v) == "string" or type(v) == "number" then
				local sv = tostring(v)
				if sv:match("%d%d%d%d%d+") then
					if lk:find("mesh") and not meshId then meshId = sv; where = tag end
					if (lk:find("tex") or lk:find("decal")) and not texId then texId = sv end
				end
			end
		end
	end
	local function walk(t, depth, seen, tag)
		if depth > 4 or seen[t] then return end
		seen[t] = true
		for k, v in pairs(t) do
			if type(v) == "table" then
				if type(k) == "string" and want[k:lower()] then harvest(v, tag .. "." .. k) end
				if not meshId then walk(v, depth + 1, seen, tag) end
			end
		end
	end
	local hasUv = type(debug) == "table" and type(debug.getupvalue) == "function"
	for _, m in ipairs(mods) do
		local okr, mod = pcall(require, m)
		if okr and type(mod) == "table" then
			pcall(function() walk(mod, 0, {}, m.Name) end)
			if not meshId and hasUv then
				for k, v in pairs(mod) do
					if type(v) == "function" then
						for i = 1, 8 do
							local oku, uv = pcall(debug.getupvalue, v, i)
							if not oku then break end
							if type(uv) == "table" then
								pcall(function() walk(uv, 0, {}, m.Name .. ":" .. tostring(k)) end)
							end
						end
					end
					if meshId then break end
				end
			end
		end
		if meshId then break end
	end
	if not meshId then return nil, nil, "no mesh in " .. #mods .. " mods" end
	return meshId, texId, "db:" .. tostring(where)
end

-- Does a database record mention this asset id anywhere inside it? Matches the
-- id as a WHOLE value ("123", 123, "rbxassetid://123", "...?id=123") — a plain
-- substring test hits any long number that merely contains it. GLOBAL.
function MH_recHasId(rec, id, depth)
	local tv = type(rec)
	if tv == "number" then return string.format("%d", math.floor(rec)) == id end
	if tv == "string" then
		return rec == id
			or rec:find("rbxassetid://" .. id, 1, true) ~= nil
			or rec:find("?id=" .. id, 1, true) ~= nil
			or rec:find("=" .. id, 1, true) ~= nil
			or rec:find("/" .. id, 1, true) ~= nil
	end
	if tv == "table" and (depth or 0) < 2 then
		for _, v in pairs(rec) do
			if MH_recHasId(v, id, (depth or 0) + 1) then return true end
		end
	end
	return false
end

-- Pull (mesh, texture) ids out of a database record, whatever shape it has:
-- a bare id, {Mesh=,Texture=}, or a nested table of ids. GLOBAL.
function MH_recIds(rec, depth)
	local tv = type(rec)
	if tv == "string" or tv == "number" then
		local s = MH_shortId(rec)
		return (#s >= 5) and s or nil, nil
	end
	if tv ~= "table" or (depth or 0) > 2 then return nil, nil end
	local mesh, tex, spare = nil, nil, {}
	for k, v in pairs(rec) do
		local lk = tostring(k):lower()
		if type(v) == "string" or type(v) == "number" then
			local sid = MH_shortId(v)
			if #sid >= 5 then
				if lk:find("mesh") and not mesh then mesh = sid
				elseif (lk:find("tex") or lk:find("decal")) and not tex then tex = sid
				else spare[#spare + 1] = sid end
			end
		elseif type(v) == "table" then
			local m2, t2 = MH_recIds(v, (depth or 0) + 1)
			if m2 and not mesh then mesh = m2 end
			if t2 and not tex then tex = t2 end
		end
	end
	if not mesh then mesh = spare[1] end
	if not tex then tex = spare[2] end
	return mesh, tex
end

-- FIND THE GAME'S WEAPON-MESH DATABASE, using the weapon you are really wearing
-- as the anchor: we know its item key AND the mesh id its display is showing, so
-- the one table in memory that maps the first to the second must be the mesh
-- database. Then just read our item out of it. Nothing is guessed and nothing is
-- sent anywhere. Returns (mesh, tex, detail). GLOBAL.
function MH_meshDBLookup(anchorMesh, anchorKeys, wantNames)
	local anchor = MH_shortId(anchorMesh)
	if anchor == "" then return nil, nil, "no anchor mesh" end
	local getgcf = (type(getgc) == "function" and getgc)
		or rawget(_G, "getgc")
		or (getgenv and type(getgenv().getgc) == "function" and getgenv().getgc) or nil
	if type(getgcf) ~= "function" then return nil, nil, "no getgc" end
	local objs
	if not pcall(function() objs = getgcf(true) end) or type(objs) ~= "table" then
		return nil, nil, "getgc failed"
	end
	local db, tag
	-- pass 1: a table indexed by the equipped item's key whose record carries the
	-- mesh id we can see. Exact, so it cannot pick the wrong table.
	for _, o in pairs(objs) do
		if type(o) == "table" then
			for _, ak in ipairs(anchorKeys) do
				if ak ~= nil and tostring(ak) ~= "" then
					local rec
					pcall(function() rec = rawget(o, ak) end)
					if rec ~= nil then
						local hit = false
						pcall(function() hit = MH_recHasId(rec, anchor, 0) end)
						if hit then db = o; tag = "key=" .. tostring(ak); break end
					end
				end
			end
		end
		if db then break end
	end
	-- pass 2: any table that holds the mesh id as a value — tells us the database
	-- exists even when its key format isn't what we assumed.
	if not db then
		local budget = 150000
		for _, o in pairs(objs) do
			local big = false
			pcall(function() big = #o > 2000 end)   -- skip bulk arrays, not databases
			if type(o) == "table" and not big then
				pcall(function()
					for k, v in pairs(o) do
						budget = budget - 1
						if budget <= 0 then error("budget", 0) end
						if MH_recHasId(v, anchor, 1) then
							db = o; tag = "val@" .. tostring(k)
							error("found", 0)
						end
					end
				end)
			end
			if db or budget <= 0 then break end
		end
	end
	if not db then return nil, nil, "no db for mesh " .. anchor end
	for _, wn in ipairs(wantNames) do
		if wn ~= nil and tostring(wn) ~= "" then
			local rec
			pcall(function() rec = rawget(db, wn) end)
			if rec ~= nil then
				local m, t
				pcall(function() m, t = MH_recIds(rec, 0) end)
				if m then return m, t, tag .. " -> " .. tostring(wn) end
			end
		end
	end
	-- found the table but not our item: show its key format so the next build can
	-- match it exactly.
	local sample = {}
	pcall(function()
		for k in pairs(db) do
			sample[#sample + 1] = tostring(k)
			if #sample >= 4 then break end
		end
	end)
	return nil, nil, tag .. " no entry; keys{" .. table.concat(sample, ",") .. "}"
end

--==============================================================================
-- CLIENT-SIDE SKIN SWAP
-- Not "spawn a weapon in your hand" — RESTYLE the weapon you are already
-- wearing. MM2 draws your equipped weapon on your body through
-- Character.DisplayRefKnife/Gun, and hands you a Tool when a round starts. Both
-- carry a mesh we can repoint locally, so one equipped gun visually becomes
-- another, for your eyes only. Nothing is sent to the server.
--==============================================================================

-- Repoint every mesh under `root` at our skin, remembering the originals so the
-- change can be undone. Returns how many meshes changed. GLOBAL.
function MH_paintMesh(root, mesh, tex, rec)
	if not root then return 0 end
	local mnum = MH_shortId(mesh)
	if mnum == "" then return 0 end
	local tnum = MH_shortId(tex)
	local scale = MH_scaleOf(rec)
	_G.MH_SkinUndo = _G.MH_SkinUndo or {}
	_G.MH_SkinSeen = _G.MH_SkinSeen or {}
	local okd, ds = pcall(function() return root:GetDescendants() end)
	if not okd then ds = {} end
	MH_normRec(rec)
	-- Clear a MeshPart overlay left by the PREVIOUS item. It hides the display it
	-- sits on, so repainting the mesh underneath changed nothing visible and the
	-- old weapon stayed on screen however many times you clicked.
	MH_dropOverlay(root, (type(rec) == "table" and rec.k == "size") and mnum or nil)
	-- A skin recorded off a MeshPart has an ABSOLUTE size, which no SpecialMesh
	-- can match. Rebuild it as a real MeshPart at that size and wear that instead.
	if type(rec) == "table" and rec.k == "size" and _G.MH_MeshPartSkins ~= false then
		local host = (root:IsA("BasePart") and root) or root:FindFirstChildWhichIsA("BasePart", true)
		if host then
			local ex = host:FindFirstChild("__MHskin")
			if ex and ex:IsA("MeshPart") and MH_shortId(ex.MeshId) == mnum then
				pcall(function() host.LocalTransparencyModifier = 1 end)  -- already on
				return 1
			end
			local mp, why = MH_makeMeshPart(mesh, tex, rec.sx, rec.sy, rec.sz)
			_G.MH_SkinNote = tostring(why)     -- surfaced in the equip diagnostic
			if mp then return MH_overlayWith(host, mp) end
		end
	end
	-- (a) a SpecialMesh can simply be repointed
	local sms = {}
	if root:IsA("SpecialMesh") then sms[1] = root end
	for _, dd in ipairs(ds) do if dd:IsA("SpecialMesh") then sms[#sms + 1] = dd end end
	local n = 0
	for _, m in ipairs(sms) do
		pcall(function()
			if not _G.MH_SkinSeen[m] then
				_G.MH_SkinSeen[m] = true
				local om, ot, os, oo, ov = m.MeshId, m.TextureId, m.Scale, m.Offset, m.VertexColor
				_G.MH_SkinUndo[#_G.MH_SkinUndo + 1] = function()
					m.MeshId = om; m.TextureId = ot; m.Scale = os
					m.Offset = oo; m.VertexColor = ov
				end
			end
			m.MeshType = Enum.MeshType.FileMesh
			m.MeshId = "rbxassetid://" .. mnum
			if tnum ~= "" then m.TextureId = "rbxassetid://" .. tnum end
			-- the item's own scale, else keep whatever the game had
			if scale then m.Scale = scale end
			if type(rec) == "table" then
				if rec.ox and rec.oy and rec.oz then m.Offset = Vector3.new(rec.ox, rec.oy, rec.oz) end
				if rec.vx and rec.vy and rec.vz then
					m.VertexColor = Vector3.new(rec.vx, rec.vy, rec.vz)
				end
			end
			n = n + 1
		end)
	end
	-- Where the weapon sits on the body is the display Attachment's CFrame, and
	-- it is per-weapon too — the right mesh at the wrong attachment hangs at the
	-- wrong angle.
	if n > 0 and type(rec) == "table" and rec.cf then
		pcall(function()
			local at = root:FindFirstChildWhichIsA("Attachment")
			if not at then return end
			local want = MH_cfFrom(rec.cf)
			if not want then return end
			if not _G.MH_SkinSeen[at] then
				_G.MH_SkinSeen[at] = true
				local was = at.CFrame
				_G.MH_SkinUndo[#_G.MH_SkinUndo + 1] = function() at.CFrame = was end
			end
			at.CFrame = want
		end)
	end
	if n > 0 then return n end
	-- (b) no SpecialMesh: this skin is a MeshPart, and MeshPart.MeshId is
	-- read-only at runtime. Hide it for our eyes only and weld our own meshed
	-- part in its place, so MeshPart-shaped skins work too.
	local mps = {}
	if root:IsA("MeshPart") then mps[1] = root end
	for _, dd in ipairs(ds) do if dd:IsA("MeshPart") then mps[#mps + 1] = dd end end
	-- (c) still nothing? a plain Part (a Tool handle with no mesh) can be given
	-- a SpecialMesh of its own.
	if #mps == 0 then
		local h = root:FindFirstChild("Handle")
		if not (h and h:IsA("BasePart")) then h = root:FindFirstChildWhichIsA("BasePart", true) end
		if h and not h:IsA("MeshPart") then
			pcall(function()
				local sm = h:FindFirstChild("__MHmesh")
				if not sm then
					sm = Instance.new("SpecialMesh")
					sm.Name = "__MHmesh"
					sm.Parent = h
					_G.MH_SkinUndo[#_G.MH_SkinUndo + 1] = function() sm:Destroy() end
				end
				sm.MeshType = Enum.MeshType.FileMesh
				sm.MeshId = "rbxassetid://" .. mnum
				if tnum ~= "" then sm.TextureId = "rbxassetid://" .. tnum end
				if scale then sm.Scale = scale end
				n = n + 1
			end)
		end
		return n
	end
	for _, mp in ipairs(mps) do n = n + MH_overlayPart(mp, mnum, tnum, scale) end
	return n
end

-- The scale stored with a learned skin, times your own _G.MH_SkinScale nudge.
-- nil means "leave the scale alone". GLOBAL.
-- Fill in the missing kind on a skin learned before we recorded one. A mesh
-- SCALE in MM2 is a uniform multiplier (0.27, 0.27, 0.27); a part SIZE has three
-- different numbers (0.27, 1.26, 4.21 — a gun 4.2 studs long). So uneven numbers
-- mean studs. Returns the record. GLOBAL.
function MH_normRec(rec)
	if type(rec) ~= "table" or rec.k then return rec end
	local x, y, z = tonumber(rec.sx), tonumber(rec.sy), tonumber(rec.sz)
	if not (x and y and z) then return rec end
	local lo = math.min(x, y, z)
	local hi = math.max(x, y, z)
	if lo > 0 and (hi - lo) / hi < 0.02 then rec.k = "scale" else rec.k = "size" end
	rec.g = true      -- inferred, not measured: a real learn pass should replace it
	return rec
end

function MH_scaleOf(rec)
	if type(rec) ~= "table" then return nil end
	MH_normRec(rec)
	local k = tonumber(_G.MH_SkinScale) or 1
	-- Numbers taken off a MeshPart are its SIZE IN STUDS, not a multiplier.
	-- Feeding those to SpecialMesh.Scale is what blew a swapped-in weapon up to
	-- several times its size. A MeshPart renders its mesh at its own size, so the
	-- SpecialMesh equivalent is scale 1.
	if rec.k == "size" then return Vector3.new(k, k, k) end
	if rec.k ~= "scale" then return nil end          -- unknown origin: don't guess
	local x, y, z = tonumber(rec.sx), tonumber(rec.sy), tonumber(rec.sz)
	if not (x and y and z) then return nil end
	if x <= 0 or y <= 0 or z <= 0 then return nil end
	return Vector3.new(x * k, y * k, z * k)
end

-- Record a skin's mesh, texture and scale in one place, so every learner writes
-- the same shape. `kind` says whether the numbers are a mesh scale or a part
-- size — mixing the two is what made weapons render huge. GLOBAL.
function MH_skinRecord(mesh, tex, sx, sy, sz, kind)
	local m = MH_shortId(mesh)
	if m == "" then return nil end
	local t = MH_shortId(tex)
	return { mesh = m, tex = (t ~= "" and t or nil),
		sx = sx, sy = sy, sz = sz, k = kind }
end

-- Build a REAL MeshPart from a mesh id, at an exact size. A skin recorded off a
-- MeshPart display carries its size in studs, and a SpecialMesh cannot reproduce
-- that: its Scale multiplies the mesh's native size, which nothing exposes — so
-- a big mesh at scale 1 comes out huge. A MeshPart takes the size directly.
-- Returns (part, detail). GLOBAL.
function MH_makeMeshPart(mesh, tex, sx, sy, sz)
	local mnum = MH_shortId(mesh)
	if mnum == "" then return nil, "no mesh id" end
	local AS = game:GetService("AssetService")
	local maker
	pcall(function() maker = AS.CreateMeshPartAsync end)
	if type(maker) ~= "function" then return nil, "no CreateMeshPartAsync" end
	local url = "rbxassetid://" .. mnum
	local mp
	-- newer engines want a Content object, older ones take the url string
	pcall(function()
		if Content and type(Content.fromAssetId) == "function" then
			mp = AS:CreateMeshPartAsync(Content.fromAssetId(tonumber(mnum)))
		end
	end)
	if not mp then pcall(function() mp = AS:CreateMeshPartAsync(url) end) end
	if not mp then return nil, "CreateMeshPartAsync failed" end
	pcall(function()
		mp.CanCollide = false; mp.Massless = true; mp.Anchored = false
		local t = MH_shortId(tex)
		if t ~= "" then mp.TextureID = "rbxassetid://" .. t end
		local k = tonumber(_G.MH_SkinScale) or 1
		if sx and sy and sz then mp.Size = Vector3.new(sx * k, sy * k, sz * k) end
	end)
	return mp, "meshpart:" .. mnum
end

-- Remove an overlay we welded on earlier and unhide what it was covering, so a
-- new skin is not left buried under an old one. `keep` is the mesh id of an
-- overlay that is still correct and should stay. GLOBAL.
function MH_dropOverlay(root, keep)
	pcall(function()
		local list = { root }
		for _, d in ipairs(root:GetDescendants()) do list[#list + 1] = d end
		for _, p in ipairs(list) do
			if p:IsA("BasePart") then
				local sk = p:FindFirstChild("__MHskin")
				if sk and not (keep and sk:IsA("MeshPart") and MH_shortId(sk.MeshId) == keep) then
					sk:Destroy()
					p.LocalTransparencyModifier = 0
				end
			end
		end
	end)
end

-- Hide `target` for our eyes only and weld a ready-made part in its place.
-- Returns 1 when the overlay is up. GLOBAL.
function MH_overlayWith(target, newPart)
	local made = 0
	pcall(function()
		local old = target:FindFirstChild("__MHskin")
		if old then old:Destroy() end
		newPart.Name = "__MHskin"
		newPart.CFrame = target.CFrame
		newPart.Parent = target
		local w = Instance.new("WeldConstraint")
		w.Part0 = target; w.Part1 = newPart; w.Parent = newPart
		local ltm = target.LocalTransparencyModifier
		target.LocalTransparencyModifier = 1
		_G.MH_SkinUndo = _G.MH_SkinUndo or {}
		_G.MH_SkinUndo[#_G.MH_SkinUndo + 1] = function()
			newPart:Destroy(); target.LocalTransparencyModifier = ltm
		end
		made = 1
	end)
	return made
end

-- Hide a MeshPart locally (LocalTransparencyModifier never replicates) and weld
-- our own Part+SpecialMesh onto it, so it moves exactly where the weapon does.
-- Returns 1 if the overlay is in place. GLOBAL.
function MH_overlayPart(part, mnum, tnum, scale)
	local made = 0
	pcall(function()
		local p = part:FindFirstChild("__MHskin")
		if not p then
			p = Instance.new("Part")
			p.Name = "__MHskin"
			p.Size = Vector3.new(1, 1, 1)
			p.CanCollide = false; p.Massless = true; p.Anchored = false
			p.CFrame = part.CFrame
			local sm = Instance.new("SpecialMesh")
			sm.MeshType = Enum.MeshType.FileMesh
			sm.Parent = p
			p.Parent = part
			local w = Instance.new("WeldConstraint")
			w.Part0 = part; w.Part1 = p; w.Parent = p
			local ltm = part.LocalTransparencyModifier
			_G.MH_SkinUndo[#_G.MH_SkinUndo + 1] = function()
				p:Destroy(); part.LocalTransparencyModifier = ltm
			end
		end
		part.LocalTransparencyModifier = 1
		local sm = p:FindFirstChildWhichIsA("SpecialMesh")
		sm.MeshId = "rbxassetid://" .. mnum
		if tnum ~= "" then sm.TextureId = "rbxassetid://" .. tnum end
		if scale then sm.Scale = scale end
		made = 1
	end)
	return made
end

-- Is this Tool the knife or the gun? GLOBAL.
function MH_toolSlot(tool)
	local n = tostring(tool.Name):lower()
	if n:find("gun") or n:find("revolver") or n:find("pistol") then return "Gun" end
	if n:find("knife") or n:find("blade") then return "Knife" end
	return nil
end

-- Push the stored skins onto everything that shows them right now: the body
-- display and any Tool you are holding. Safe to call repeatedly. GLOBAL.
function MH_applySkinNow()
	local ov = _G.MH_SkinOverride or {}
	local plr = game:GetService("Players").LocalPlayer
	local char = plr and plr.Character
	if not char then return 0 end
	local n = 0
	for _, slot in ipairs({ "Knife", "Gun" }) do
		local e = ov[slot]
		if type(e) == "table" and MH_shortId(e.mesh) ~= "" then
			local part = MH_displayPart(slot)
			if part then n = n + MH_paintMesh(part, e.mesh, e.tex, e) end
			local bp = plr:FindFirstChildOfClass("Backpack")
			for _, src in ipairs({ char, bp }) do
				if src then
					for _, t in ipairs(src:GetChildren()) do
						if t:IsA("Tool") and MH_toolSlot(t) == slot then
							n = n + MH_paintMesh(t, e.mesh, e.tex, e)
							-- how the weapon sits in the hand is the Tool's own Grip
							if e.grip then
								pcall(function()
									local want = MH_cfFrom(e.grip)
									if not want then return end
									if not _G.MH_SkinSeen[t] then
										_G.MH_SkinSeen[t] = true
										local was = t.Grip
										_G.MH_SkinUndo[#_G.MH_SkinUndo + 1] = function() t.Grip = was end
									end
									t.Grip = want
								end)
							end
						end
					end
				end
			end
		end
	end
	return n
end

-- Set the skin for a slot and keep it applied: the game rebuilds the display on
-- respawn and hands out a fresh Tool every round, so a light keep-alive loop
-- re-applies it. Returns (meshes changed, detail). GLOBAL.
function MH_applySkin(itemType, mesh, tex, sx, sy, sz, kind, rec)
	if MH_shortId(mesh) == "" then return 0, "no mesh id" end
	_G.MH_SkinOverride = _G.MH_SkinOverride or {}
	local use = MH_skinRecord(mesh, tex, sx, sy, sz, kind)
	-- carry the placement fields through: a mesh alone is not the whole look
	if type(rec) == "table" and use then
		for _, f in ipairs({ "ox", "oy", "oz", "vx", "vy", "vz", "cf", "grip" }) do
			use[f] = rec[f]
		end
	end
	_G.MH_SkinOverride[itemType] = use
	-- a stray part welded on by an older build would now sit next to the weapon
	pcall(function()
		local c = game:GetService("Players").LocalPlayer.Character
		local old = c and c:FindFirstChild("__MHequip")
		if old then old:Destroy() end
	end)
	local n = MH_applySkinNow()
	-- One keep-alive, not one per equip. Restoring stops the loop, and the next
	-- equip started another while the stopped one was still asleep in its wait —
	-- so they stacked up, each repainting on its own schedule.
	if not _G.MH_SkinLoop then
		_G.MH_SkinLoop = true
		_G.MH_SkinGen = (_G.MH_SkinGen or 0) + 1
		local myGen = _G.MH_SkinGen
		task.spawn(function()
			while _G.MH_SkinLoop and _G.MH_SkinGen == myGen do
				task.wait(0.5)
				pcall(MH_applySkinNow)
			end
		end)
	end
	if n == 0 then return 0, "nothing to restyle (no display/tool)" end
	local how = "mesh"
	pcall(function()
		local p = MH_displayPart(itemType)
		local sk = p and p:FindFirstChild("__MHskin")
		if sk then how = sk:IsA("MeshPart") and "meshpart" or "overlay" end
	end)
	return n, "restyled " .. tostring(n) .. " " .. how
		.. (_G.MH_SkinNote and (" [" .. tostring(_G.MH_SkinNote) .. "]") or "")
end

-- Put everything we touched back the way it was and stop the keep-alive. GLOBAL.
function MH_restoreSkins()
	_G.MH_SkinLoop = false
	_G.MH_SkinOverride = {}
	local n = 0
	for _, undo in ipairs(_G.MH_SkinUndo or {}) do
		if pcall(undo) then n = n + 1 end
	end
	_G.MH_SkinUndo = {}
	_G.MH_SkinSeen = {}
	return n
end

-- Drop the skin on ONE slot and leave the other one alone, so equipping a real
-- knife does not also strip a faked gun. GLOBAL.
function MH_clearSkin(slot)
	local ov = _G.MH_SkinOverride or {}
	local keep = {}
	for k, v in pairs(ov) do if k ~= slot then keep[k] = v end end
	MH_restoreSkins()
	for k, v in pairs(keep) do
		MH_applySkin(k, v.mesh, v.tex, v.sx, v.sy, v.sz, v.k, v)
	end
end

-- Display name (what an inventory tile shows) -> catalog key. GLOBAL.
function MH_keyForName(txt)
	txt = tostring(txt or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if txt == "" then return nil end
	local look = _G.MH_NameToKey
	if not look then
		look = {}
		for k, v in pairs(ItemDB) do
			if type(v) == "table" and (v.ItemType == "Knife" or v.ItemType == "Gun") then
				local lk = tostring(k):lower()
				look[lk] = look[lk] or k
				if v.ItemName then
					local n = tostring(v.ItemName):lower()
					look[n] = look[n] or k
				end
			end
		end
		_G.MH_NameToKey = look
	end
	if look[txt] then return look[txt] end
	-- A skin we have already learned is itself proof the item exists, even when
	-- the catalog has not caught up with it.
	for k in pairs(_G.MH_MeshMap or {}) do
		if tostring(k):lower() == txt then return k end
	end
	return nil
end

-- EQUIP FROM THE GAME'S OWN INVENTORY. Every inventory tile is a frame with an
-- ItemName.Label and a Container.ActionButton, so hook the button and read the
-- item off the label. Clicking a tile we have a skin for wears that skin;
-- clicking anything else drops our skin for THAT slot so the game's own equip
-- shows through instead of being repainted over. This only ADDS a listener — it
-- never blocks the game's own handler and never writes to any frame, so the
-- inventory keeps rendering exactly as it did. Returns tiles newly hooked. GLOBAL.
function MH_hookInventory()
	local gui = PlayerGui and PlayerGui:FindFirstChild("MainGUI")
	if not gui then return 0 end
	_G.MH_InvHooked = _G.MH_InvHooked or setmetatable({}, { __mode = "k" })
	local hooked = 0
	local okd, ds = pcall(function() return gui:GetDescendants() end)
	if not okd then return 0 end
	for _, f in ipairs(ds) do
		if not _G.MH_InvHooked[f] then
			local btn, label
			pcall(function()
				local nm = f:FindFirstChild("ItemName")
				local cn = f:FindFirstChild("Container")
				label = nm and nm:FindFirstChild("Label")
				local b = cn and cn:FindFirstChild("ActionButton")
				if label and label:IsA("TextLabel") and b and b:IsA("GuiButton") then btn = b end
			end)
			if btn then
				_G.MH_InvHooked[f] = true
				hooked = hooked + 1
				btn.MouseButton1Click:Connect(function()
					if _G.MH_InventoryEquip == false then return end
					task.spawn(function()
						local key = MH_keyForName(label.Text)
						if not key then return end
						local d0 = ItemDB[key]
						local rec = MH_normRec((_G.MH_MeshMap or {})[key])
						local slot = "Knife"
						if d0 and d0.ItemType == "Gun" then slot = "Gun"
						elseif not d0 and type(rec) == "table" and rec.slot == "Gun" then slot = "Gun" end
						if type(rec) == "table" and MH_shortId(rec.mesh) ~= "" then
							MH_equipItem(key, (d0 and d0.ItemName) or key)
						else
							MH_clearSkin(slot)
						end
					end)
				end)
			end
		end
	end
	return hooked
end

-- Keep the hook alive: the inventory rebuilds its tiles constantly (filters,
-- tabs, new items), so re-scan when the GUI grows and on a slow tick. GLOBAL.
function MH_watchInventory()
	if _G.MH_InvWatch then return end
	_G.MH_InvWatch = true
	MH_hookInventory()
	pcall(function()
		local gui = PlayerGui and PlayerGui:FindFirstChild("MainGUI")
		if gui then
			gui.DescendantAdded:Connect(function()
				if _G.MH_InvPending then return end
				_G.MH_InvPending = true
				task.delay(0.3, function()
					_G.MH_InvPending = false
					pcall(MH_hookInventory)
				end)
			end)
		end
	end)
	task.spawn(function()
		while _G.MH_InvWatch do
			task.wait(3)
			pcall(MH_hookInventory)
		end
	end)
end

-- Throw away every learned skin (on disk too). Use it if the map picked up a
-- bad entry — an older build could pair an item with the default weapon's mesh.
-- Hand-pinned _G.MH_MeshMap entries are re-applied from the file you edited, so
-- only learned data is lost. Returns how many entries were dropped. GLOBAL.
function MH_forgetSkins()
	local n = 0
	for _ in pairs(_G.MH_MeshMap or {}) do n = n + 1 end
	_G.MH_MeshMap = {}
	_G.MH_MeshMapLoaded = false
	pcall(function() if delfile then delfile("MollyHub_skins.json") end end)
	pcall(function() writefile("MollyHub_skins.json", "{}") end)
	return n
end

-- LEARN skins from the players around you. Every player's weapon display is a
-- replicated instance carrying the real mesh + texture of what they wear, and
-- the key they wear is on an attribute next to it — so pair the two and we get
-- genuine "item -> mesh/texture" entries for free. The map is saved to disk, so
-- it keeps growing across servers and sessions. Returns (learned, total). GLOBAL.
function MH_learnMeshes()
	MH_loadMeshMap()
	-- NB: do NOT strip the skins you are wearing here. This learner only ever
	-- reads OTHER players' displays, never our own, and it runs at the top of
	-- every equip — so stripping meant equipping a knife took off your gun, and
	-- equipping the gun took off the knife.
	local map = _G.MH_MeshMap or {}
	_G.MH_MeshMap = map
	local learned, total = 0, 0
	local me = game:GetService("Players").LocalPlayer
	for _, p in ipairs(game:GetService("Players"):GetPlayers()) do
		local c = p.Character
		-- never learn from YOURSELF: our own equipped-key attribute is the one an
		-- older build overwrote with a fake key, which would pair that item with
		-- the default weapon's mesh and poison the saved map.
		if p == me then c = nil end
		if c then
			for _, slot in ipairs({ "Knife", "Gun" }) do
				local wornKey
				for _, src in ipairs({ p, c }) do
					local oka, at = pcall(function() return src:GetAttributes() end)
					if oka and type(at) == "table" then
						for an, av in pairs(at) do
							if type(av) == "string" and av ~= ""
								and tostring(an):lower():find(slot:lower(), 1, true) then
								wornKey = wornKey or av
							end
						end
					end
				end
				local dpart, mid = MH_displayPart2(c, slot)
				if wornKey and MH_shortId(mid) ~= "" then
					local cur = map[wornKey]
					-- re-learn entries saved before we recorded scale, otherwise the
					-- swapped-in weapon keeps the previous item's size
					if type(cur) ~= "table" or MH_shortId(cur.mesh) == "" or not cur.k or cur.g then
						local r = MH_readSkin(dpart)
						if r then r.slot = slot end
						map[wornKey] = r
						learned = learned + 1
					end
				end
			end
		end
	end
	for _ in pairs(map) do total = total + 1 end
	if learned > 0 then MH_saveMeshMap() end
	return learned, total
end

-- MH_displayPart for an arbitrary character (MH_displayPart is yours). GLOBAL.
function MH_displayPart2(char, itemType)
	if not char then return nil, "", "" end
	local ov = char:FindFirstChild("DisplayRef" .. tostring(itemType))
	local part = (ov and ov:IsA("ObjectValue")) and ov.Value or nil
	if not part then return nil, "", "" end
	local mid, tid, sx, sy, sz, kind = MH_meshFieldsOf(part)
	return part, mid, tid, sx, sy, sz, kind
end

-- Persist / restore the learned skin map. GLOBAL.
function MH_saveMeshMap()
	pcall(function()
		local HS = game:GetService("HttpService")
		local map = _G.MH_MeshMap or {}
		-- MERGE with what is on disk instead of overwriting it. A fresh join
		-- starts with an empty map, so a learner that saved before anything read
		-- the file wiped every skin collected in an earlier session.
		local disk
		pcall(function()
			if isfile and isfile("MollyHub_skins.json") and readfile then
				disk = HS:JSONDecode(readfile("MollyHub_skins.json"))
			end
		end)
		if type(disk) == "table" then
			for k, v in pairs(disk) do
				local cur = map[k]
				-- keep the better record: a measured one beats a guessed one
				if type(cur) ~= "table" or MH_shortId(cur.mesh) == ""
					or (cur.g and type(v) == "table" and not v.g) then
					map[k] = v
				end
			end
		end
		writefile("MollyHub_skins.json", HS:JSONEncode(map))
	end)
end
function MH_loadMeshMap()
	if _G.MH_MeshMapLoaded then return end
	_G.MH_MeshMapLoaded = true
	pcall(function()
		if not (isfile and isfile("MollyHub_skins.json") and readfile) then return end
		local saved = game:GetService("HttpService"):JSONDecode(readfile("MollyHub_skins.json"))
		if type(saved) ~= "table" then return end
		local map = _G.MH_MeshMap or {}
		_G.MH_MeshMap = map
		for k, v in pairs(saved) do
			-- entries you pinned by hand win; anything learned before we recorded
			-- whether the numbers are a scale or a size gets that filled in, so an
			-- old map doesn't have to be thrown away and re-learned
			if map[k] == nil then map[k] = MH_normRec(v) end
		end
	end)
end

-- The BASE mesh for a slot: MM2 skins are mostly retextures of one knife / one
-- gun mesh, so the mesh from any display in that slot gives the right SHAPE even
-- when we don't know the item's own texture. GLOBAL.
function MH_slotBaseMesh(itemType)
	local _, mine = MH_displayPart(itemType)
	mine = MH_shortId(mine)
	if mine ~= "" then return mine, "yours" end
	local want = tostring(itemType):lower()
	local found = ""
	pcall(function()
		local wd = workspace:FindFirstChild("WeaponDisplays")
		if not wd then return end
		for _, dd in ipairs(wd:GetDescendants()) do
			if dd:IsA("SpecialMesh") and dd.Parent
				and tostring(dd.Parent.Name):lower():find(want, 1, true) then
				local id = MH_shortId(dd.MeshId)
				if id ~= "" then found = id; break end
			end
		end
	end)
	if found ~= "" then return found, "displays" end
	return nil, "no base mesh"
end

-- Part + SpecialMesh from raw ids. Meshes and textures render on ANY account
-- (unlike Models, which are ownership-gated), so this is the one build path that
-- can work for an item we don't own. Returns (part, detail). GLOBAL.
function MH_buildMeshPart(meshId, texId, tag)
	local mnum = MH_shortId(meshId)
	if mnum == "" then return nil, "no mesh id" end
	local part = Instance.new("Part")
	part.Size = Vector3.new(1, 1, 1)
	part.CanCollide = false
	part.Massless = true
	part.Anchored = false
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.FileMesh
	m.MeshId = "rbxassetid://" .. mnum
	local tnum = MH_shortId(texId)
	if tnum ~= "" then m.TextureId = "rbxassetid://" .. tnum end
	m.Parent = part
	return part, (tag or "mesh") .. ":" .. mnum .. (tnum ~= "" and ("/" .. tnum) or "")
end

-- Look for our item ANYWHERE the client can reach — the whole Workspace (lobby
-- shop stands, round weapons) and ReplicatedStorage — and read its mesh ids off
-- it. Matches the instance's own name, an ancestor's name, or any attribute
-- value, so a mesh sitting inside a container named after the item is found too.
-- Returns (mesh, tex, detail). GLOBAL.
function MH_scanWorldMeshes(names)
	local want = {}
	for _, n in ipairs(names or {}) do
		if n ~= nil and tostring(n) ~= "" then want[tostring(n):lower()] = true end
	end
	local mesh, tex, where, sx, sy, sz, kind
	local function identify(inst)
		if want[tostring(inst.Name):lower()] then return true end
		local oka, at = pcall(function() return inst:GetAttributes() end)
		if oka and type(at) == "table" then
			for _, av in pairs(at) do
				if type(av) == "string" and want[av:lower()] then return true end
			end
		end
		local p = inst.Parent
		for _ = 1, 3 do
			if not p or typeof(p) ~= "Instance" or p == workspace then break end
			if want[tostring(p.Name):lower()] then return true end
			p = p.Parent
		end
		return false
	end
	for _, root in ipairs({ workspace, game:GetService("ReplicatedStorage") }) do
		local okD, ds = pcall(function() return root:GetDescendants() end)
		if okD then
			for _, dd in ipairs(ds) do
				if (dd:IsA("SpecialMesh") or dd:IsA("MeshPart")) and identify(dd) then
					local m2, t2, a, b, c, kk = MH_meshFieldsOf(dd)
					mesh, tex, sx, sy, sz, kind = MH_shortId(m2), MH_shortId(t2), a, b, c, kk
					pcall(function() where = dd:GetFullName() end)
					if mesh ~= "" then
						return mesh, tex, "world:" .. tostring(where), sx, sy, sz, kind
					end
				end
			end
		end
	end
	return nil, nil, "not in world"
end

-- Every distinct weapon mesh the client can see anywhere, with where it lives.
-- Pure diagnostics: if MM2 keeps a 3D shop stand or a weapon gallery somewhere
-- in the world, its meshes show up here with a path that names the item. GLOBAL.
function MH_meshGallery(limit)
	limit = limit or 30
	local out, seen = {}, {}
	for _, root in ipairs({ workspace, game:GetService("ReplicatedStorage") }) do
		local okD, ds = pcall(function() return root:GetDescendants() end)
		if okD then
			for _, dd in ipairs(ds) do
				if #out >= limit then return table.concat(out, "\n") end
				local mid, tid = "", ""
				if dd:IsA("SpecialMesh") then
					pcall(function() mid = MH_shortId(dd.MeshId); tid = MH_shortId(dd.TextureId) end)
				elseif dd:IsA("MeshPart") then
					pcall(function() mid = MH_shortId(dd.MeshId); tid = MH_shortId(dd.TextureID) end)
				end
				if mid ~= "" and not seen[mid .. "/" .. tid] then
					seen[mid .. "/" .. tid] = true
					local path = ""
					pcall(function() path = dd:GetFullName() end)
					out[#out + 1] = "  " .. mid .. " + " .. (tid ~= "" and tid or "-") .. "  @ " .. path
				end
			end
		end
	end
	if #out == 0 then return "  (none)" end
	return table.concat(out, "\n")
end

-- EQUIP AN ITEM YOU REALLY OWN, THROUGH THE SERVER. The server only builds the
-- 3D display for items you actually own, so this is the one way to make it
-- reveal an item's real mesh + texture. The remote's argument order isn't known,
-- so the first call tries the plausible shapes and remembers the one the server
-- accepted. Returns (ok, detail). GLOBAL.
-- Every RemoteEvent that could plausibly be the equip call, paired with the
-- argument templates to try on it. MM2's equip code mentions Inventory, Equip
-- and FireServer in that order, which reads equally as Remotes.Inventory.Equip
-- (a child) or Remotes.Inventory:FireServer("Equip", ...) (an action string) —
-- so both are offered. GLOBAL.
function MH_equipCandidates()
	local out = {}
	local rs = game:GetService("ReplicatedStorage")
	local root = rs:FindFirstChild("Remotes") or rs
	local okd, ds = pcall(function() return root:GetDescendants() end)
	if not okd then return out end
	for _, d in ipairs(ds) do
		if d:IsA("RemoteEvent") then
			local n = tostring(d.Name):lower()
			if n == "equip" or n == "equipitem" then
				for _, t in ipairs({ { "$key" }, { "$type", "$key" }, { "$key", "$type" },
					{ "Weapons", "$key" }, { "Weapons", "$type", "$key" } }) do
					out[#out + 1] = { remote = d, args = t }
				end
			elseif n == "inventory" or n == "inventoryevent" or n == "weapons" then
				for _, t in ipairs({ { "Equip", "$key" }, { "Equip", "$type", "$key" },
					{ "Equip", "Weapons", "$key" } }) do
					out[#out + 1] = { remote = d, args = t }
				end
			end
		end
	end
	return out
end

function MH_equipReal(key, itemType, timeout)
	local plr = game:GetService("Players").LocalPlayer
	local attr = "Equipped" .. tostring(itemType)
	-- Already wearing it? Then say so plainly. Probing would "succeed" on the
	-- very first shape without the server doing anything, which both hid the item
	-- from the learner and taught us a wrong argument order.
	if plr:GetAttribute(attr) == key then return true, "already" end
	local cands = _G.MH_EquipSig and { _G.MH_EquipSig } or MH_equipCandidates()
	if #cands == 0 then return false, "no equip remote" end
	-- The display's mesh BEFORE we ask. The equipped-key attribute is not a
	-- reliable success signal on its own — a dump showed it reading DefaultGun
	-- while the profile said Ace — so a changed display counts as success too,
	-- and that is the thing we are actually here to read.
	local before = select(2, MH_displayPart(itemType))
	for _, c in ipairs(cands) do
		local sent = {}
		for i, a in ipairs(c.args) do
			if a == "$key" then sent[i] = key
			elseif a == "$type" then sent[i] = itemType
			else sent[i] = a end
		end
		pcall(function() c.remote:FireServer(table.unpack(sent)) end)
		local waited = 0
		while waited < (timeout or 1) do
			task.wait(0.1)
			waited = waited + 0.1
			local now = select(2, MH_displayPart(itemType))
			if plr:GetAttribute(attr) == key
				or (MH_shortId(now) ~= "" and tostring(now) ~= tostring(before)) then
				if not _G.MH_EquipSig then _G.MH_EquipSig = c end
				return true, tostring(c.remote.Name) .. "(" .. table.concat(c.args, ",") .. ")"
			end
		end
	end
	return false, "server did not accept"
end

-- LEARN YOUR WHOLE INVENTORY. Walks the items you own, equips each one for real,
-- reads the mesh + texture the server puts on your display, and records it. This
-- is slow and it does talk to the server — but only to equip things that are
-- already yours, which is an ordinary thing the game lets you do. Your original
-- equip is restored at the end and progress is saved as it goes, so an interrupt
-- loses nothing. Returns (learned, tried). GLOBAL.
function MH_learnOwned(onProgress)
	-- Take our own skin off first. The keep-alive repaints the display twice a
	-- second, so with an override live the display never looks like it changed
	-- and every read would return OUR mesh instead of the server's.
	MH_restoreSkins()
	MH_loadMeshMap()
	local map = _G.MH_MeshMap or {}
	_G.MH_MeshMap = map
	local pd
	pcall(function()
		local cs = game:GetService("ReplicatedStorage"):FindFirstChild("ClientServices")
		local esM = cs and cs:FindFirstChild("EquipService")
		local okr, ES = pcall(require, esM)
		if okr and type(ES) == "table" and type(ES.EquipItem) == "function" then
			pcall(function() pd = debug.getupvalue(ES.EquipItem, 2) end)
		end
	end)
	if type(pd) ~= "table" or type(pd.Weapons) ~= "table"
		or type(pd.Weapons.Owned) ~= "table" then
		return 0, 0, 0, 0, "no owned list (not MM2, or EquipService moved)"
	end
	if #MH_equipCandidates() == 0 then
		return 0, 0, 0, 0, "no equip remote found"
	end
	-- What the SERVER says is equipped. ProfileData is not usable here: the
	-- harness writes fake keys into it, so "am I already wearing this?" never
	-- matched and every worn item was skipped.
	local plr = game:GetService("Players").LocalPlayer
	local was = { Knife = plr:GetAttribute("EquippedKnife"),
		Gun = plr:GetAttribute("EquippedGun") }
	local keys = {}
	for k in pairs(pd.Weapons.Owned) do keys[#keys + 1] = k end
	table.sort(keys)
	local learned, tried, refused, stale, known, skipped = 0, 0, 0, 0, 0, 0
	local names, owned = {}, #keys        -- which keys were refused, for the report
	_G.MH_LearnStop = false
	for _, k in ipairs(keys) do
		if _G.MH_LearnStop then break end
		local cur = map[k]
		local fake = (_G.MH_FakeOwned or {})[k] ~= nil
			or (ItemDB[k] == nil and not _G.MH_LearnUnknown)
		if fake then
			skipped = skipped + 1                -- our own spawned key, not a real item
		elseif type(cur) == "table" and MH_shortId(cur.mesh) ~= "" and cur.k and not cur.g then
			known = known + 1                    -- already have a measured record
		else
			local d = ItemDB[k]
			-- Unknown items (an old harness build could add fake keys to Owned) are
			-- tried in BOTH slots rather than assumed to be knives, which silently
			-- read the wrong display and skipped every unlisted gun.
			local slots = { "Knife", "Gun" }
			if d and d.ItemType == "Gun" then slots = { "Gun" }
			elseif d and d.ItemType == "Knife" then slots = { "Knife" } end
			-- once the call shape is known the server answers fast, so a refusal must
			-- not cost the full discovery timeout on every one of ~800 items
			local wait4 = _G.MH_EquipSig and 0.45 or 1
			tried = tried + 1
			local got, sawStale = false, false
			for _, slot in ipairs(slots) do
				if got or _G.MH_LearnStop then break end
				local was0 = select(2, MH_displayPart(slot))
				-- already wearing it? then the display is ALREADY this item, and
				-- waiting for it to change would time out on correct data
				if plr:GetAttribute("Equipped" .. slot) == k and MH_shortId(was0) ~= "" then
					local dpart = MH_displayPart(slot)
					local r = MH_readSkin(dpart)
					if r then r.slot = slot end
					map[k] = r
					learned = learned + 1
					got = true
				elseif MH_equipReal(k, slot, wait4) then
					-- Wait for the display to actually CHANGE. A fixed sleep recorded
					-- whatever was still on the body, so a slow rebuild filed the
					-- PREVIOUS item's mesh and scale under this key.
					local dpart, mid
					for _ = 1, 16 do
						task.wait(0.1)
						dpart, mid = MH_displayPart(slot)
						if MH_shortId(mid) ~= "" and tostring(mid) ~= tostring(was0) then break end
					end
					if MH_shortId(mid) ~= "" and tostring(mid) ~= tostring(was0) then
						local r = MH_readSkin(dpart)
						if r then r.slot = slot end
						map[k] = r
						learned = learned + 1
						got = true
						if learned % 10 == 0 then MH_saveMeshMap() end
					else
						sawStale = true                  -- equipped, display never moved
					end
				end
			end
			if not got then
				if sawStale then stale = stale + 1 else refused = refused + 1 end
				if #names < 10 then
					names[#names + 1] = tostring(k) .. (ItemDB[k] and "" or "?")
				end
			end
			if onProgress and tried % 25 == 0 then
				pcall(onProgress, learned, tried, #keys, refused, stale)
			end
			task.wait(0.1)
		end
	end
	for slot, k in pairs(was) do
		if k then pcall(function() MH_equipReal(k, slot, 0.4) end) end
	end
	MH_saveMeshMap()
	local why = "ok"
	if learned == 0 then
		if tried == 0 then why = "nothing to do: all " .. known .. " already known"
		elseif refused >= tried then why = "server refused every equip"
		else why = "equips went through but no display appeared" end
	end
	-- What the server would not equip, and how we asked. A "?" marks a key the
	-- catalog does not know — those are the fake ones the spawner writes into
	-- Owned, not real items, so they are expected to be refused.
	local sig = "none"
	if _G.MH_EquipSig then
		sig = tostring(_G.MH_EquipSig.remote.Name)
			.. "(" .. table.concat(_G.MH_EquipSig.args, ",") .. ")"
	end
	local note = "owned=" .. owned .. " skipped=" .. skipped .. " via=" .. sig
	if #names > 0 then note = note .. " refused[" .. table.concat(names, " ") .. "]" end
	return learned, tried, refused, stale, why, known, note
end

-- Equip an item on YOUR character CLIENT-SIDE only. (1) menu equip: set
-- ProfileData.Weapons.Equipped + fire EquippedChanged (no server). (2) hand:
-- pull the game's item record and build a real weapon model into your hand;
-- fall back to a name-search. Dumps the record so its mesh field is visible if
-- the build fails. Returns (ok, detail). GLOBAL.
function MH_equipItem(key, dispName)
	if not key or key == "" then return false, "no key" end
	local parts = {}
	local function add(s) parts[#parts + 1] = tostring(s) end
	add("v37")   -- freshness marker so a stale-cache test is obvious
	MH_loadMeshMap()
	local lrn, tot = MH_learnMeshes()
	add("learn=+" .. tostring(lrn) .. "/" .. tostring(tot))
	local d0 = ItemDB[key]
	local mrec = MH_normRec((_G.MH_MeshMap or {})[key])
	-- An item the catalog has not caught up with must not silently become a
	-- knife: the learned skin knows which slot it was read off.
	local itemType = "Knife"
	if d0 and d0.ItemType == "Gun" then itemType = "Gun"
	elseif not d0 and type(mrec) == "table" and mrec.slot == "Gun" then itemType = "Gun" end
	add("type=" .. itemType)
	-- Snapshot what the game REALLY has equipped + the mesh its display shows
	-- right now, so we can (a) find the replicated markers that hold that key and
	-- (b) tell whether the display actually rebuilt for our item.
	local realKey
	pcall(function()
		local cs = game:GetService("ReplicatedStorage"):FindFirstChild("ClientServices")
		local esM = cs and cs:FindFirstChild("EquipService")
		if not esM then return end
		local okr, ES = pcall(require, esM)
		if okr and type(ES) == "table" and type(ES.EquipItem) == "function"
			and type(debug) == "table" and type(debug.getupvalue) == "function" then
			local pd
			pcall(function() pd = debug.getupvalue(ES.EquipItem, 2) end)
			if type(pd) == "table" and type(pd.Weapons) == "table"
				and type(pd.Weapons.Equipped) == "table" then
				realKey = pd.Weapons.Equipped[itemType]
			end
		end
	end)
	local _, mesh0 = MH_displayPart(itemType)
	-- 1) menu equip (data + client signal, no FireServer)
	pcall(function()
		local rs = game:GetService("ReplicatedStorage")
		local cs = rs:FindFirstChild("ClientServices")
		local esM = cs and cs:FindFirstChild("EquipService")
		local ES
		if esM then local r; r, ES = pcall(require, esM); if not r then ES = nil end end
		if type(ES) == "table" then
			local pd
			if type(debug) == "table" and type(debug.getupvalue) == "function"
				and type(ES.EquipItem) == "function" then
				pcall(function() pd = debug.getupvalue(ES.EquipItem, 2) end)
			end
			if type(pd) ~= "table" or type(pd.Weapons) ~= "table" then
				local mods = rs:FindFirstChild("Modules")
				local pdM = mods and mods:FindFirstChild("ProfileData")
				local okp, p = pcall(require, pdM)
				if okp then pd = p end
			end
			if type(pd) == "table" and type(pd.Weapons) == "table" then
				if type(pd.Weapons.Owned) == "table" then
					pd.Weapons.Owned[key] = pd.Weapons.Owned[key] or 1
					_G.MH_FakeOwned = _G.MH_FakeOwned or {}
					_G.MH_FakeOwned[key] = true
				end
				if type(pd.Weapons.Equipped) == "table" then
					pd.Weapons.Equipped[itemType] = key
					add("Equipped set")
				end
			end
			pcall(function() ES.EquippedChanged:Fire(itemType, key) end)
			pcall(function() ES.EquippedChanged:Fire() end)
		end
	end)
	-- 2) hand model. Gather candidate names first.
	local names = { key, dispName }
	local info, gd = MH_getItemInfo(key)
	if info then
		add("info=" .. MH_infoDump(info))
		if info.ItemName then names[#names + 1] = info.ItemName end
		if info.ItemID then names[#names + 1] = string.format("%d", math.floor(info.ItemID)) end
	else
		add("getInfo:" .. tostring(gd))
	end
	-- NB: no marker swap any more. Overwriting the replicated equipped-key
	-- attribute never rebuilt the display (it is built server-side), and it fed a
	-- fake key back into the skin learner, which then paired our item with the
	-- default weapon's mesh. Leave the game's own state alone.
	add("disp=" .. (MH_shortId(mesh0) ~= "" and MH_shortId(mesh0) or "none"))
	-- the real weapon meshes the client can already see. Non-empty here means the
	-- meshes ARE reachable and we only need the right id per item.
	add("harvest[" .. MH_harvestDisplays(8) .. "]")
	-- 2a0) a skin you already know for this item (_G.MH_MeshMap) — always wins.
	local mm = _G.MH_MeshMap or {}
	for _, nm in ipairs(names) do
		local e = (nm ~= nil) and MH_normRec(mm[tostring(nm)]) or nil
		if type(e) == "table" and MH_shortId(e.mesh) ~= "" then
			local n, ad = MH_applySkin(itemType, e.mesh, e.tex, e.sx, e.sy, e.sz, e.k, e)
			add("map " .. MH_shortId(e.mesh) .. "/" .. MH_shortId(e.tex)
				.. " " .. tostring(e.k or "?") .. "("
				.. string.format("%.3f,%.3f,%.3f", tonumber(e.sx) or 0, tonumber(e.sy) or 0,
					tonumber(e.sz) or 0) .. ") -> " .. tostring(ad))
			if n > 0 then return true, table.concat(parts, " | "), "map" end
		end
	end
	-- 2a) YOUR own uploaded model (_G.MH_SkinModels) takes priority — this is the
	-- reliable path since MM2's own models aren't loadable client-side.
	local skins = _G.MH_SkinModels or {}
	local mapId
	for _, nm in ipairs(names) do
		local v = (nm ~= nil) and skins[tostring(nm)] or nil
		if v ~= nil and tostring(v) ~= "0" and tostring(v) ~= "rbxassetid://0" then mapId = v; break end
	end
	if mapId then
		local m, md = MH_loadAssetModel(mapId)
		if m then
			local aok, ad = MH_attachToHand(m)
			add("skin " .. tostring(md) .. " -> " .. tostring(ad))
			if aok then return true, table.concat(parts, " | "), "skin" end
		else
			add("skin:" .. tostring(md))
		end
	end
	-- 2b) THE MESH DATABASE. Anchor on the weapon you are really wearing (its key
	-- + the mesh id its display is showing right now) to identify the game's own
	-- key->mesh table in memory, then read our item straight out of it.
	local anchors = { realKey }
	if realKey then
		local ri = MH_getItemInfo(realKey)
		if ri and ri.ItemName then anchors[#anchors + 1] = ri.ItemName end
	end
	add("anchor=" .. tostring(realKey) .. "/" .. (MH_shortId(mesh0) ~= "" and MH_shortId(mesh0) or "?"))
	local aId, bId, ad2 = MH_meshDBLookup(mesh0, anchors, names)
	if aId then
		local n, ad3 = MH_applySkin(itemType, aId, bId)
		add(tostring(ad2) .. " " .. MH_shortId(aId) .. " -> " .. tostring(ad3))
		if n > 0 then return true, table.concat(parts, " | "), "gamedb" end
	else
		add("meshdb:" .. tostring(ad2))
	end
	-- 2c) a mesh id filed under this item anywhere in the client's own modules
	local mId, tId, sd = MH_scanMeshDB(key, names)
	if mId then
		local n, ad = MH_applySkin(itemType, mId, tId)
		add(tostring(sd) .. " " .. MH_shortId(mId) .. " -> " .. tostring(ad))
		if n > 0 then return true, table.concat(parts, " | "), "dbmesh" end
	else
		add("scan:" .. tostring(sd))
	end
	-- 3) our item's mesh sitting somewhere in the world (a lobby shop stand, a
	-- round weapon) identified by name, ancestor name or attribute
	local wMesh, wTex, wd2, wsx, wsy, wsz, wk = MH_scanWorldMeshes(names)
	if wMesh then
		local n, ad = MH_applySkin(itemType, wMesh, wTex, wsx, wsy, wsz, wk)
		add(tostring(wd2) .. " " .. wMesh .. " -> " .. tostring(ad))
		if n > 0 then return true, table.concat(parts, " | "), "world" end
	else
		add("world:" .. tostring(wd2))
	end
	-- 3b) BASE MESH: MM2 skins are retextures of one knife / one gun mesh, so the
	-- SHAPE is always available — only the texture is per-item. Retexture with the
	-- item's own image asset. Reported as "basemesh": the shape is real, the skin
	-- is only right if that image asset happens to be the weapon's texture.
	-- _G.MH_BaseMeshFallback = false turns this off if you would rather see
	-- nothing than a wrong skin.
	local bm, bmd = MH_slotBaseMesh(itemType)
	if bm and _G.MH_BaseMeshFallback ~= false then
		local tex = info and MH_shortId(info.Image) or ""
		local n, ad = MH_applySkin(itemType, bm, tex ~= "" and tex or nil)
		add("basemesh/" .. tostring(bmd) .. " " .. bm .. "/" .. tex .. " -> " .. tostring(ad))
		if n > 0 then return true, table.concat(parts, " | "), "basemesh" end
	else
		add("base:" .. tostring(bmd))
	end
	-- NB: the old "treat ItemID as a mesh id" guess is gone. It welded a stray
	-- part onto the hand instead of restyling the weapon you are wearing, and the
	-- id is a model id, so nothing ever rendered from it anyway.
	-- diagnostics: the real weapon meshes the client can already see. If this is
	-- non-empty the meshes ARE reachable and we only need the right id per item.
	add("harvest[" .. MH_harvestDisplays(8) .. "]")
	return false, table.concat(parts, " | ")
end

-- Rank catalog matches for a typed name: exact key/name > prefix > contains.
-- This is the "scanner" — you type what you want, it figures out the item.
local function rankMatches(query)
	query = tostring(query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	local out = {}
	if query == "" then
		for _, it in ipairs(spawnIndex) do
			out[#out + 1] = it
			if #out >= 50 then break end
		end
		return out
	end
	local scored = {}
	for _, it in ipairs(spawnIndex) do
		local n, k = it.name:lower(), tostring(it.key):lower()
		local s
		if n == query or k == query then s = 0
		elseif n:sub(1, #query) == query or k:sub(1, #query) == query then s = 1
		elseif n:find(query, 1, true) or k:find(query, 1, true) then s = 2 end
		if s then scored[#scored + 1] = { it = it, s = s } end
	end
	table.sort(scored, function(a, b)
		if a.s ~= b.s then return a.s < b.s end
		return a.it.name:lower() < b.it.name:lower()
	end)
	for i = 1, math.min(50, #scored) do out[i] = scored[i].it end
	return out
end
-- When the real catalog/inventory finishes loading in the background, rebuild.
onCatalogLoaded = function()
	buildSpawnIndex()
	pcall(renderInventory)
end
--==============================================================================
-- 9b. OPTIONAL EXTERNAL UI  —  Rubis library front-end (user requested)
--==============================================================================
-- Builds the SAME controls on ONE "Trade" tab using the Rubis UI library.
-- NOTE: this fetches and RUNS external code from the URL below at launch — to
-- disable it and keep the fully self-contained panel, comment out this whole
-- task.spawn block. The built-in panel stays as an automatic fallback: it is
-- hidden ONLY after the Rubis menu finishes building, so a failed load / changed
-- API never leaves you with no menu. Every control just calls existing functions.
-- Rubis is ENABLED. Flip `if true` to `if false` to fall back to the built-in
-- blue-gray panel. If Rubis fails to build, the console (F9) shows the error and
-- the built-in panel is restored automatically.
if true then
	-- WATCHDOG (separate thread, so a hung HttpGet can't block it). Rubis on a slow
	-- executor (e.g. Potassium PC) can take a while to fetch, so give it a long
	-- grace period before warning — and if it DOES come up late, auto-remove the
	-- warning so you're not left staring at a false error.
	task.spawn(function()
		task.wait(30)
		if not Runtime.RubisReady then
			__showFatal("Rubis is slow to load (executor/connection). It may still appear shortly — if not, re-run.")
			-- Keep watching: clear the notice the moment Rubis reports ready.
			for _ = 1, 60 do
				task.wait(1)
				if Runtime.RubisReady then
					pcall(function()
						local g = PlayerGui:FindFirstChild("TradeDebugError")
						if g then g:Destroy() end
					end)
					break
				end
			end
		end
	end)
	task.spawn(function()
		-- Retry the load a few times — the endpoint occasionally hiccups.
		local lib
		for attempt = 1, 5 do
			local okLoad, res = pcall(function()
				return loadstring(game:HttpGet("https://api.rubis.app/v2/scrap/D9CpDTMz8Hh4v1wA/raw"))()
			end)
			if okLoad and type(res) == "table" then lib = res; break end
			warn("[TradeDebug] Rubis load attempt " .. attempt .. " failed: " .. tostring(res))
			task.wait(1.5)
		end
		if type(lib) ~= "table" then
			warn("[TradeDebug] Rubis UI could not load.")
			__showFatal("Rubis UI could not load (HttpGet/loadstring failed) — re-run the script.")
			return
		end
		local built, builtErr = pcall(function()
			pcall(function() lib:SetTheme("Dark") end)
			-- Try to push a blue-gray custom theme (Rubis's exact key names are
			-- unknown to us, so try a few shapes; unknown ones are ignored/pcall'd).
			pcall(function()
				lib:SetTheme({
					Name = "MollyBlue",
					Accent = Color3.fromRGB(108, 150, 210), AccentColor = Color3.fromRGB(108, 150, 210),
					Background = Color3.fromRGB(24, 30, 42), Main = Color3.fromRGB(24, 30, 42),
					Topbar = Color3.fromRGB(30, 37, 52), Second = Color3.fromRGB(35, 43, 60),
					Text = Color3.fromRGB(228, 234, 246),
				})
			end)
			local function notify(title, content)
				pcall(function() lib:Notify({ Title = title, Content = content, Duration = 4 }) end)
			end
			-- Snapshot existing GUIs so we can find + reskin Rubis's own ScreenGui.
			local guiRoots = { PlayerGui }
			pcall(function() guiRoots[#guiRoots + 1] = game:GetService("CoreGui") end)
			pcall(function() if gethui then guiRoots[#guiRoots + 1] = gethui() end end)
			local seenGui = {}
			for _, root in ipairs(guiRoots) do
				for _, g in ipairs(root:GetChildren()) do seenGui[g] = true end
			end
			-- Blue-gray, slightly transparent, with your background photo. Rubis reads
			-- these option names; the image ones let you drop in BG_IMAGE. Unknown
			-- fields are harmlessly ignored, so we pass a few likely aliases.
			-- Create the window DEFENSIVELY: if styled options make Rubis throw (that is
			-- what left you with no menu), retry with a minimal set so a window appears.
			local Win
			pcall(function()
				Win = lib:CreateWindow({
					Title = "MollyHub", Icon = "box", Author = "trade sandbox",
					Size = UDim2.fromOffset(292, 224), Theme = "Dark", Resizable = true,
					SideBarWidth = 104, Transparent = true, BackgroundImageTransparency = 0.5,
					BackgroundImage = BG_IMAGE, Image = BG_IMAGE, Background = BG_IMAGE,
					OpenButton = { Title = "MollyHub", Enabled = true, Draggable = true,
						Color = ColorSequence.new(Color3.fromRGB(108, 150, 210), Color3.fromRGB(60, 84, 128)) },
				})
			end)
			if not Win then
				pcall(function() Win = lib:CreateWindow({ Title = "MollyHub", Size = UDim2.fromOffset(292, 224), Theme = "Dark" }) end)
			end
			assert(Win, "Rubis CreateWindow returned nil")
			-- Menu scale: some executors/devices (e.g. Delta on PC) render Rubis
			-- oversized. Add a UIScale to the window frame(s) so the whole menu
			-- shrinks. Tunable via _G.MH_MenuScale. Applied a few times because
			-- Rubis parents its GUI slightly after CreateWindow returns.
			local function MH_scaleMenuOnce()
				local s = tonumber(_G.MH_MenuScale) or 1
				if s == 1 then return end
				for _, root in ipairs(guiRoots) do
					local okc, kids = pcall(function() return root:GetChildren() end)
					if okc then
						for _, g in ipairs(kids) do
							if g:IsA("ScreenGui") and not seenGui[g] and not g:GetAttribute("__MHscaled") then
								for _, d in ipairs(g:GetChildren()) do
									if d:IsA("GuiObject") then
										local us = d:FindFirstChildOfClass("UIScale")
										if us then us.Scale = us.Scale * s
										else us = Instance.new("UIScale"); us.Scale = s; us.Parent = d end
									end
								end
								g:SetAttribute("__MHscaled", true)
							end
						end
					end
				end
			end
			task.defer(MH_scaleMenuOnce)
			task.delay(0.5, MH_scaleMenuOnce)
			task.delay(1.5, MH_scaleMenuOnce)
			-- ================= shared helpers + state =================
			local function serverNames()
				local out = {}
				for _, pl in ipairs(Players:GetPlayers()) do
					if pl ~= LocalPlayer then out[#out + 1] = pl.Name end
				end
				table.sort(out)
				return out
			end
			local function catalogNames()
				local names = {}
				for _, it in ipairs(spawnIndex) do names[#names + 1] = it.name end
				return names
			end
			local spName, spAmt = "", "1"
			local p2Name, p2Amt = "", "1"
			-- Spawn the best match for a query; toP2 routes it into Player2's offer.
			local function doSpawn(query, amount, toP2)
				local it = rankMatches(query)[1]
				if not it then notify("Spawn", "no item matches \"" .. tostring(query) .. "\"") return end
				local prev = OfferMode
				if toP2 then OfferMode = "Player2" end
				local total = spawnEntry(it, amount)
				OfferMode = prev
				notify("Spawned", it.name .. " (x" .. tostring(total) .. ")" .. (toP2 and " -> P2 offer" or ""))
			end

			-- ================= THEME state =================
			-- Per-theme background image. Blue-Gray uses BG_IMAGE (top of script).
			-- vv PASTE the Black / Secret theme image ids here (rbxassetid://...) vv
			local THEME_IMAGES = {
				["Blue-Gray"] = BG_IMAGE,
				["Black"]     = "rbxassetid://0",
				["Secret"]    = "rbxassetid://0",
			}
			-- ^^ ---------------------------------------------------------------- ^^
				local function blueTint(l) return Color3.new(l * 0.80, l * 0.88, math.min(1, l * 1.06 + 0.03)) end
				local function purpleTint(l) return Color3.new(math.min(1, l * 0.85 + 0.05), l * 0.32, math.min(1, l * 0.95 + 0.08)) end
				local currentTheme = "Blue-Gray"
				local secretUnlocked = false
				-- Blue-Gray = blue tint. Black = Rubis's NATIVE dark (restore the originals).
				-- Secret = purple tint (left as-is). Originals are cached per element so
				-- switching back to Black looks exactly like the default dark theme.
				local function applyTheme(name)
					currentTheme = name
					for _, root in ipairs(guiRoots) do
						for _, g in ipairs(root:GetChildren()) do
							if g:IsA("ScreenGui") and not seenGui[g] then
								for _, d in ipairs(g:GetDescendants()) do
									pcall(function()
										if d.Name == "__MHPhoto" and d:IsA("ImageLabel") then
											d.Image = THEME_IMAGES[name] or BG_IMAGE
										elseif (d:IsA("Frame") or d:IsA("ImageLabel") or d:IsA("ImageButton")) and d.BackgroundTransparency < 1 then
											local ob = d:GetAttribute("__MHorigBg")
											if not ob then ob = d.BackgroundColor3; d:SetAttribute("__MHorigBg", ob) end
											local l = (ob.R + ob.G + ob.B) / 3
											if name == "Black" then d.BackgroundColor3 = ob
											elseif name == "Secret" then d.BackgroundColor3 = purpleTint(l)
											else d.BackgroundColor3 = blueTint(l) end
										elseif d:IsA("TextLabel") or d:IsA("TextButton") then
											local ot = d:GetAttribute("__MHorigTx")
											if not ot then ot = d.TextColor3; d:SetAttribute("__MHorigTx", ot) end
											if name == "Black" then d.TextColor3 = ot   -- native (already light)
											elseif name == "Secret" then d.TextColor3 = Color3.fromRGB(255, 238, 255)
											else d.TextColor3 = Color3.fromRGB(228, 234, 246) end
										end
									end)
								end
							end
						end
					end
				end
				local p2Key = Enum.KeyCode.G

			-- ================= TAB 1: Trade =================
			local _ok_0, _e_0 = pcall(function()
				local T = Win:Tab({ Title = "Trade", Icon = "box", ShowTabTitle = true })
				T:Section({ Title = "Trade" })
				local plDrop
				pcall(function()
					plDrop = T:Dropdown({ Title = "Choose player", Desc = "pick from the server",
						Values = serverNames(), Value = "", Compact = true, AllowNone = true,
						Callback = function(v) if type(v) == "string" and v ~= "" then NameBox.Text = v end end })
				end)
				local function refreshPl() if plDrop then pcall(function() plDrop:Refresh(serverNames()) end) end end
				track(Players.PlayerAdded:Connect(refreshPl))
				track(Players.PlayerRemoving:Connect(refreshPl))
				T:Input({ Title = "...or type a name", Placeholder = "name...",
					Callback = function(v) NameBox.Text = (v ~= "" and v) or "Player2" end })
				T:Button({ Title = "Incoming request", Desc = "someone sends YOU a request",
					Callback = function() showRequestModal(currentName(), true) end })
				T:Button({ Title = "Outgoing request", Desc = "YOU send a request (waiting)",
					Callback = function() showRequestModal(currentName(), false) end })
				T:Toggle({ Title = "Overlay on REAL trade", Desc = "fake items on your side (visual only)", Default = false,
					Callback = function(on) OverlayMode = on; if on then pcall(openItemsPicker) end; pcall(RenderTrade) end })
				T:Section({ Title = "Accept" })
				T:Toggle({ Title = "You accepted (P1)", Desc = "YOU HAVE ACCEPTED.", Default = false,
					Callback = function(on) setYourAcceptedUI(on) end })
				T:Toggle({ Title = "Other accepted (P2)", Desc = "OTHER PLAYER HAS ACCEPTED.", Default = false,
					Callback = function(on)
						DebugTradeTable.Player2.Accepted = on
						showAcceptedBadge("their", on, "OTHER PLAYER HAS ACCEPTED.")
						if on then completeTradeIfBothAccepted() end
					end })
				T:Button({ Title = "Terminate + Wipe", Desc = "close & wipe the harness",
					Callback = function() terminate() end })
			end)
			if not _ok_0 then warn("[TradeDebug] Rubis tab Trade error: "..tostring(_e_0)) end

			-- ================= TAB 2: 2 Player =================
			local _ok_1, _e_1 = pcall(function()
				local P2 = Win:Tab({ Title = "2 Player", Icon = "box", ShowTabTitle = true })
				P2:Section({ Title = "Player 2 side" })
				P2:Toggle({ Title = "Spawn to Player 2 side", Desc = "spawns land in THEIR offer (Spawner too)", Default = false,
					Callback = function(on) OfferMode = on and "Player2" or "Player1" end })
				P2:Input({ Title = "Search item", Placeholder = "e.g. Chroma Seer",
					Callback = function(v) p2Name = v end })
				P2:Input({ Title = "Amount", Placeholder = "1", Callback = function(v) p2Amt = v end })
				P2:Button({ Title = "Spawn into P2 offer", Desc = "puts the item straight into their side",
					Callback = function() doSpawn(p2Name, p2Amt, true) end })
			end)
			if not _ok_1 then warn("[TradeDebug] Rubis tab 2 Player error: "..tostring(_e_1)) end

			-- ================= TAB 3: Spawner =================
			local _ok_2, _e_2 = pcall(function()
				local S = Win:Tab({ Title = "Spawner", Icon = "box", ShowTabTitle = true })
				S:Section({ Title = "Spawn" })
				local catDrop
				pcall(function()
					catDrop = S:Dropdown({ Title = "Catalog", Desc = "matches for your search",
						Values = catalogNames(), Value = "", Compact = true, AllowNone = true,
						Callback = function(v) if type(v) == "string" and v ~= "" then spName = v end end })
				end)
				S:Input({ Title = "Search item", Placeholder = "type a name, e.g. Chroma Seer",
					Callback = function(v)
						spName = v
						if catDrop then
							local names = {}
							for _, it in ipairs(rankMatches(v)) do names[#names + 1] = it.name end
							pcall(function() catDrop:Refresh(names) end)
						end
					end })
				S:Input({ Title = "Amount", Placeholder = "1", Callback = function(v) spAmt = v end })
				S:Button({ Title = "Spawn item", Desc = "into trade inventory + game inventory",
					Callback = function() doSpawn(spName, spAmt, false) end })
				S:Button({ Title = "Equip item", Desc = "equip it in your hand (client-side)",
					Callback = function()
						local it = rankMatches(spName)[1]
						if not it then notify("Equip", "no match for \""..tostring(spName).."\"") return end
						doSpawn(spName, 1, false)                 -- add to trade + game inventory
						-- task.spawn: MH_equipItem may yield (game:GetObjects loads the asset)
						task.spawn(function()
							local okq, detail, how = MH_equipItem(it.key, it.name)
							pcall(function() setclipboard("MH EQUIP: " .. tostring(detail)) end)
							-- keep the toast SHORT; full diagnostic goes to the clipboard
							notify("Equip", it.name .. (okq and (" - in hand [" .. tostring(how) .. "]")
								or " - menu only (diag copied)"))
						end)
					end })
				S:Toggle({ Title = "Equip from inventory", Default = true,
					Desc = "clicking an item in the game's own inventory wears its skin",
					Callback = function(v)
						_G.MH_InventoryEquip = v and true or false
						if v then MH_watchInventory() end
					end })
				S:Button({ Title = "Remove skin", Desc = "put your real weapon look back",
					Callback = function()
						local n = MH_restoreSkins()
						notify("Equip", "restored " .. tostring(n) .. " mesh(es)")
					end })
				S:Button({ Title = "Forget skins", Desc = "wipe the learned skin map",
					Callback = function()
						MH_restoreSkins()
						notify("Skins", "forgot " .. tostring(MH_forgetSkins()) .. " entries")
					end })
				S:Button({ Title = "Copy skins", Desc = "learned skin map to clipboard",
					Callback = function()
						local txt = "{}"
						pcall(function()
							txt = game:GetService("HttpService"):JSONEncode(_G.MH_MeshMap or {})
						end)
						pcall(function() setclipboard(txt) end)
						notify("Skins", "copied to clipboard")
					end })
				S:Button({ Title = "Learn MY items", Desc = "equip each item you own, record its real skin",
					Callback = function()
						if _G.MH_LearnBusy then
							_G.MH_LearnStop = true
							notify("Skins", "stopping...")
							return
						end
						task.spawn(function()
							_G.MH_LearnBusy = true
							notify("Skins", "learning your inventory - this takes a few minutes")
							local ok, a, b, c, d, why, known, note = pcall(MH_learnOwned, function(l, t, total)
								notify("Skins", l .. " learned / " .. t .. " tried of " .. total)
							end)
							_G.MH_LearnBusy = false
							if ok then
								local msg = "+" .. tostring(a) .. " of " .. tostring(b)
									.. " (refused " .. tostring(c) .. ", no display " .. tostring(d)
									.. ", known " .. tostring(known) .. ")"
								if tostring(why) ~= "ok" then msg = tostring(why) .. " | " .. msg end
								pcall(function()
									setclipboard("MH LEARN: " .. msg .. " | " .. tostring(note))
								end)
								notify("Skins", msg)
							else
								notify("Skins", "failed: " .. tostring(a))
							end
						end)
					end })
				S:Button({ Title = "Learn skins", Desc = "read real weapon meshes off nearby players",
					Callback = function()
						task.spawn(function()
							MH_loadMeshMap()
							local lrn, tot = MH_learnMeshes()
							notify("Skins", "+" .. tostring(lrn) .. " learned, " .. tostring(tot) .. " known")
						end)
					end })
				S:Button({ Title = "Load LIVE items", Desc = "read the real catalog from memory",
					Callback = function()
						task.spawn(function()
							pcall(loadLiveCatalog)
							notify("Catalog", CatalogStatus)
							if catDrop then pcall(function() catDrop:Refresh(catalogNames()) end) end
						end)
					end })
			end)
			if not _ok_2 then warn("[TradeDebug] Rubis tab Spawner error: "..tostring(_e_2)) end

			-- ================= TAB 4: Music =================
			local _ok_3, _e_3 = pcall(function()
				local music = game:GetService("SoundService"):FindFirstChild("MollyHubMusic")
				if not music then
					music = Instance.new("Sound")
					music.Name = "MollyHubMusic"; music.Looped = true; music.Volume = 0.5
					music.SoundId = "rbxassetid://0"
					pcall(function() music.Parent = game:GetService("SoundService") end)
				end
				local Mu = Win:Tab({ Title = "Music", Icon = "music", ShowTabTitle = true })
				Mu:Section({ Title = "Music" })
				-- Popular tracks (Roblox audio ids). Roblox moderates audio, so if one
				-- doesn't play it was taken down - pick another or paste your own id below.
				local MUSIC_LIST = {
					["Believer - Imagine Dragons"] = "rbxassetid://1725787491",
					["Blinding Lights - The Weeknd"] = "rbxassetid://5555445124",
					["Sunflower - Post Malone"]      = "rbxassetid://2531943421",
					["Astronaut In The Ocean"]       = "rbxassetid://6403500775",
					["STAY - Kid Laroi"]             = "rbxassetid://7317666452",
					["Sweet Dreams"]                 = "rbxassetid://5843014871",
				}
				local musNames = {}
				for k in pairs(MUSIC_LIST) do musNames[#musNames + 1] = k end
				table.sort(musNames)
				pcall(function()
					Mu:Dropdown({ Title = "Popular tracks", Desc = "pick a song, then Play",
						Values = musNames, Value = "", Compact = true, AllowNone = true,
						Callback = function(v)
							local id = MUSIC_LIST[v]
							if id and id ~= "" then music.SoundId = id end
						end })
				end)
				Mu:Input({ Title = "Custom music ID", Placeholder = "rbxassetid://... or a number",
					Callback = function(v)
						v = tostring(v)
						if v ~= "" then music.SoundId = v:find("rbxassetid") and v or ("rbxassetid://" .. v:gsub("%D", "")) end
					end })
				Mu:Toggle({ Title = "Play music", Default = false,
					Callback = function(on) if on then pcall(function() music:Play() end) else pcall(function() music:Pause() end) end end })
				Mu:Slider({ Title = "Volume", Value = { Min = 0, Max = 1, Default = 0.5 },
					Callback = function(v) music.Volume = tonumber(v) or 0.5 end })
			end)
			if not _ok_3 then warn("[TradeDebug] Rubis tab Music error: "..tostring(_e_3)) end

			-- ================= TAB 5: Settings =================
			local _ok_4, _e_4 = pcall(function()
				local Set = Win:Tab({ Title = "Settings", Icon = "settings", ShowTabTitle = true })
				Set:Section({ Title = "Theme" })
				local themeDrop
				pcall(function()
					themeDrop = Set:Dropdown({ Title = "Theme", Desc = "menu colours", Compact = true,
						Values = { "Blue-Gray", "Black" }, Value = "Blue-Gray",
						Callback = function(v) if type(v) == "string" and v ~= "" then applyTheme(v) end end })
				end)
				Set:Input({ Title = "Theme code", Placeholder = "enter a code to unlock a theme",
					Callback = function(v)
						if tostring(v) == "secret1337" and not secretUnlocked then
							secretUnlocked = true
							if themeDrop then pcall(function() themeDrop:Refresh({ "Blue-Gray", "Black", "Secret" }) end) end
							applyTheme("Secret")
							notify("Theme", "Secret theme unlocked!")
						end
					end })
				Set:Section({ Title = "Debug" })
				Set:Button({ Title = "Dump GUI tree", Desc = "on-screen panel + clipboard + MollyHub_dump.txt",
					Callback = function()
						local ok = pcall(MH_Dump)
						notify("Dump", ok and "shown on screen + copied to clipboard" or "dump failed")
					end })
			end)
			if not _ok_4 then warn("[TradeDebug] Rubis tab Settings error: "..tostring(_e_4)) end

				-- ================= TAB 6: Keybinds =================
				-- Dynamic list: "+ Add keybind" makes a new (key + item) pair. Pressing
				-- the chosen key spawns that item into Player 2's offer.
				local _ok_kb, _e_kb = pcall(function()
					local KB = Win:Tab({ Title = "Keybinds", Icon = "box", ShowTabTitle = true })
					-- Trade keybind: make the OTHER side (Player 2) accept on a keypress.
					KB:Section({ Title = "Trade keybinds" })
					local p2AcceptKey = Enum.KeyCode.Unknown
					pcall(function()
						KB:Keybind({ Title = "Player 2 accepts", Desc = "press to make the other side accept", Value = "",
							Callback = function(k)
								local ok2, kc = pcall(function() return Enum.KeyCode[k] end)
								if ok2 and kc then p2AcceptKey = kc end
							end })
					end)
					local testPopupKey = Enum.KeyCode.Unknown
					pcall(function()
						KB:Keybind({ Title = "Test received popup", Desc = "fire the game item-received popup for the Spawner item", Value = "",
							Callback = function(k)
								local ok2, kc = pcall(function() return Enum.KeyCode[k] end)
								if ok2 and kc then testPopupKey = kc end
							end })
					end)
					KB:Section({ Title = "Item keybinds" })
					local binds = {}
					KB:Button({ Title = "+ Add keybind", Desc = "pick a key + an item to spawn to P2",
						Callback = function()
							local b = { key = Enum.KeyCode.Unknown, item = "" }
							binds[#binds + 1] = b
							local n = #binds
							pcall(function()
								KB:Keybind({ Title = "Key #" .. n, Desc = "press to set the key", Value = "",
									Callback = function(k)
										local ok2, kc = pcall(function() return Enum.KeyCode[k] end)
										if ok2 and kc then b.key = kc end
									end })
							end)
							pcall(function()
								KB:Input({ Title = "Item #" .. n, Placeholder = "e.g. Chroma Seer",
									Callback = function(v) b.item = v end })
							end)
						end })
					track(UIS.InputBegan:Connect(function(input, gp)
						if gp then return end
						if p2AcceptKey ~= Enum.KeyCode.Unknown and input.KeyCode == p2AcceptKey
							and HarnessTradeActive then          -- only in OUR fake trade, never a real one
							pcall(forceRemoteAccept)  -- other side accepts (+ completes if you also did)
						end
						if testPopupKey ~= Enum.KeyCode.Unknown and input.KeyCode == testPopupKey then
							local it = rankMatches(spName)[1]
							if it then MH_fireReceived({ { key = it.key, cat = it.cat } }) end
						end
						for _, b in ipairs(binds) do
							if b.key ~= Enum.KeyCode.Unknown and input.KeyCode == b.key and b.item ~= "" then
								doSpawn(b.item, 1, true)
							end
						end
					end))
				end)
				if not _ok_kb then warn("[TradeDebug] Rubis tab Keybinds error: "..tostring(_e_kb)) end

				-- ================= TAB 7: Configs =================
				-- Save the whole Add-Items inventory as a named config and spawn it back with
				-- one press. Includes a built-in preset pack.
				local _ok_cf, _e_cf = pcall(function()
					local CF = Win:Tab({ Title = "Configs", Icon = "box", ShowTabTitle = true })
					CF:Section({ Title = "Inventory configs" })
					local cfgSel, cfgName = "", ""
					local cfgDrop
					pcall(function()
						cfgDrop = CF:Dropdown({ Title = "Saved configs", Desc = "pick one, then Load", Compact = true,
							Values = MH_ConfigNames(), Value = "", AllowNone = true,
							Callback = function(v) if type(v) == "string" then cfgSel = v end end })
					end)
					CF:Button({ Title = "Load config (spawn all)", Desc = "spawns the whole saved inventory",
						Callback = function()
							if cfgSel == "" then notify("Configs", "pick a config first") return end
							if MH_ApplyConfig(cfgSel) then notify("Configs", "Loaded: " .. cfgSel)
							else notify("Configs", "load failed") end
						end })
					CF:Input({ Title = "New config name", Placeholder = "my loadout",
						Callback = function(v) cfgName = v end })
					CF:Button({ Title = "Save current inventory", Desc = "saves everything in Add Items",
						Callback = function()
							if cfgName == "" then notify("Configs", "enter a name") return end
							MH_SaveCurrent(cfgName)
							if cfgDrop then pcall(function() cfgDrop:Refresh(MH_ConfigNames()) end) end
							notify("Configs", "Saved: " .. cfgName)
						end })
					CF:Button({ Title = "Delete selected config", Desc = "presets can't be deleted",
						Callback = function()
							if cfgSel ~= "" and MH_DeleteConfig(cfgSel) then
								if cfgDrop then pcall(function() cfgDrop:Refresh(MH_ConfigNames()) end) end
								notify("Configs", "Deleted: " .. cfgSel)
							else notify("Configs", "can't delete that") end
						end })
				end)
				if not _ok_cf then warn("[TradeDebug] Rubis tab Configs error: "..tostring(_e_cf)) end

			-- ================= background photo + theme reskin =================
			task.spawn(function()
				local function injectPhoto(g)
					if g:GetAttribute("__MHbg") then return end
					local img0 = THEME_IMAGES[currentTheme] or BG_IMAGE
					if img0 == "" or img0 == "rbxassetid://0" then return end
					local win, area
					for _, d in ipairs(g:GetDescendants()) do
						if (d:IsA("Frame") or d:IsA("CanvasGroup")) and d.Visible
							and d.AbsoluteSize.X > 220 and d.AbsoluteSize.Y > 150 then
							local a = d.AbsoluteSize.X * d.AbsoluteSize.Y
							if not area or a > area then win, area = d, a end
						end
					end
					if not win then return end
					g:SetAttribute("__MHbg", true)
					local img = Instance.new("ImageLabel")
					img.Name = "__MHPhoto"; img.Size = UDim2.new(1, 0, 1, 0)
					img.BackgroundTransparency = 1; img.Image = img0
					img.ScaleType = Enum.ScaleType.Crop; img.ImageTransparency = 0.5
					local z = math.huge
					for _, ch in ipairs(win:GetChildren()) do
						if ch:IsA("GuiObject") then z = math.min(z, ch.ZIndex) end
					end
					img.ZIndex = (z == math.huge) and 0 or (z - 1)
					local uc = Instance.new("UICorner"); uc.CornerRadius = UDim.new(0, 12); uc.Parent = img
					img.Parent = win
				end
				for _ = 1, 10 do
					task.wait(0.3)
					for _, root in ipairs(guiRoots) do
						for _, g in ipairs(root:GetChildren()) do
							if g:IsA("ScreenGui") and not seenGui[g] then pcall(injectPhoto, g) end
						end
					end
					applyTheme(currentTheme)
				end
			end)

			-- Rubis is fully up: mark ready so the watchdog leaves it alone.
			Runtime.RubisReady = true
		end)
		if not built then
			-- The Rubis build errored — show the error on screen (no fallback panel).
			warn("[TradeDebug] Rubis build failed: " .. tostring(builtErr))
			__showFatal("Rubis menu failed to build: " .. tostring(builtErr))
			return
		end
	end)
end

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

	-- Fire on both signals so the hook triggers regardless of button class,
	-- guarding against a double-open with a short debounce.
	local lastOpen = 0
	local function onAccept()
		-- Only hijack the native request-Accept when WE armed a fake request, and
		-- CONSUME the arm immediately so a real trade request accepted afterwards
		-- passes straight through, untouched.
		if not HarnessRequestArmed then return end
		if os.clock() - lastOpen < 0.3 then return end
		lastOpen = os.clock()
		HarnessRequestArmed = false
		startTrade(PendingP2Name or currentName())
	end
	-- Decline hides the modal and disarms the fake flow. Bound the same
	-- re-hooking way as Accept — the old one-time, PC-only-path bind was why
	-- Decline did nothing on phone.
	local function onDecline()
		HarnessTradeActive = false; HarnessRequestArmed = false
		if RequestFrame then pcall(function() RequestFrame.Visible = false end) end
		-- Declining abandons the trade. Fully reset it so nothing leaks into the NEXT
		-- trade (real or fake): give YOUR staged items back to the inventory, drop the
		-- fake P2 offer, clear the accepted flags/badges + the accept confirm/cancel/
		-- cooldown, then re-render so EVERY offer slot goes blank. (A real trade that
		-- opens the same native frames afterwards must not show the old items.)
		returnOfferToInventory("Player1")             -- empties Player1.Offer (+ refunds)
		DebugTradeTable.Player2.Offer = {}            -- fake other side: just discard
		DebugTradeTable.Player1.Accepted = false
		DebugTradeTable.Player2.Accepted = false
		pcall(function() showAcceptedBadge("your", false) end)
		pcall(function() showAcceptedBadge("their", false) end)
		if stopAcceptCooldown then pcall(stopAcceptCooldown) end
		setVisible(TradeRoot, "Actions.Accept.Confirm", false)
		setVisible(TradeRoot, "Actions.Accept.Cancel", false)
		pcall(renderInventory)
		pcall(RenderTrade)                            -- blanks both offers' slots
	end
	local function findRequestDecline()
		if not RequestFrame then return nil end
		local scope = resolve(RequestFrame, "Accepting") or RequestFrame
		local node = scope:FindFirstChild("Decline", true) or scope:FindFirstChild("No", true)
		return firstButtonIn(node)
	end
	-- (Re)bind the CURRENT native Accept + Decline buttons, skipping ones already
	-- hooked. The game can rebuild these between trades, so binding once left the
	-- second trade dead — showRequestModal calls this on every show.
	-- Bind a tap on a button across mouse AND touch. Some phone builds don't fire
	-- MouseButton1Click/Activated on the request buttons, so we also listen to raw
	-- InputBegan (touch/click) on the button and everything inside it. The handlers
	-- are debounced/idempotent, so multiple signals firing is harmless.
	local function bindTap(btn, fn)
		pcall(function() btn.Active = true end)
		track(btn.MouseButton1Click:Connect(fn))
		track(btn.Activated:Connect(fn))
		local function onInput(input)
			if input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseButton1 then fn() end
		end
		track(btn.InputBegan:Connect(onInput))
		for _, d in ipairs(btn:GetDescendants()) do
			if d:IsA("GuiObject") then track(d.InputBegan:Connect(onInput)) end
		end
	end
	hookRequestAccept = function()
		local btn = findRequestAccept()
		if btn and not btn:GetAttribute("__MHacc") then
			btn:SetAttribute("__MHacc", true)
			bindTap(btn, onAccept)
		end
		local dec = findRequestDecline()
		if dec and not dec:GetAttribute("__MHdec") then
			dec:SetAttribute("__MHdec", true)
			bindTap(dec, onDecline)
		end
	end
	hookRequestAccept()  -- initial bind
	if not findRequestAccept() then
		warn("[TradeDebug] Native request Accept button not found at load.")
	end

	-- Robust fallback for phones where the button's OWN click/touch events never
	-- fire (which is why accept did nothing on mobile): detect the tap by SCREEN
	-- POSITION over the accept/decline button instead. onAccept keeps its
	-- HarnessTradeActive guard + debounce, so this only acts on our fake request.
	local function inBounds(pos, gui)
		if not (gui and gui.Visible) then return false end
		local ap, sz = gui.AbsolutePosition, gui.AbsoluteSize
		if sz.X < 4 or sz.Y < 4 then return false end
		return pos.X >= ap.X and pos.X <= ap.X + sz.X and pos.Y >= ap.Y and pos.Y <= ap.Y + sz.Y
	end
	track(UIS.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Touch
			and input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		if not (RequestFrame and RequestFrame.Visible) then return end
		local pos = input.Position
		local dec = findRequestDecline()
		if dec and inBounds(pos, dec) then onDecline(); return end
		local acc = findRequestAccept()
		if acc and inBounds(pos, acc) then onAccept() end
	end))
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
			-- Empty trade: the button is greyed, so accepting does nothing (like MM2).
			if (#DebugTradeTable.Player1.Offer + #DebugTradeTable.Player2.Offer) <= 0 then return end
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

-- Load the LIVE catalog. Prefer reading it straight from memory (require + getgc)
-- — that is reliable and needs NO server round-trip, so item tags (Event/Year/
-- Chroma/Evo) and rarity colours are the game's real ones. Only if that never
-- succeeds do we fall back to the slow GetSyncData:InvokeServer probe (which
-- times out on many executors — hence it is the LAST resort, not the first).
task.spawn(function()
	for _ = 1, 8 do
		local ok, live = pcall(loadLiveCatalog)
		if ok and live then
			print("[TradeDebug] LIVE catalog loaded from memory (" .. countKeys(ItemDB) .. " items).")
			return
		end
		task.wait(3)
	end
	-- getgc/require never produced the catalog — try the server probe as a fallback.
	if not RealCatalog then task.spawn(applyRealData) end
end)

-- Watch the game's own inventory so equipping there wears the skin.
task.spawn(function()
	MH_loadMeshMap()
	MH_watchInventory()
end)

print("[TradeDebug] Harness loaded. Layout: " .. (TradeGUI and TradeGUI.Name or "NOT FOUND") ..
	" | Use the TradeDebugPanel to drive the offline trade.")

end, function(e)
	local tb = ""
	pcall(function() tb = debug.traceback() end)
	return tostring(e) .. "\n\n" .. tostring(tb)
end)
if not __ok then __showFatal(__err) end
