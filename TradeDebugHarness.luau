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
	if label and label:IsA("TextLabel") then pcall(function() label.Text = text end) end
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

-- Default starter items are never tradeable and never consumed (like the game).
local function isDefaultItem(key)
	return key == "DefaultKnife" or key == "DefaultGun"
end

-- Place ONE copy of an item into the current side's offer, CONSUMING it from the
-- inventory (Add Items) — exactly like the game moves an item out of your pack
-- and into the offer. Removing it later (tap the offer slot) returns it.
local function offerItemLocal(itemKey, category, visual)
	if isDefaultItem(itemKey) then return end       -- defaults can't be traded
	-- In overlay mode everything goes on YOUR side (you can't fill a real player's).
	local side = OverlayMode and DebugTradeTable.Player1 or DebugTradeTable[OfferMode]
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
	if not isDefaultItem(entry[1]) then
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
	renderInventory()
	RenderTrade()
	if not OverlayMode and startAcceptCooldown then startAcceptCooldown() end
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
	-- FX: only reveal a REAL FX frame if the game's slot has one (no synthetic
	-- badge). This build's trade slot has none, so nothing shows for now.
	if data.FX ~= nil or data.Effect ~= nil or data.HasFX ~= nil then showBadge(tags, "FX") end
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
		cache = { container = container, template = sample:Clone(), cell = sample.AbsoluteSize }
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
	HarnessTradeActive = true  -- arm the native-Accept hijack for OUR fake flow
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
		task.delay(2, function()
			-- Abort if a new trade started in the meantime.
			if myToken ~= completeToken then return end
			if processing then processing.Visible = false end
			if TradeGUI and TradeGUI:IsA("ScreenGui") then TradeGUI.Enabled = false end
			if Container then Container.Visible = false end
			-- Reset accepted state so the NEXT trade starts clean.
			DebugTradeTable.Player1.Accepted = false
			DebugTradeTable.Player2.Accepted = false
			HarnessTradeActive = false  -- disarm; re-shown request re-arms it
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
function startTrade(player2Name)
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

	-- Open the Trade panel. Bring the trade ScreenGui + ancestor chain on-screen.
	if TradeGUI and TradeGUI:IsA("ScreenGui") then TradeGUI.Enabled = true end
	revealAncestors(Offer1 or TradeRoot or Container)
	if Container then Container.Visible = true end
	if TradeRoot then TradeRoot.Visible = true end
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
	HarnessTradeActive = false  -- disarm the native-Accept hijack
	OverlayMode = false         -- idle the overlay refresh loop
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

-- Background image + overlay for readability. The image sits at ~50% transparency
-- (half see-through) with a slight dark scrim on top so the menu stays legible.
local Bg = Instance.new("ImageLabel")
Bg.Name = "Bg"; Bg.Size = UDim2.new(1, 0, 1, 0); Bg.BackgroundTransparency = 1
Bg.Image = BG_IMAGE; Bg.ScaleType = Enum.ScaleType.Crop
Bg.ImageTransparency = 0.5; Bg.ZIndex = 0; Bg.Parent = Window
-- Dark tint over the image so it reads a bit darker ("чуть потемнее"). Lower the
-- transparency for MORE darkening, raise it for a brighter image.
local Overlay = Instance.new("Frame")
Overlay.Size = UDim2.new(1, 0, 1, 0); Overlay.BackgroundColor3 = Color3.fromRGB(12, 16, 24)
Overlay.BackgroundTransparency = 0.3; Overlay.BorderSizePixel = 0; Overlay.ZIndex = 0; Overlay.Parent = Window

-- Sidebar (left).
local Side = Instance.new("Frame")
Side.Name = "Sidebar"; Side.Size = UDim2.new(0, 122, 1, 0)
Side.BackgroundColor3 = C_SIDE; Side.BackgroundTransparency = 0.35
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

-- A slim section header (organizes the single Trade tab into labelled groups).
local function makeSection(page, title)
	rowOrder = rowOrder + 1
	local h = Instance.new("TextLabel")
	h.Size = UDim2.new(1, 0, 0, 22); h.BackgroundTransparency = 1
	h.Text = "— " .. title:upper() .. " —"; h.TextColor3 = C_ACCENT
	h.Font = Enum.Font.GothamBold; h.TextSize = 12
	h.TextXAlignment = Enum.TextXAlignment.Left
	h.ZIndex = 3; h.LayoutOrder = rowOrder; h.Parent = page
	return h
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
makeSection(pTrade, "Trade")

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

local _, setP2Side = makeRowToggle(pTrade, "Add to Player 2 side", "off = your side (left) / on = right", false, function(on)
	OfferMode = on and "Player2" or "Player1"
end)
-- Every fresh trade starts on YOUR side again (fixes: a "fake" P2-side trade
-- left the toggle on, so the next real trade still filled the P2 side).
table.insert(onNewTrade, function() OfferMode = "Player1"; setP2Side(false) end)

-- OVERLAY toggle: use the fake inventory + fake slots ON TOP of a REAL trade.
-- Turn it on WHILE you're in a genuine game trade: the Add Items grid becomes the
-- fake inventory, tapping paints fake items onto YOUR side only (visual, nothing
-- sent, the other player never sees it), and the real player's offer is left
-- alone. A background loop re-asserts your fake side so the game can't wipe it.
makeRowToggle(pTrade, "Overlay on REAL trade", "fake items on your side (visual only)", false, function(on)
	OverlayMode = on
	if on then
		pcall(openItemsPicker)  -- reveal + fill the fake Add Items grid
	end
	pcall(RenderTrade)
end)
-- Re-paint your fake side a few times a second so the real game's own trade
-- render can't overwrite the fake items while Overlay is on.
task.spawn(function()
	while true do
		if OverlayMode then pcall(RenderTrade) end
		task.wait(0.4)
	end
end)

-- Background MUSIC: paste your audio asset id on the marked line below, then use
-- the "Music" toggle to play/stop it (loops). Wrapped in a do-block so it adds no
-- lasting local (the harness is close to Luau's 200-local-per-function limit).
do
	local music = Instance.new("Sound")
	music.Name = "MollyHubMusic"
	--  ▼▼▼  PASTE YOUR MUSIC ID HERE (keep the rbxassetid:// prefix)  ▼▼▼
	music.SoundId = "rbxassetid://0"
	--  ▲▲▲  ---------------------------------------------------------  ▲▲▲
	music.Looped = true
	music.Volume = 0.5
	pcall(function() music.Parent = game:GetService("SoundService") end)
	makeRowToggle(pTrade, "Music", "play background music (set id in script)", false, function(on)
		if on then pcall(function() music:Play() end) else pcall(function() music:Pause() end) end
	end)
end

--------------------------------------------------------------------------------
-- PAGE 2 — Spawn (add game items into your inventory)
--------------------------------------------------------------------------------
-- Two tabs: Trade and Spawn. The spawner gets its own tab; Accept + Info fold
-- into the Trade tab (they alias pTrade below).
local pSpawn = makeTab("Spawn")

-- Flat, name-sorted index of the whole catalog (weapons + pets), rebuildable
-- when the real catalog finishes loading in the background.
local spawnIndex = {}
local function buildSpawnIndex()
	spawnIndex = {}
	for k, v in pairs(ItemDB) do
		-- Only real, individually-tradeable weapons (Knife / Gun). This drops the
		-- non-tradeable "Item Pack" / Misc bundles that showed as fake entries.
		if type(v) == "table" and (v.ItemType == "Knife" or v.ItemType == "Gun") then
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
end)

-- Dump the STRUCTURE of the first few detected WEAPON slots so the real slot
-- layout is visible (screenshot it). This is how we stop guessing the tree.
makeRowButton(pSpawn, "Dump slots", "show inventory container + slot", "Dump", C_ACCENT, function()
	local lines = {}
	local function kidsOf(node)
		local ch = {}
		for _, c in ipairs(node:GetChildren()) do
			local t = (c:IsA("TextLabel") or c:IsA("TextButton") or c:IsA("TextBox"))
				and ("'" .. tostring(c.Text):sub(1, 10) .. "'") or ""
			table.insert(ch, c.Name .. "(" .. c.ClassName .. ")" .. t)
		end
		return table.concat(ch, ", ")
	end
	-- The container we actually render the inventory into.
	local cont = InvContainer
	if cont then
		local sz = cont.AbsoluteSize
		table.insert(lines, "InvContainer: " .. cont:GetFullName():gsub("Players%.[^.]+%.PlayerGui%.", ""))
		table.insert(lines, ("  <%s>  size=%dx%d"):format(cont.ClassName, math.floor(sz.X), math.floor(sz.Y)))
		local lay
		for _, c in ipairs(cont:GetChildren()) do
			if c:IsA("UIGridLayout") or c:IsA("UIListLayout") then lay = c break end
		end
		if lay then
			local cs = lay:IsA("UIGridLayout") and lay.CellSize or nil
			table.insert(lines, "  layout=" .. lay.ClassName .. (cs and (" cell=" .. math.floor(cs.X.Offset) .. "x" .. math.floor(cs.Y.Offset)) or ""))
		else
			table.insert(lines, "  layout= NONE")
		end
		-- first rendered slot's structure (for the rarity plate)
		for _, s in ipairs(cont:GetChildren()) do
			if s:IsA("GuiObject") and s:GetAttribute("__MHSpawn") then
				table.insert(lines, "slot=" .. s.Name .. "<" .. s.ClassName .. ">")
				table.insert(lines, "  kids:" .. kidsOf(s))
				local inm = s:FindFirstChild("ItemName")
				if inm then
					table.insert(lines, "  ItemName<" .. inm.ClassName .. ">:" .. kidsOf(inm))
				end
				local tg = s:FindFirstChild("Tags")
				if tg then
					table.insert(lines, "  Tags:" .. kidsOf(tg))
					-- Full per-badge detail (class + Visible) so we can see if an FX
					-- badge frame exists in this build and whether it's showing.
					for _, b in ipairs(tg:GetChildren()) do
						if b:IsA("GuiObject") then
							table.insert(lines, ("   • %s(%s) vis=%s kids[%s]"):format(
								b.Name, b.ClassName, tostring(b.Visible), kidsOf(b)))
						end
					end
				end
				break
			end
		end
	else
		table.insert(lines, "InvContainer nil — open Add Items first")
	end
	table.insert(lines, "Rarity['Godly']=" .. tostring(Rarity["Godly"]))
	Diag.Text = table.concat(lines, "\n")
	Diag.Visible = true
end)

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

makeRowButton(pSpawn, "Load LIVE items", "read the real catalog from memory", "Live", C_GREEN, function()
	local lines = {}
	local function show() Diag.Text = table.concat(lines, "\n"); Diag.Visible = true end
	local live, why = loadLiveCatalog()
	if live then
		lines[#lines + 1] = "✓ LIVE catalog loaded from memory!"
		lines[#lines + 1] = countKeys(ItemDB) .. " items, " .. countKeys(PetDB) .. " pets"
		lines[#lines + 1] = "Add Items now uses REAL game data — search any item."
	else
		lines[#lines + 1] = "live load failed: " .. tostring(why)
		lines[#lines + 1] = "tip: open your inventory in-game once, then tap Live again."
		local gsd = findGetSync()
		lines[#lines + 1] = "GetSyncData remote: " .. (gsd and "found" or "not found")
	end
	show()
end)

-- Open the "Add Items" panel — the full catalog, searchable, tap to add.
makeRowButton(pSpawn, "Open Add Items", "browse & tap the whole catalog", "Open", C_GREEN, function()
	openItemsPicker()
	CatLabel.Text = ("Add Items: %d weapons + %d pets — search & tap to add"):format(
		countKeys(ItemDB), countKeys(PetDB))
	CatLabel.TextColor3 = C_GREEN
end)

-- Spawn `amount` copies into the trade's OWN inventory (the "Add Items" panel).
-- Exactly like the game: the item appears in the trade inventory, and you tap it
-- there to place it into the offer. No separate menu, no going out of the trade.
local function spawnEntry(it, amount)
	amount = math.max(1, math.floor(tonumber(amount) or 1))
	local list = (it.cat == "Pets") and SpawnedPets or SpawnedWeapons
	list[it.key] = (list[it.key] or 0) + amount
	openItemsPicker()     -- make sure the trade's Add Items panel is open + rendered
	renderInventory()     -- re-render so the new item shows in it
	return list[it.key]
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

-- Row: item-name box + amount box + Spawn button (spawns the top match).
local spawnRow = makeRow(pSpawn, "Spawn item", "type a name · pick amount · Spawn")
local SpawnNameBox = Instance.new("TextBox")
SpawnNameBox.Size = UDim2.new(0, 132, 0, 30); SpawnNameBox.Position = UDim2.new(1, -222, 0.5, -15)
SpawnNameBox.BackgroundColor3 = C_BG; SpawnNameBox.Text = ""
SpawnNameBox.PlaceholderText = "item name…"; SpawnNameBox.PlaceholderColor3 = C_DIM
SpawnNameBox.TextColor3 = C_TXT; SpawnNameBox.Font = Enum.Font.Gotham; SpawnNameBox.TextSize = 12
SpawnNameBox.TextXAlignment = Enum.TextXAlignment.Left
SpawnNameBox.ClearTextOnFocus = false; SpawnNameBox.BorderSizePixel = 0; SpawnNameBox.ClipsDescendants = true
SpawnNameBox.ZIndex = 4; SpawnNameBox.Parent = spawnRow; corner(SpawnNameBox, 8); pad(SpawnNameBox, 6)

local AmountBox = Instance.new("TextBox")
AmountBox.Size = UDim2.new(0, 40, 0, 30); AmountBox.Position = UDim2.new(1, -84, 0.5, -15)
AmountBox.BackgroundColor3 = C_BG; AmountBox.Text = "1"
AmountBox.PlaceholderText = "x1"; AmountBox.PlaceholderColor3 = C_DIM
AmountBox.TextColor3 = C_TXT; AmountBox.Font = Enum.Font.GothamMedium; AmountBox.TextSize = 12
AmountBox.TextXAlignment = Enum.TextXAlignment.Center
AmountBox.ClearTextOnFocus = false; AmountBox.BorderSizePixel = 0
AmountBox.ZIndex = 4; AmountBox.Parent = spawnRow; corner(AmountBox, 8)

local SpawnBtn = Instance.new("TextButton")
SpawnBtn.Size = UDim2.new(0, 36, 0, 30); SpawnBtn.Position = UDim2.new(1, -42, 0.5, -15)
SpawnBtn.BackgroundColor3 = C_GREEN; SpawnBtn.Text = "＋"; SpawnBtn.TextColor3 = C_TXT
SpawnBtn.Font = Enum.Font.GothamBold; SpawnBtn.TextSize = 16; SpawnBtn.BorderSizePixel = 0
SpawnBtn.ZIndex = 4; SpawnBtn.Parent = spawnRow; corner(SpawnBtn, 8)

-- Feedback line (what got spawned / not found), coloured by rarity.
rowOrder = rowOrder + 1
local SpawnMsg = Instance.new("TextLabel")
SpawnMsg.Size = UDim2.new(1, 0, 0, 16); SpawnMsg.BackgroundTransparency = 1
SpawnMsg.Text = ""; SpawnMsg.TextColor3 = C_DIM; SpawnMsg.Font = Enum.Font.GothamMedium
SpawnMsg.TextSize = 12; SpawnMsg.TextXAlignment = Enum.TextXAlignment.Left
SpawnMsg.ZIndex = 2; SpawnMsg.LayoutOrder = rowOrder; SpawnMsg.Parent = pSpawn

rowOrder = rowOrder + 1
local SpawnList = Instance.new("Frame")
SpawnList.Size = UDim2.new(1, 0, 0, 0); SpawnList.AutomaticSize = Enum.AutomaticSize.Y
SpawnList.BackgroundColor3 = C_BG; SpawnList.BorderSizePixel = 0; SpawnList.ZIndex = 2
SpawnList.LayoutOrder = rowOrder; SpawnList.Parent = pSpawn
corner(SpawnList, 10)
local sll = Instance.new("UIListLayout")
sll.Padding = UDim.new(0, 4); sll.SortOrder = Enum.SortOrder.LayoutOrder; sll.Parent = SpawnList
pad(SpawnList, 6)

local function announceSpawn(it, total)
	SpawnMsg.Text = ("✓ %s  [%s]  → in trade inventory (x%d) — tap it in Add Items"):format(it.name, tostring(it.rarity or "?"), total)
	SpawnMsg.TextColor3 = (it.rarity == "Common") and C_TXT or (Rarity[it.rarity] or C_TXT)
end

-- Live results list: each match is a rarity-coloured button; tap = spawn `amount`.
local function refreshSpawn(query)
	for _, c in ipairs(SpawnList:GetChildren()) do
		if c:IsA("TextButton") or c:IsA("TextLabel") then c:Destroy() end
	end
	local matches = rankMatches(query)
	for i, it in ipairs(matches) do
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(1, 0, 0, 28); b.BackgroundColor3 = C_BTN
		b.Text = "  " .. it.name .. "   " .. tostring(it.rarity or "") .. "   ＋"
		b.TextXAlignment = Enum.TextXAlignment.Left
		b.TextColor3 = (it.rarity == "Common") and C_TXT or (Rarity[it.rarity] or C_TXT)
		b.Font = Enum.Font.Gotham; b.TextSize = 12; b.BorderSizePixel = 0
		b.ZIndex = 3; b.LayoutOrder = i; b.Parent = SpawnList; corner(b, 6)
		track(b.MouseButton1Click:Connect(function()
			local total = spawnEntry(it, AmountBox.Text)
			announceSpawn(it, total)
		end))
	end
	if #matches == 0 then
		local e = Instance.new("TextLabel")
		e.Size = UDim2.new(1, 0, 0, 24); e.BackgroundTransparency = 1
		e.Text = "no matches"; e.TextColor3 = C_DIM; e.Font = Enum.Font.Gotham
		e.TextSize = 12; e.ZIndex = 3; e.Parent = SpawnList
	end
end

-- Spawn button: resolve the typed name to its best match and spawn `amount`.
track(SpawnBtn.MouseButton1Click:Connect(function()
	local matches = rankMatches(SpawnNameBox.Text)
	local it = matches[1]
	if not it then
		SpawnMsg.Text = "✗ no item matches \"" .. tostring(SpawnNameBox.Text) .. "\""
		SpawnMsg.TextColor3 = C_RED
		return
	end
	local total = spawnEntry(it, AmountBox.Text)
	announceSpawn(it, total)
end))

track(SpawnNameBox:GetPropertyChangedSignal("Text"):Connect(function()
	refreshSpawn(SpawnNameBox.Text)
end))
refreshSpawn("")

-- When the real catalog/inventory finishes loading in the background, rebuild.
onCatalogLoaded = function()
	buildSpawnIndex()
	refreshSpawn(SpawnNameBox.Text)
	renderInventory()
	CatLabel.Text = CatalogStatus
end

--------------------------------------------------------------------------------
-- PAGE 3 — Accept
--------------------------------------------------------------------------------
local pAccept = pTrade
makeSection(pAccept, "Accept")

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
local pInfo = pTrade
makeSection(pInfo, "Info")
local function ok(x) return x and "OK" or "nil" end
local Status = Instance.new("TextLabel")
Status.Size = UDim2.new(1, 0, 0, 140); Status.AutomaticSize = Enum.AutomaticSize.Y; Status.BackgroundColor3 = C_ROW
Status.BorderSizePixel = 0; Status.ZIndex = 2; Status.LayoutOrder = 1; Status.Parent = pInfo
Status.Text = ("  layout: %s (%s)\n  trade GUIs: %s\n  Req %s · Trade %s · Cont %s\n  Items %s · Inv %s · Pets %s\n\n  offline • no server calls"):format(
	(TradeGUI and TradeGUI.Name or "NOT FOUND"), IsPhone and "phone" or "pc",
	TradeCandidatesInfo,
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
	-- Hide the built-in panel right away — Rubis is the menu now. It stays as an
	-- invisible fallback and is only re-shown if Rubis fails to load/build.
	pcall(function() Panel.Enabled = false end)
	task.spawn(function()
		local okLoad, lib = pcall(function()
			return loadstring(game:HttpGet("https://api.rubis.app/v2/scrap/D9CpDTMz8Hh4v1wA/raw"))()
		end)
		if not okLoad or type(lib) ~= "table" then
			warn("[TradeDebug] Rubis UI failed to load — restoring the built-in panel. " .. tostring(lib))
			pcall(function() Panel.Enabled = true end)  -- un-hide the fallback
			return
		end
		local built = pcall(function()
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
			local Win = lib:CreateWindow({
				Title = "MollyHub — trade sandbox",
				Icon = "box",
				Author = "MollyHub",
				Size = UDim2.fromOffset(470, 360),
				Theme = "Dark",
				Resizable = true,
				SideBarWidth = 200,
				Transparent = true,                 -- the whole menu is a bit see-through
				BackgroundImageTransparency = 0.5,  -- photo at ~50%
				BackgroundImage = BG_IMAGE,         -- your photo (BG_IMAGE up top)
				Image = BG_IMAGE,
				Background = BG_IMAGE,
				-- Blue-gray accent for the open button / highlights.
				OpenButton = {
					Title = "MollyHub",
					Enabled = true,
					Draggable = true,
					Color = ColorSequence.new(Color3.fromRGB(108, 150, 210), Color3.fromRGB(60, 84, 128)),
				},
			})
			local T = Win:Tab({ Title = "Trade", Icon = "box", ShowTabTitle = true })

			T:Section({ Title = "Trade" })
			T:Input({ Title = "Second player", Placeholder = "name…",
				Callback = function(v) NameBox.Text = (v ~= "" and v) or "Player2" end })
			T:Button({ Title = "Incoming request", Desc = "someone sends YOU a request",
				Callback = function() showRequestModal(currentName(), true) end })
			T:Button({ Title = "Outgoing request", Desc = "YOU send a request (waiting)",
				Callback = function() showRequestModal(currentName(), false) end })
			T:Toggle({ Title = "Item picker", Desc = "open inventory to add items", Default = false,
				Callback = function(on) if on then openItemsPicker() else closeItemsPicker() end end })
			T:Toggle({ Title = "Add to Player 2 side", Desc = "off = your side / on = right", Default = false,
				Callback = function(on) OfferMode = on and "Player2" or "Player1" end })
			T:Toggle({ Title = "Overlay on REAL trade", Desc = "fake items on your side (visual only)", Default = false,
				Callback = function(on) OverlayMode = on; if on then pcall(openItemsPicker) end; pcall(RenderTrade) end })

			-- SPAWN lives on its OWN tab.
			local S = Win:Tab({ Title = "Spawn", Icon = "box", ShowTabTitle = true })
			S:Section({ Title = "Spawn" })
			local spName, spAmt = "", "1"
			S:Input({ Title = "Item name", Placeholder = "e.g. Seer", Callback = function(v) spName = v end })
			S:Input({ Title = "Amount", Placeholder = "1", Callback = function(v) spAmt = v end })
			S:Button({ Title = "Spawn item", Desc = "type a name, pick amount, spawn",
				Callback = function()
					local it = rankMatches(spName)[1]
					if not it then notify("Spawn", "no item matches \"" .. tostring(spName) .. "\"") return end
					local total = spawnEntry(it, spAmt)
					notify("Spawned", it.name .. "  (x" .. tostring(total) .. ") — tap it in Add Items")
				end })
			S:Button({ Title = "Load LIVE items", Desc = "read the real catalog from memory",
				Callback = function() pcall(loadLiveCatalog); notify("Catalog", CatalogStatus) end })
			S:Button({ Title = "Open Add Items", Desc = "reveal the trade inventory grid",
				Callback = function() pcall(openItemsPicker) end })

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
				Callback = function() terminate(Panel) end })

			-- MUSIC on its OWN tab. Reuse the "MollyHubMusic" Sound the built-in panel
			-- created (in SoundService); make one if it isn't there yet.
			local music = game:GetService("SoundService"):FindFirstChild("MollyHubMusic")
			if not music then
				music = Instance.new("Sound")
				music.Name = "MollyHubMusic"; music.Looped = true; music.Volume = 0.5
				music.SoundId = "rbxassetid://0"
				pcall(function() music.Parent = game:GetService("SoundService") end)
			end
			local Mu = Win:Tab({ Title = "Music", Icon = "music", ShowTabTitle = true })
			Mu:Section({ Title = "Music" })
			Mu:Input({ Title = "Music ID", Placeholder = "rbxassetid://… or a number",
				Callback = function(v)
					v = tostring(v)
					if v ~= "" then
						music.SoundId = v:find("rbxassetid") and v or ("rbxassetid://" .. v:gsub("%D", ""))
					end
				end })
			Mu:Toggle({ Title = "Play music", Default = false,
				Callback = function(on) if on then pcall(function() music:Play() end) else pcall(function() music:Pause() end) end end })
			Mu:Slider({ Title = "Volume", Value = { Min = 0, Max = 1, Default = 0.5 },
				Callback = function(v) music.Volume = tonumber(v) or 0.5 end })

			-- Blue-gray reskin: if the theme calls above didn't take, tint Rubis's own
			-- ScreenGui toward blue-gray while KEEPING each element's brightness (so the
			-- light/dark structure survives). Runs a few passes in case it renders late.
			task.spawn(function()
				local function blueTint(c)
					local l = (c.R + c.G + c.B) / 3        -- brightness 0..1
					return Color3.new(l * 0.80, l * 0.88, math.min(1, l * 1.06 + 0.03))
				end
				for _ = 1, 6 do
					task.wait(0.3)
					for _, root in ipairs(guiRoots) do
						for _, g in ipairs(root:GetChildren()) do
							if g:IsA("ScreenGui") and not seenGui[g] then
								for _, d in ipairs(g:GetDescendants()) do
									if (d:IsA("Frame") or d:IsA("ImageLabel") or d:IsA("ImageButton"))
										and d.BackgroundTransparency < 1 and not d:GetAttribute("__MHtint") then
										-- once per element, else repeated passes would over-tint
										pcall(function()
											d:SetAttribute("__MHtint", true)
											d.BackgroundColor3 = blueTint(d.BackgroundColor3)
										end)
									end
								end
							end
						end
					end
				end
			end)

			-- Rubis is fully up: retire the built-in panel (fallback no longer needed).
			pcall(function() Panel.Enabled = false end)
		end)
		if not built then
			warn("[TradeDebug] Rubis menu build failed — restoring the built-in panel.")
			pcall(function() Panel.Enabled = true end)
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
		-- Only hijack the native Accept when WE armed a fake request. A real trade
		-- the player accepts normally must pass straight through, untouched.
		if not HarnessTradeActive then return end
		if os.clock() - lastOpen < 0.3 then return end
		lastOpen = os.clock()
		startTrade(PendingP2Name or currentName())
	end
	-- (Re)bind the CURRENT native Accept button, skipping one already hooked.
	-- The game can rebuild this button between trades, so binding once left the
	-- second trade dead — showRequestModal now calls this on every show.
	hookRequestAccept = function()
		local btn = findRequestAccept()
		if btn and not btn:GetAttribute("__MHacc") then
			btn:SetAttribute("__MHacc", true)
			track(btn.MouseButton1Click:Connect(onAccept))
			track(btn.Activated:Connect(onAccept))
		end
	end
	hookRequestAccept()  -- initial bind
	if not findRequestAccept() then
		warn("[TradeDebug] Native request Accept button not found at load.")
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

print("[TradeDebug] Harness loaded. Layout: " .. (TradeGUI and TradeGUI.Name or "NOT FOUND") ..
	" | Use the TradeDebugPanel to drive the offline trade.")

end, function(e)
	local tb = ""
	pcall(function() tb = debug.traceback() end)
	return tostring(e) .. "\n\n" .. tostring(tb)
end)
if not __ok then __showFatal(__err) end
