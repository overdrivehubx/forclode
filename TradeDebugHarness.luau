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
local RARITY_GREY = Color3.fromRGB(106, 106, 106)  -- Common plate (0.415686)

local RarityValue = {
	Classic=1, Common=2, Uncommon=3, Rare=4, Legendary=5,
	Godly=6, Divine=6.6, Ancient=6.5, Victim=7, Unique=11,
	Christmas=1.6, Halloween=1.5,
}

local ItemDB = {
-- === Real MM2 catalog embedded from Sync.Item (445 items) ===
	["2015"]={ItemName="2015", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=199026945", ItemType="Knife", Rarity="Common"},
	["8-BitItemPack"]={ItemName="8-BIT Item Pack", Image="http://www.roblox.com/asset/?id=6070700573", ItemType="Misc", Rarity="Godly"},
	["8-Bititempack"]={ItemName="8-Bit Item pack", Image="http://www.roblox.com/asset/?id=5807076275", ItemType="Knife", Rarity="Godly"},
	["8bit"]={ItemName="8bit", Image="http://www.roblox.com/asset/?id=198453482", ItemType="Knife", Rarity="Common"},
	["Abstract"]={ItemName="Abstract", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365569428", ItemType="Knife", Rarity="Rare"},
	["Ace"]={ItemName="Ace", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238546577", ItemType="Gun", Rarity="Rare"},
	["Acid"]={ItemName="Acid", Image="http://www.roblox.com/asset/?id=10042432713", ItemType="Knife", Rarity="Uncommon"},
	["Adurite"]={ItemName="Adurite", Image="http://www.roblox.com/asset/?id=192492943", ItemType="Knife", Rarity="Uncommon"},
	["AduriteGun"]={ItemName="Adurite", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=175668921", ItemType="Gun", Rarity="Uncommon"},
	["Aid"]={ItemName="Juice", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203807397", ItemType="Gun", Rarity="Common"},
	["Alex"]={ItemName="Alex", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=546159020", ItemType="Knife", Rarity="Common"},
	["AmericaGun"]={ItemName="America", Image="http://www.roblox.com/asset/?id=164676043", ItemType="Gun", Rarity="Classic"},
	["AmericaSword"]={ItemName="Old Glory", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=446047742", ItemType="Knife", Rarity="Godly"},
	["AmericanItemPack"]={ItemName="American Item Pack", Image="http://www.roblox.com/asset/?id=6070700917", ItemType="Misc", Rarity="Godly"},
	["Americanitempack"]={ItemName="American Item pack", Image="http://www.roblox.com/asset/?id=5807076558", ItemType="Knife", Rarity="Godly"},
	["Amerilaser"]={ItemName="Amerilaser", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=446050753", ItemType="Gun", Rarity="Godly"},
	["Aqua"]={ItemName="Aqua", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315501208", ItemType="Knife", Rarity="Common"},
	["Asteroid"]={ItemName="Asteroid", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=476599365", ItemType="Gun", Rarity="Common"},
	["Astral Boneblade"]={ItemName="Astral Boneblade", Image="https://www.roblox.com/asset/?id=8855705248", ItemType="Knife", Rarity="Godly"},
	["Bacon"]={ItemName="Bacon", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238546467", ItemType="Gun", Rarity="Rare"},
	["Bats"]={ItemName="Bats", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873625", ItemType="Knife", Rarity="Rare"},
	["BattleaxeII"]={ItemName="Battleaxe II", Image="http://www.roblox.com/asset/?id=5976301881", ItemType="Knife", Rarity="Godly"},
	["Batwing"]={ItemName="Batwing", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=375690925", ItemType="Knife", Rarity="Ancient"},
	["BdaysScythe"]={ItemName="Bday's Scythe", Image="http://www.roblox.com/asset/?id=9970402829", ItemType="Knife", Rarity="Ancient"},
	["BigKill"]={ItemName="Big Kill", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=162669041", ItemType="Gun", Rarity="Common"},
	["Bioblade"]={ItemName="Bioblade", Image="http://www.roblox.com/asset/?id=4751572506", ItemType="Knife", Rarity="Godly"},
	["Biogun"]={ItemName="Biogun", Image="http://www.roblox.com/asset/?id=5805960976", ItemType="Gun", Rarity="Uncommon"},
	["Bit"]={ItemName="Bit", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238549030", ItemType="Gun", Rarity="Common"},
	["Blaster"]={ItemName="Blaster", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=386277381", ItemType="Gun", Rarity="Godly"},
	["Bleached"]={ItemName="Bleached", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315500879", ItemType="Knife", Rarity="Common"},
	["Bleed"]={ItemName="Rupture", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315100702", ItemType="Gun", Rarity="Legendary"},
	["Blood Hallowgun"]={ItemName="Blood Hallowgun", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7333263081", ItemType="Gun", Rarity="Godly"},
	["Blood Hallowscythe"]={ItemName="Blood HallowScythe", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7356519141", ItemType="Knife", Rarity="Ancient"},
	["Blood Vampire's Edge"]={ItemName="Blood Vampire's Edge", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6917339862", ItemType="Knife", Rarity="Godly"},
	["BloodKnife"]={ItemName="Blood", Image="http://www.roblox.com/asset/?id=144307188", ItemType="Knife", Rarity="Classic"},
	["Blossom"]={ItemName="Blossom", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=363150561", ItemType="Knife", Rarity="Common"},
	["Bloxy Cola"]={ItemName="Bloxy Cola", Image="http://www.roblox.com/asset/?id=10042429263", ItemType="Knife", Rarity="Uncommon"},
	["Blue Flower"]={ItemName="Blue Flower", Image="http://www.roblox.com/asset/?id=10042422410", ItemType="Knife", Rarity="Common"},
	["Blue Iceblaster"]={ItemName="Blue Iceblaster", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10530848450", ItemType="Gun", Rarity="Ancient"},
	["Blue Icebreaker"]={ItemName="Blue Icebreaker", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10280401405", ItemType="Knife", Rarity="Ancient"},
	["BlueBatwing"]={ItemName="Batwing", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10832639115", ItemType="Knife", Rarity="Ancient"},
	["BlueElite"]={ItemName="Blue Elite", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=1269374321", ItemType="Knife", Rarity="Legendary"},
	["BlueLogchopper"]={ItemName="BlueLogchopper", Image="http://www.roblox.com/asset/?id=4849908327", ItemType="Knife", Rarity="Victim"},
	["BlueMinty"]={ItemName="Blue Minty", Image="http://www.roblox.com/asset/?id=6158546958", ItemType="Gun", Rarity="Victim"},
	["BlueScratch"]={ItemName="Scratch", Image="http://www.roblox.com/asset/?id=10909353159", ItemType="Knife", Rarity="Legendary"},
	["BlueSeer"]={ItemName="Blue Seer", Image="http://www.roblox.com/asset/?id=5809284189", ItemType="Knife", Rarity="Godly"},
	["BlueSwirlyAxe"]={ItemName="Blue Swirly", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9552048857", ItemType="Knife", Rarity="Godly"},
	["BlueSwirlyGun"]={ItemName="Blue Swirly", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9552060741", ItemType="Gun", Rarity="Godly"},
	["BlueVampiresEdge"]={ItemName="Blue Vampire's Edge", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10454290121", ItemType="Knife", Rarity="Godly"},
	["Bluesteel"]={ItemName="Bluesteel", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=159947939", ItemType="Knife", Rarity="Uncommon"},
	["BluesteelGun"]={ItemName="Bluesteel", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=162668203", ItemType="Gun", Rarity="Uncommon"},
	["Bones"]={ItemName="Bones", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873816", ItemType="Knife", Rarity="Common"},
	["Borders"]={ItemName="Borders", Image="http://www.roblox.com/asset/?id=198453499", ItemType="Knife", Rarity="Common"},
	["Brains"]={ItemName="Brains", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873956", ItemType="Knife", Rarity="Common"},
	["Brush"]={ItemName="Brush", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365568602", ItemType="Knife", Rarity="Uncommon"},
	["Bunny"]={ItemName="Bunny", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=387874365", ItemType="Knife", Rarity="Common"},
	["Camo"]={ItemName="Camo", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=160024789", ItemType="Gun", Rarity="Uncommon"},
	["CamoKnife"]={ItemName="Camo", Image="http://www.roblox.com/asset/?id=5805749841", ItemType="Knife", Rarity="Uncommon"},
	["Candies"]={ItemName="Candies", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531203559", ItemType="Misc", Rarity="Halloween"},
	["Candleflame"]={ItemName="Candleflame", Image="http://www.roblox.com/asset/?id=7864019525", ItemType="Knife", Rarity="Godly"},
	["Candy"]={ItemName="Candy", Image="http://www.roblox.com/asset/?id=10006845422", ItemType="Knife", Rarity="Godly"},
	["CandyCorn"]={ItemName="Candy Corn", Image="http://www.roblox.com/asset/?id=10909341342", ItemType="Knife", Rarity="Common"},
	["Cane"]={ItemName="Cane", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=331140746", ItemType="Knife", Rarity="Rare"},
	["CaneGun"]={ItemName="Cane", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332497187", ItemType="Gun", Rarity="Rare"},
	["Cardboard"]={ItemName="Cardboard", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235366729", ItemType="Knife", Rarity="Common"},
	["Carrot"]={ItemName="Carrot", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=387874071", ItemType="Knife", Rarity="Common"},
	["Caution"]={ItemName="Caution", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238546422", ItemType="Gun", Rarity="Uncommon"},
	["Checker"]={ItemName="Checker", Image="http://www.roblox.com/asset/?id=198461230", ItemType="Knife", Rarity="Uncommon"},
	["Cheddar"]={ItemName="Cheddar", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203808317", ItemType="Gun", Rarity="Uncommon"},
	["Cheesy"]={ItemName="Cheesy", Image="http://www.roblox.com/asset/?id=198455898", ItemType="Knife", Rarity="Uncommon"},
	["Cherry"]={ItemName="Cherry", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235366575", ItemType="Knife", Rarity="Common"},
	["Chill"]={ItemName="Chill", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332022166", ItemType="Knife", Rarity="Godly"},
	["Chips"]={ItemName="Blue", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473626317", ItemType="Knife", Rarity="Uncommon"},
	["Choco"]={ItemName="Choco", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=387874991", ItemType="Knife", Rarity="Common"},
	["Chroma Candleflame"]={ItemName="Candleflame", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7806149582", ItemType="Knife", Rarity="Godly", Chroma=true},
	["Chroma Corrupt"]={ItemName="Corrupt", Image="http://www.roblox.com/asset/?id=10029093063", ItemType="Knife", Rarity="Victim", Chroma=true},
	["Chroma Darkbringer"]={ItemName="Darkbringer", Image="http://www.roblox.com/asset/?id=6997765019", ItemType="Gun", Rarity="Godly", Chroma=true},
	["Chroma Deathshard"]={ItemName="Deathshard", Image="http://www.roblox.com/asset/?id=5808892571", ItemType="Knife", Rarity="Godly", Chroma=true},
	["Chroma Fang"]={ItemName="Fang", Image="http://www.roblox.com/asset/?id=6033770460", ItemType="Knife", Rarity="Godly", Chroma=true},
	["Chroma Gemstone"]={ItemName="Gemstone", Image="http://www.roblox.com/asset/?id=6691390888", ItemType="Knife", Rarity="Godly", Chroma=true},
	["Chroma Harvester"]={ItemName="Harvester", Image="https://www.roblox.com/asset/?id=8495035484", ItemType="Gun", Rarity="Ancient", Chroma=true},
	["Chroma Heat"]={ItemName="Heat", Image="http://www.roblox.com/asset/?id=5808893795", ItemType="Knife", Rarity="Godly", Chroma=true},
	["Chroma Iceblaster"]={ItemName="Iceblaster", Image="http://www.roblox.com/asset/?id=8495021873", ItemType="Gun", Rarity="Ancient", Chroma=true},
	["Chroma Icebreaker"]={ItemName="Icebreaker", Image="http://www.roblox.com/asset/?id=8495021099", ItemType="Knife", Rarity="Ancient", Chroma=true},
	["Chroma Laser"]={ItemName="Laser", Image="http://www.roblox.com/asset/?id=6033886856", ItemType="Gun", Rarity="Godly", Chroma=true},
	["Chroma Lightbringer"]={ItemName="Lightbringer", Image="http://www.roblox.com/asset/?id=6691883035", ItemType="Gun", Rarity="Godly", Chroma=true},
	["Chroma Luger"]={ItemName="Luger", Image="http://www.roblox.com/asset/?id=5808896276", ItemType="Gun", Rarity="Godly", Chroma=true},
	["Chroma Pixel Gun"]={ItemName="Pixel", Image="http://www.roblox.com/asset/?id=10324764035", ItemType="Gun", Rarity="Godly", Chroma=true},
	["Chroma Plasmabeam"]={ItemName="Plasmabeam", Image="http://www.roblox.com/asset/?id=10102253545", ItemType="Gun", Rarity="Godly", Chroma=true},
	["Chroma Plasmablade"]={ItemName="Plasmablade", Image="http://www.roblox.com/asset/?id=10102250086", ItemType="Knife", Rarity="Godly", Chroma=true},
	["Chroma Reaver 3"]={ItemName="Reaver", Image="https://www.roblox.com/asset/?id=8363320666", ItemType="Knife", Rarity="Godly", Chroma=true},
	["Chroma Saw"]={ItemName="Saw", Image="http://www.roblox.com/asset/?id=5808893352", ItemType="Knife", Rarity="Godly", Chroma=true},
	["Chroma Seer"]={ItemName="Seer", Image="http://www.roblox.com/asset/?id=5808893009", ItemType="Knife", Rarity="Godly", Chroma=true},
	["Chroma Shark"]={ItemName="Shark", Image="http://www.roblox.com/asset/?id=5808894870", ItemType="Gun", Rarity="Godly", Chroma=true},
	["Chroma Slasher"]={ItemName="Slasher", Image="http://www.roblox.com/asset/?id=5808897510", ItemType="Knife", Rarity="Godly", Chroma=true},
	["Chroma Tides"]={ItemName="Tides", Image="http://www.roblox.com/asset/?id=5808894285", ItemType="Knife", Rarity="Godly", Chroma=true},
	["Chroma Vampire's Edge"]={ItemName="Vampire's Edge", Image="https://www.roblox.com/asset/?id=8495033547", ItemType="Knife", Rarity="Godly", Chroma=true},
	["ChromaEternal"]={ItemName="Eternal", Image="http://www.roblox.com/asset/?id=6056779978", ItemType="Knife", Rarity="Godly", Chroma=true},
	["ChromaPrismatic"]={ItemName="Prismatic", Image="http://www.roblox.com/asset/?id=9754262472", ItemType="Knife", Rarity="Godly", Chroma=true},
	["ChromaScythe"]={ItemName="Chroma Scythe", Image="http://www.roblox.com/asset/?id=6056780228", ItemType="Knife", Rarity="Godly", Chroma=true},
	["ChromaSwirlyGun"]={ItemName="Swirly Gun", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8311453396", ItemType="Gun", Rarity="Godly", Chroma=true},
	["Chromatic Tides"]={ItemName="Chromatic Tides", Image="http://www.roblox.com/asset/?id=9981544572", ItemType="Knife", Rarity="Godly"},
	["Circuit"]={ItemName="Circuit", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235366945", ItemType="Knife", Rarity="Uncommon"},
	["Clan"]={ItemName="Clan", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235366460", ItemType="Knife", Rarity="Common"},
	["ClassicLaser"]={ItemName="Laser", Image="http://www.roblox.com/asset/?id=54798135", ItemType="Gun", Rarity="Classic"},
	["Clockwork"]={ItemName="Clockwork", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=360609441", ItemType="Knife", Rarity="Godly"},
	["ClockworkItemPack"]={ItemName="Clockwork Item Pack", Image="http://www.roblox.com/asset/?id=6070701470", ItemType="Misc", Rarity="Godly"},
	["Clockworkitempack"]={ItemName="Clockwork Item pack", Image="http://www.roblox.com/asset/?id=5807073519", ItemType="Knife", Rarity="Godly"},
	["Clown"]={ItemName="Clown", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315501118", ItemType="Knife", Rarity="Common"},
	["ClownGun"]={ItemName="Clown", Image="http://www.roblox.com/asset/?id=5805970971", ItemType="Gun", Rarity="Common"},
	["Cola"]={ItemName="Soda", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238546400", ItemType="Gun", Rarity="Uncommon"},
	["Cold"]={ItemName="Cold", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=161309889", ItemType="Gun", Rarity="Common"},
	["Combat"]={ItemName="Combat", Image="http://www.roblox.com/asset/?id=5805768116", ItemType="Knife", Rarity="Common"},
	["Cookieblade"]={ItemName="Cookieblade", Image="http://www.roblox.com/asset/?id=6132429246", ItemType="Knife", Rarity="Godly"},
	["Copper"]={ItemName="Copper", Image="http://www.roblox.com/asset/?id=5805764400", ItemType="Knife", Rarity="Common"},
	["Corl"]={ItemName="Corl", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=546161858", ItemType="Knife", Rarity="Common"},
	["CottonCandy"]={ItemName="Cotton Candy", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=435933179", ItemType="Knife", Rarity="Legendary"},
	["CyanHarvester"]={ItemName="Cyan Harvester", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10832996299", ItemType="Gun", Rarity="Godly"},
	["Cyber"]={ItemName="Cyber", Image="http://www.roblox.com/asset/?id=10042430931", ItemType="Knife", Rarity="Uncommon"},
	["Damp"]={ItemName="Damp", Image="http://www.roblox.com/asset/?id=198461253", ItemType="Knife", Rarity="Rare"},
	["Dark Candy"]={ItemName="Dark Candy", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10341270178", ItemType="Knife", Rarity="Godly"},
	["Dark Clockwork"]={ItemName="Dark Clockwork", Image="http://www.roblox.com/asset/?id=9981541954", ItemType="Knife", Rarity="Godly"},
	["Dark Luger"]={ItemName="Dark Luger", Image="http://www.roblox.com/asset/?id=9981540944", ItemType="Gun", Rarity="Godly"},
	["Dark Sugar"]={ItemName="Dark Sugar", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10341298265", ItemType="Gun", Rarity="Godly"},
	["Dark Swirly Blade"]={ItemName="Dark Swirly Blade", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9767982029", ItemType="Knife", Rarity="Godly"},
	["Dark Swirly Gun"]={ItemName="Dark Swirly Gun", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=9767955945", ItemType="Gun", Rarity="Godly"},
	["Darkbringer"]={ItemName="Darkbringer", Image="http://www.roblox.com/asset/?id=5805978387", ItemType="Gun", Rarity="Godly"},
	["Dartbringer"]={ItemName="Dartbringer", Image="http://www.roblox.com/asset/?id=8787496597", ItemType="Gun", Rarity="Victim"},
	["Death Luger"]={ItemName="Death Luger", Image="http://www.roblox.com/asset/?id=9981367437", ItemType="Gun", Rarity="Godly"},
	["Death's Blade"]={ItemName="Death's Blade", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10306335514", ItemType="Knife", Rarity="Ancient"},
	["Deathshard"]={ItemName="Deathshard", Image="http://www.roblox.com/asset/?id=6017476455", ItemType="Knife", Rarity="Godly"},
	["Deathstone"]={ItemName="Deathstone", Image="http://www.roblox.com/asset/?id=9981368109", ItemType="Knife", Rarity="Godly"},
	["DeepSea"]={ItemName="Deep Sea", Image="http://www.roblox.com/asset/?id=5805947767", ItemType="Knife", Rarity="Rare"},
	["DefaultGun"]={ItemName="Default Gun", Image="http://www.roblox.com/asset/?id=197518111", ItemType="Gun", Rarity="Common"},
	["DefaultKnife"]={ItemName="Default Knife", Image="http://www.roblox.com/asset/?id=584555920", ItemType="Knife", Rarity="Common"},
	["Denis"]={ItemName="Denis", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=546161062", ItemType="Knife", Rarity="Common"},
	["Destiny"]={ItemName="Destiny", Image="http://www.roblox.com/asset/?id=9987790284", ItemType="Knife", Rarity="Godly"},
	["Dew"]={ItemName="Black", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473626646", ItemType="Knife", Rarity="Rare"},
	["Doge"]={ItemName="Doge", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235371276", ItemType="Knife", Rarity="Uncommon"},
	["Donut"]={ItemName="Donut", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235366815", ItemType="Knife", Rarity="Uncommon"},
	["Doritos"]={ItemName="Purple", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473626740", ItemType="Knife", Rarity="Rare"},
	["Eco"]={ItemName="Eco", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365567889", ItemType="Knife", Rarity="Common"},
	["Ecto"]={ItemName="Ecto", Image="http://www.roblox.com/asset/?id=10909334330", ItemType="Knife", Rarity="Common"},
	["Eggblade"]={ItemName="Eggblade", Image="http://www.roblox.com/asset/?id=9782610073", ItemType="Knife", Rarity="Godly"},
	["Eggs"]={ItemName="Egg", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=387875405", ItemType="Knife", Rarity="Common"},
	["ElderwoodRevolver"]={ItemName="Elderwood Revolver", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=4468571736", ItemType="Gun", Rarity="Godly"},
	["ElderwoodScythe"]={ItemName="Elderwood Scythe", Image="http://www.roblox.com/asset/?id=5976324735", ItemType="Knife", Rarity="Ancient"},
	["Elf"]={ItemName="Elf", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=331746317", ItemType="Knife", Rarity="Common"},
	["ElfGun"]={ItemName="Elf", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332767999", ItemType="Gun", Rarity="Common"},
	["Elite"]={ItemName="Elite", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=241095344", ItemType="Knife", Rarity="Legendary"},
	["EliteGreen"]={ItemName="Green Elite", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332754554", ItemType="Knife", Rarity="Legendary"},
	["Emerald"]={ItemName="Emerald", Image="http://www.roblox.com/asset/?id=198461276", ItemType="Knife", Rarity="Legendary"},
	["Engraved"]={ItemName="Engraved", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203807690", ItemType="Gun", Rarity="Common"},
	["Eternal"]={ItemName="Eternal", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=538706317", ItemType="Knife", Rarity="Godly"},
	["EternalII"]={ItemName="EternalII", Image="http://www.roblox.com/asset/?id=6019628835", ItemType="Knife", Rarity="Godly"},
	["EternalIII"]={ItemName="EternalIII", Image="http://www.roblox.com/asset/?id=6019629260", ItemType="Knife", Rarity="Godly"},
	["EternalIV"]={ItemName="EternalIV", Image="http://www.roblox.com/asset/?id=6019629723", ItemType="Knife", Rarity="Godly"},
	["Euro"]={ItemName="Euro", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=305504173", ItemType="Knife", Rarity="Common"},
	["Fade"]={ItemName="Fade", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315501640", ItemType="Knife", Rarity="Legendary"},
	["Fallout"]={ItemName="Fallout", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=175668592", ItemType="Gun", Rarity="Common"},
	["Fang"]={ItemName="Fang", Image="http://www.roblox.com/asset/?id=6017472147", ItemType="Knife", Rarity="Godly"},
	["Fanta"]={ItemName="Orange", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473626025", ItemType="Knife", Rarity="Common"},
	["Fidget's Scythe"]={ItemName="Batwing", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10531500968", ItemType="Knife", Rarity="Ancient"},
	["Flames"]={ItemName="Flames", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=585873746", ItemType="Knife", Rarity="Godly"},
	["Frostbite"]={ItemName="Frostbite", Image="http://www.roblox.com/asset/?id=6132363139", ItemType="Knife", Rarity="Godly"},
	["Fusion"]={ItemName="Fusion", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365569686", ItemType="Knife", Rarity="Legendary"},
	["Future"]={ItemName="Future", Image="http://www.roblox.com/asset/?id=197639041", ItemType="Knife", Rarity="Uncommon"},
	["FuturisticItemPack"]={ItemName="Futuristic Item Pack", Image="http://www.roblox.com/asset/?id=6070701952", ItemType="Misc", Rarity="Godly"},
	["Galactic"]={ItemName="Galactic", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=173913533", ItemType="Gun", Rarity="Rare"},
	["Galaxy"]={ItemName="Galaxy", Image="http://www.roblox.com/asset/?id=192480941", ItemType="Knife", Rarity="Rare"},
	["Galaxy Beam"]={ItemName="Cosmos", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10367104489", ItemType="Gun", Rarity="Godly"},
	["Galaxy Blade"]={ItemName="Universe", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10367060757", ItemType="Knife", Rarity="Godly"},
	["Galaxy Darkbringer"]={ItemName="Darkbringer", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10367178553", ItemType="Gun", Rarity="Godly"},
	["Galaxy Deathshard"]={ItemName="Deathshard", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10367349773", ItemType="Knife", Rarity="Godly"},
	["Galaxy Gemstone"]={ItemName="Gemstone", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10367334828", ItemType="Knife", Rarity="Godly"},
	["Galaxy Hallow's Edge"]={ItemName="Hallow's Edge", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10367370257", ItemType="Knife", Rarity="Godly"},
	["Galaxy Heat"]={ItemName="Heat", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10367038434", ItemType="Knife", Rarity="Godly"},
	["Galaxy Laser"]={ItemName="Laser", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10367229709", ItemType="Gun", Rarity="Godly"},
	["Galaxy Lightbringer"]={ItemName="Lightbringer", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10367171658", ItemType="Gun", Rarity="Godly"},
	["Galaxy Luger"]={ItemName="Luger", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10367244640", ItemType="Gun", Rarity="Godly"},
	["Galaxy Saw"]={ItemName="Saw", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10367287876", ItemType="Knife", Rarity="Godly"},
	["Galaxy Shark"]={ItemName="Shark", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10367273241", ItemType="Gun", Rarity="Godly"},
	["Galaxy Slasher"]={ItemName="Slasher", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10367311943", ItemType="Knife", Rarity="Godly"},
	["Gemstone"]={ItemName="Gemstone", Image="http://www.roblox.com/asset/?id=3183657748", ItemType="Knife", Rarity="Godly"},
	["GhostKnife"]={ItemName="Ghost", Image="http://www.roblox.com/asset/?id=144268841", ItemType="Knife", Rarity="Classic"},
	["Ghostblade"]={ItemName="Ghostblade", Image="http://www.roblox.com/asset/?id=5838251023", ItemType="Knife", Rarity="Godly"},
	["Ghosty"]={ItemName="Ghosty", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873080", ItemType="Knife", Rarity="Common"},
	["Gift"]={ItemName="Gifts 2015", Image="https://www.roblox.com/asset/?id=330192109", ItemType="Misc", Rarity="Christmas"},
	["GiftBag"]={ItemName="Gift Bag", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121864813", ItemType="Gun", Rarity="Common"},
	["Gifted"]={ItemName="Gifted", Image="http://www.roblox.com/asset/?id=197627734", ItemType="Knife", Rarity="Uncommon"},
	["Ginger"]={ItemName="Ginger", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=331744703", ItemType="Knife", Rarity="Rare"},
	["GingerGun"]={ItemName="Ginger", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332497038", ItemType="Gun", Rarity="Rare"},
	["Gingerbread"]={ItemName="Gingerbread", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121860619", ItemType="Gun", Rarity="Uncommon"},
	["Glitched Blaster"]={ItemName="Glitched Blaster", Image="https://www.roblox.com/asset/?id=8692361926", ItemType="Gun", Rarity="Godly"},
	["Glitched Katana"]={ItemName="Glitched Katana", Image="https://www.roblox.com/asset/?id=8692362860", ItemType="Knife", Rarity="Godly"},
	["Glittered Luger"]={ItemName="Glittered Luger", Image="https://www.roblox.com/asset/?id=9833300267", ItemType="Gun", Rarity="Godly"},
	["Gold Batwing"]={ItemName="Gold Batwing", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10531500968", ItemType="Knife", Rarity="Ancient"},
	["GoldElderwoodRevolver"]={ItemName="Gold Elderwood Revolver", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=4468584345", ItemType="Gun", Rarity="Victim"},
	["GoldIceblaster"]={ItemName="Iceblaster", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10457086628", ItemType="Gun", Rarity="Victim"},
	["GoldIcebreaker"]={ItemName="Icebreaker", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10457081269", ItemType="Knife", Rarity="Victim"},
	["GoldenGun"]={ItemName="Golden", Image="http://www.roblox.com/asset/?id=147835357", ItemType="Gun", Rarity="Classic"},
	["Goo"]={ItemName="Goo", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=237336076", ItemType="Knife", Rarity="Common"},
	["Graffiti"]={ItemName="Graffiti", Image="http://www.roblox.com/asset/?id=5805956212", ItemType="Knife", Rarity="Uncommon"},
	["Grass"]={ItemName="Grass", Image="http://www.roblox.com/asset/?id=10042426156", ItemType="Knife", Rarity="Common"},
	["GreenBlaster"]={ItemName="Blaster", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10784346994", ItemType="Gun", Rarity="Godly"},
	["GreenElite"]={ItemName="Green Elite", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332754554", ItemType="Knife", Rarity="Legendary"},
	["GreenLuger"]={ItemName="Green Luger", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332044679", ItemType="Gun", Rarity="Godly"},
	["GreenMarble"]={ItemName="Green Marble", Image="http://www.roblox.com/asset/?id=10909351660", ItemType="Knife", Rarity="Rare"},
	["GreenVirtual"]={ItemName="Virtual", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10784347612", ItemType="Knife", Rarity="Godly"},
	["Grind"]={ItemName="Grind", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=305503942", ItemType="Knife", Rarity="Common"},
	["Gun1"]={ItemName="Cowboy", Image="http://www.roblox.com/asset/?id=144290769", ItemType="Gun", Rarity="Classic"},
	["HL2"]={ItemName="HL2", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238546100", ItemType="Gun", Rarity="Common"},
	["Hacker"]={ItemName="Hacker", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203819271", ItemType="Gun", Rarity="Rare"},
	["Hallow"]={ItemName="Hallow's Edge", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531878205", ItemType="Knife", Rarity="Godly"},
	["HallowsBlade"]={ItemName="Hallow's Blade", Image="http://www.roblox.com/asset/?id=10909488343", ItemType="Knife", Rarity="Godly"},
	["Handsaw"]={ItemName="Handsaw", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332042435", ItemType="Knife", Rarity="Godly"},
	["Hardened"]={ItemName="Hardened", Image="http://www.roblox.com/asset/?id=5805761191", ItemType="Knife", Rarity="Common"},
	["Harvester"]={ItemName="Harvester", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=7800847534", ItemType="Gun", Rarity="Ancient"},
	["Hazmat"]={ItemName="Hazmat", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315501297", ItemType="Knife", Rarity="Uncommon"},
	["Heartblade"]={ItemName="Heartblade", Image="http://www.roblox.com/asset/?id=6413214382", ItemType="Knife", Rarity="Godly"},
	["Hearts"]={ItemName="Hearts", Image="https://www.roblox.com/asset/?id=363362737", ItemType="Knife", Rarity="Common"},
	["Heat"]={ItemName="Heat", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6017472462", ItemType="Knife", Rarity="Godly"},
	["HighTech"]={ItemName="High Tech", Image="http://www.roblox.com/asset/?id=5805953977", ItemType="Knife", Rarity="Uncommon"},
	["Hive"]={ItemName="Hive", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315501434", ItemType="Knife", Rarity="Uncommon"},
	["HyperEdge"]={ItemName="Hyper's Edge", Image="https://www.roblox.com/asset/?id=8590484098", ItemType="Knife", Rarity="Godly"},
	["Ice"]={ItemName="Ice", Image="http://www.roblox.com/asset/?id=191976710", ItemType="Knife", Rarity="Common"},
	["Ice Cream"]={ItemName="Ice Cream", Image="http://www.roblox.com/asset/?id=10042435267", ItemType="Knife", Rarity="Rare"},
	["IceDragon"]={ItemName="Ice Dragon", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=585846454", ItemType="Knife", Rarity="Godly"},
	["IceShared"]={ItemName="Ice Shared", Image="http://www.roblox.com/asset/?id=6106353862", ItemType="Knife", Rarity="Godly"},
	["Iceblaster"]={ItemName="Iceblaster", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121579464", ItemType="Gun", Rarity="Godly"},
	["Icebreaker"]={ItemName="Icebreaker", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121572723", ItemType="Knife", Rarity="Ancient"},
	["Icecracker"]={ItemName="Icecracker", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121848805", ItemType="Knife", Rarity="Legendary"},
	["Icewing"]={ItemName="Icewing", Image="http://www.roblox.com/asset/?id=10029194550", ItemType="Knife", Rarity="Ancient"},
	["Imbued"]={ItemName="Imbued", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=162668312", ItemType="Gun", Rarity="Rare"},
	["Indy"]={ItemName="Indy", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=305506951", ItemType="Knife", Rarity="Common"},
	["Infected"]={ItemName="Infected", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=200953094", ItemType="Knife", Rarity="Common"},
	["Infiltrator"]={ItemName="Infiltrator", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203806022", ItemType="Gun", Rarity="Common"},
	["Iron"]={ItemName="Iron", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=160201541", ItemType="Gun", Rarity="Common"},
	["JD"]={ItemName="JD", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=566867312", ItemType="Knife", Rarity="Legendary"},
	["Jack"]={ItemName="Jack", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315099010", ItemType="Knife", Rarity="Rare"},
	["Jigsaw"]={ItemName="Jigsaw", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365569126", ItemType="Knife", Rarity="Uncommon"},
	["Knife1"]={ItemName="Splitter", Image="http://www.roblox.com/asset/?id=143820641", ItemType="Knife", Rarity="Classic"},
	["Kool"]={ItemName="Yellow", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473625906", ItemType="Knife", Rarity="Common"},
	["Korblox"]={ItemName="Korblox", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315501501", ItemType="Knife", Rarity="Rare"},
	["Krypto"]={ItemName="Krypto", Image="http://www.roblox.com/asset/?id=198458841", ItemType="Knife", Rarity="Rare"},
	["LMFAO"]={ItemName="Pink", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473626473", ItemType="Knife", Rarity="Uncommon"},
	["Laser"]={ItemName="Laser", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6017472763", ItemType="Gun", Rarity="Godly"},
	["Leaf"]={ItemName="Leaf", Image="http://www.roblox.com/asset/?id=5805963918", ItemType="Knife", Rarity="Common"},
	["Lightbringer"]={ItemName="Lightbringer", Image="http://www.roblox.com/asset/?id=5805977276", ItemType="Gun", Rarity="Godly"},
	["Linked"]={ItemName="Linked", Image="http://www.roblox.com/asset/?id=198453528", ItemType="Knife", Rarity="Common"},
	["Log"]={ItemName="Log", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365567962", ItemType="Knife", Rarity="Common"},
	["Logchopper"]={ItemName="Logchopper", Image="http://www.roblox.com/asset/?id=4528268775", ItemType="Knife", Rarity="Ancient"},
	["Love"]={ItemName="Love", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=196750845", ItemType="Knife", Rarity="Common"},
	["LoveGun"]={ItemName="Love", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203867650", ItemType="Gun", Rarity="Uncommon"},
	["Lovely"]={ItemName="Lovely", Image="http://www.roblox.com/asset/?id=5805966103", ItemType="Knife", Rarity="Common"},
	["Lucky"]={ItemName="Lucky", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365569265", ItemType="Knife", Rarity="Uncommon"},
	["Luger"]={ItemName="Luger", Image="http://www.roblox.com/asset/?id=6017473071", ItemType="Gun", Rarity="Godly"},
	["MLG"]={ItemName="Shiny", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473626979", ItemType="Knife", Rarity="Legendary"},
	["Magma"]={ItemName="Magma", Image="http://www.roblox.com/asset/?id=10909350159", ItemType="Knife", Rarity="Rare"},
	["Marina"]={ItemName="Marina", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203808190", ItemType="Gun", Rarity="Uncommon"},
	["Marley"]={ItemName="Green", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473625785", ItemType="Knife", Rarity="Common"},
	["Melon"]={ItemName="Melon", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315501369", ItemType="Knife", Rarity="Uncommon"},
	["Midnight"]={ItemName="Midnight", Image="http://www.roblox.com/asset/?id=197664126", ItemType="Knife", Rarity="Legendary"},
	["Midnight Fang"]={ItemName="Midnight Fang", Image="http://www.roblox.com/asset/?id=9970375658", ItemType="Knife", Rarity="Godly"},
	["Midnight Luger"]={ItemName="Midnight Luger", Image="http://www.roblox.com/asset/?id=9970374733", ItemType="Gun", Rarity="Godly"},
	["Missing"]={ItemName="Missing", Image="http://www.roblox.com/asset/?id=198455936", ItemType="Knife", Rarity="Uncommon"},
	["Molten"]={ItemName="Molten", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203869308", ItemType="Gun", Rarity="Rare"},
	["MoltenKnife"]={ItemName="Molten", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235371809", ItemType="Knife", Rarity="Rare"},
	["Moons"]={ItemName="Moons", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873154", ItemType="Knife", Rarity="Uncommon"},
	["Mummy"]={ItemName="Mummy", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315155591", ItemType="Gun", Rarity="Rare"},
	["Mummy2"]={ItemName="Mummy", Image="http://www.roblox.com/asset/?id=10909344882", ItemType="Knife", Rarity="Uncommon"},
	["Musical"]={ItemName="Musical", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365569566", ItemType="Knife", Rarity="Rare"},
	["MysteryKey"]={ItemName="Mystery Key", Image="rbxassetid://8636997898", ItemType="Misc", Rarity="Common"},
	["Nebula"]={ItemName="Nebula", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6598123521", ItemType="Knife", Rarity="Godly"},
	["Nebula Sword"]={ItemName="Nebula Sword", Image="http://www.roblox.com/asset/?id=9981540182", ItemType="Knife", Rarity="Godly"},
	["Neo-Harvester"]={ItemName="Bday's Harvester", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10291680038", ItemType="Gun", Rarity="Ancient"},
	["Neon"]={ItemName="Neon", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=159746637", ItemType="Knife", Rarity="Common"},
	["Neon Luger"]={ItemName="Neon Luger", Image="http://www.roblox.com/asset/?id=9970373678", ItemType="Gun", Rarity="Godly"},
	["Nether"]={ItemName="Nether", Image="http://www.roblox.com/asset/?id=197657098", ItemType="Knife", Rarity="Rare"},
	["News"]={ItemName="News", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238546032", ItemType="Gun", Rarity="Common"},
	["Night"]={ItemName="Night", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=159971385", ItemType="Gun", Rarity="Uncommon"},
	["Nightblade"]={ItemName="Nightblade", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=475478854", ItemType="Knife", Rarity="Godly"},
	["Nightfire"]={ItemName="Nightfire", Image="http://www.roblox.com/asset/?id=5805950020", ItemType="Gun", Rarity="Rare"},
	["NiksLaser"]={ItemName="Nik's Laser", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8524417874", ItemType="Gun", Rarity="Ancient"},
	["NiksScythe"]={ItemName="Nik's Scythe", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=2533350813", ItemType="Knife", Rarity="Ancient"},
	["Nova"]={ItemName="Nova", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235371686", ItemType="Knife", Rarity="Rare"},
	["Nutcracker"]={ItemName="Nutcracker", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332497657", ItemType="Gun", Rarity="Uncommon"},
	["Oceanbringer"]={ItemName="Oceanbringer", Image="http://www.roblox.com/asset/?id=9989448048", ItemType="Gun", Rarity="Godly"},
	["Oily"]={ItemName="Oily", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315501170", ItemType="Knife", Rarity="Common"},
	["Ollie"]={ItemName="Ollie", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=305504399", ItemType="Knife", Rarity="Common"},
	["Omega"]={ItemName="Omega", Image="http://www.roblox.com/asset/?id=9987789633", ItemType="Knife", Rarity="Godly"},
	["Orange Iceblaster"]={ItemName="Orange Iceblaster", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10530844362", ItemType="Gun", Rarity="Ancient"},
	["Orange Icebreaker"]={ItemName="Orange Icebreaker", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10280395003", ItemType="Knife", Rarity="Ancient"},
	["OrangeMarble"]={ItemName="Orange Marble", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873011", ItemType="Knife", Rarity="Rare"},
	["OrangeSeer"]={ItemName="Orange Seer", Image="http://www.roblox.com/asset/?id=5809284896", ItemType="Knife", Rarity="Godly"},
	["Ornament1"]={ItemName="Ornament", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=331745428", ItemType="Knife", Rarity="Common"},
	["Ornament1Gun"]={ItemName="Ornament1", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332497144", ItemType="Gun", Rarity="Common"},
	["Ornament2"]={ItemName="Ornament2", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=331745341", ItemType="Knife", Rarity="Common"},
	["Ornament2Gun"]={ItemName="Ornament2", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332497550", ItemType="Gun", Rarity="Common"},
	["Ornaments"]={ItemName="Ornaments", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121853160", ItemType="Knife", Rarity="Common"},
	["Overseer"]={ItemName="Overseer", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=175668680", ItemType="Gun", Rarity="Legendary"},
	["OverseerKnife"]={ItemName="Overseer", Image="http://www.roblox.com/asset/?id=198458910", ItemType="Knife", Rarity="Legendary"},
	["Paper"]={ItemName="Paper", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235366870", ItemType="Knife", Rarity="Uncommon"},
	["Passion"]={ItemName="Passion", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=363150334", ItemType="Knife", Rarity="Common"},
	["Patrick"]={ItemName="Patrick", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=383476085", ItemType="Knife", Rarity="Common"},
	["Pea"]={ItemName="Pea", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238545971", ItemType="Gun", Rarity="Common"},
	["Pepper"]={ItemName="Brown", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473625645", ItemType="Knife", Rarity="Common"},
	["Peppermint"]={ItemName="Peppermint", Image="http://www.roblox.com/asset/?id=6106353862", ItemType="Knife", Rarity="Godly"},
	["Phantom"]={ItemName="Phantom", Image="http://www.roblox.com/asset/?id=10909336975", ItemType="Knife", Rarity="Common"},
	["Phaser"]={ItemName="Phaser", Image="http://www.roblox.com/asset/?id=144325423", ItemType="Gun", Rarity="Classic"},
	["Pirate"]={ItemName="Pirate", Image="http://www.roblox.com/asset/?id=5805744004", ItemType="Gun", Rarity="Uncommon"},
	["Pixel"]={ItemName="Pixel", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365347166", ItemType="Knife", Rarity="Godly"},
	["Pixel Gun"]={ItemName="Pixel", Image="http://www.roblox.com/asset/?id=10324763229", ItemType="Gun", Rarity="Godly"},
	["Plasmabeam"]={ItemName="Plasmabeam", Image="http://www.roblox.com/asset/?id=10081702265", ItemType="Gun", Rarity="Godly"},
	["Plasmablade"]={ItemName="Plasmablade", Image="http://www.roblox.com/asset/?id=10081700679", ItemType="Knife", Rarity="Godly"},
	["Plasmite"]={ItemName="Plasmite", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=161369368", ItemType="Knife", Rarity="Legendary"},
	["PoisonBeam"]={ItemName="Poisonbeam", Image="http://www.roblox.com/asset/?id=7676156595", ItemType="Gun", Rarity="Godly"},
	["PoisonBlade"]={ItemName="Poisonblade", Image="http://www.roblox.com/asset/?id=7676155486", ItemType="Knife", Rarity="Godly"},
	["Potion"]={ItemName="Potion", Image="http://www.roblox.com/asset/?id=10909346684", ItemType="Knife", Rarity="Uncommon"},
	["Predator"]={ItemName="Predator", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203810176", ItemType="Gun", Rarity="Legendary"},
	["PredatorKnife"]={ItemName="Predator", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235372015", ItemType="Knife", Rarity="Legendary"},
	["Prism"]={ItemName="Prism", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=306046703", ItemType="Knife", Rarity="Common"},
	["Prismatic"]={ItemName="Prismatic", Image="http://www.roblox.com/asset/?id=5645266804", ItemType="Knife", Rarity="Godly"},
	["Pumpking"]={ItemName="Pumpking", Image="http://www.roblox.com/asset/?id=10909354337", ItemType="Knife", Rarity="Godly"},
	["Purple Iceblaster"]={ItemName="Purple Iceblaster", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10530854068", ItemType="Gun", Rarity="Ancient"},
	["Purple Icebreaker"]={ItemName="Purple Icebreaker", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10281930066", ItemType="Knife", Rarity="Ancient"},
	["PurpleSeer"]={ItemName="Purple Seer", Image="http://www.roblox.com/asset/?id=5809284486", ItemType="Knife", Rarity="Godly"},
	["Rainbow"]={ItemName="Rainbow", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=159747377", ItemType="Knife", Rarity="Rare"},
	["RainbowGun"]={ItemName="Rainbow", Image="http://www.roblox.com/asset/?id=5805735262", ItemType="Gun", Rarity="Rare"},
	["RandLuger"]={ItemName="?Luger?", Image="https://www.roblox.com/asset/?id=332362247", ItemType="Gun", Rarity="Godly"},
	["Red Flower"]={ItemName="Red Flower", Image="http://www.roblox.com/asset/?id=10042423088", ItemType="Knife", Rarity="Common"},
	["Red Iceblaster"]={ItemName="Red Iceblaster", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10530855956", ItemType="Gun", Rarity="Ancient"},
	["Red Icebreaker"]={ItemName="Red Icebreaker", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10281934246", ItemType="Knife", Rarity="Ancient"},
	["RedLuger"]={ItemName="Red Luger", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332044583", ItemType="Gun", Rarity="Godly"},
	["RedSeer"]={ItemName="Red Seer", Image="http://www.roblox.com/asset/?id=5809283834", ItemType="Knife", Rarity="Godly"},
	["Reptile"]={ItemName="Reptile", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=162672131", ItemType="Knife", Rarity="Common"},
	["Retro Sunset"]={ItemName="Retro Sunset", Image="http://www.roblox.com/asset/?id=10042436051", ItemType="Knife", Rarity="Legendary"},
	["Roses"]={ItemName="Roses", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=363352002", ItemType="Knife", Rarity="Common"},
	["Rune"]={ItemName="Rune", Image="http://www.roblox.com/asset/?id=5805732208", ItemType="Knife", Rarity="Legendary"},
	["Sandy"]={ItemName="Sandy", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365568056", ItemType="Knife", Rarity="Common"},
	["Santa"]={ItemName="Santa", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=331746096", ItemType="Knife", Rarity="Common"},
	["SantaGun"]={ItemName="Santa", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332496861", ItemType="Gun", Rarity="Common"},
	["Saw"]={ItemName="Saw", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6017475768", ItemType="Knife", Rarity="Godly"},
	["Scratch"]={ItemName="Scratch", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873371", ItemType="Knife", Rarity="Legendary"},
	["Shaded"]={ItemName="Shaded", Image="http://www.roblox.com/asset/?id=5805968838", ItemType="Knife", Rarity="Common"},
	["ShadowKnife"]={ItemName="Shadow", Image="http://www.roblox.com/asset/?id=144070096", ItemType="Knife", Rarity="Classic"},
	["Shadowitempack"]={ItemName="Shadow Item pack", Image="http://www.roblox.com/asset/?id=5807078730", ItemType="Knife", Rarity="Godly"},
	["Shark"]={ItemName="Shark", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6017475362", ItemType="Gun", Rarity="Godly"},
	["SharkSeeker"]={ItemName="SharkSeeker", Image="http://www.roblox.com/asset/?id=7171844373", ItemType="Gun", Rarity="Victim"},
	["Sidewinder"]={ItemName="Sidewinder", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=305503783", ItemType="Knife", Rarity="Common"},
	["SilentNight"]={ItemName="Silent Night", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121860619", ItemType="Gun", Rarity="Rare"},
	["Sketch"]={ItemName="Sketch", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203808108", ItemType="Gun", Rarity="Uncommon"},
	["SketchYT"]={ItemName="Sketchy", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=546161470", ItemType="Knife", Rarity="Common"},
	["Skool"]={ItemName="Skool", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=295269977", ItemType="Knife", Rarity="Common"},
	["Skyfire"]={ItemName="Skyfire", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10144415540", ItemType="Knife", Rarity="Godly"},
	["Slasher"]={ItemName="Slasher", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6017473508", ItemType="Knife", Rarity="Godly"},
	["Slate"]={ItemName="Slate", Image="http://www.roblox.com/asset/?id=198453556", ItemType="Knife", Rarity="Common"},
	["Snoop"]={ItemName="Red", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=473626150", ItemType="Knife", Rarity="Uncommon"},
	["Snowflakes"]={ItemName="Snowflakes", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6123338102", ItemType="Knife", Rarity="Rare"},
	["Snowman"]={ItemName="Snowman", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=331745799", ItemType="Knife", Rarity="Uncommon"},
	["SnowmanGun"]={ItemName="Snowman", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332497603", ItemType="Gun", Rarity="Uncommon"},
	["Snowy"]={ItemName="Snowy", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332011125", ItemType="Knife", Rarity="Uncommon"},
	["Sorry"]={ItemName="Corrupt", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=197879343", ItemType="Knife", Rarity="Victim"},
	["Space"]={ItemName="Space", Image="http://www.roblox.com/asset/?id=5805739006", ItemType="Knife", Rarity="Rare"},
	["Sparkle"]={ItemName="Sparkle", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203869110", ItemType="Gun", Rarity="Legendary"},
	["Sparkle1"]={ItemName="Sparkle1", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=310709709", ItemType="Knife", Rarity="Common"},
	["Sparkle10"]={ItemName="Sparkle10", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=310715768", ItemType="Knife", Rarity="Common"},
	["Sparkle2"]={ItemName="Sparkle2", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=310710191", ItemType="Knife", Rarity="Common"},
	["Sparkle3"]={ItemName="Sparkle3", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=310710694", ItemType="Knife", Rarity="Common"},
	["Sparkle4"]={ItemName="Sparkle4", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=310712788", ItemType="Knife", Rarity="Common"},
	["Sparkle5"]={ItemName="Sparkle5", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=310713235", ItemType="Knife", Rarity="Common"},
	["Sparkle6"]={ItemName="Sparkle6", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=310713648", ItemType="Knife", Rarity="Common"},
	["Sparkle7"]={ItemName="Sparkle7", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=310714089", ItemType="Knife", Rarity="Common"},
	["Sparkle8"]={ItemName="Sparkle8", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=310714407", ItemType="Knife", Rarity="Common"},
	["Sparkle9"]={ItemName="Sparkle9", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=310715104", ItemType="Knife", Rarity="Common"},
	["Spectrum"]={ItemName="Spectrum", Image="http://www.roblox.com/asset/?id=198458862", ItemType="Knife", Rarity="Rare"},
	["Spider"]={ItemName="Spider", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315120760", ItemType="Knife", Rarity="Godly"},
	["Spitfire"]={ItemName="Spitfire", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=159971321", ItemType="Gun", Rarity="Rare"},
	["Splash"]={ItemName="Splash", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235371439", ItemType="Knife", Rarity="Legendary"},
	["Splash Luger"]={ItemName="Splash Luger", Image="http://www.roblox.com/asset/?id=9970372863", ItemType="Gun", Rarity="Godly"},
	["SplashGun"]={ItemName="Splash", Image="http://www.roblox.com/asset/?id=5805943259", ItemType="Gun", Rarity="Legendary"},
	["Splat"]={ItemName="Splat", Image="http://www.roblox.com/asset/?id=5805754745", ItemType="Gun", Rarity="Common"},
	["Splatter"]={ItemName="Splatter", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=159432647", ItemType="Knife", Rarity="Common"},
	["Squire"]={ItemName="Squire", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315501560", ItemType="Knife", Rarity="Rare"},
	["Stainless"]={ItemName="Stainless", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235366771", ItemType="Knife", Rarity="Common"},
	["Stalker"]={ItemName="Stalker", Image="http://www.roblox.com/asset/?id=198455980", ItemType="Knife", Rarity="Uncommon"},
	["Star"]={ItemName="Star", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203807904", ItemType="Gun", Rarity="Common"},
	["Static"]={ItemName="Static", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=365568163", ItemType="Knife", Rarity="Common"},
	["Stockings"]={ItemName="Stockings", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6123335682", ItemType="Knife", Rarity="Common"},
	["Sub"]={ItemName="Sub", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=546159250", ItemType="Knife", Rarity="Common"},
	["Sugar"]={ItemName="Sugar", Image="http://www.roblox.com/asset/?id=10006845822", ItemType="Gun", Rarity="Godly"},
	["Summer Rifle"]={ItemName="Summer Rifle", Image="http://www.roblox.com/asset/?id=10122690888", ItemType="Gun", Rarity="Godly"},
	["Summer Tech"]={ItemName="Summer Tech", Image="http://www.roblox.com/asset/?id=10122687783", ItemType="Knife", Rarity="Godly"},
	["Summer's Blade"]={ItemName="Summer's Blade", Image="http://www.roblox.com/asset/?id=9981543428", ItemType="Knife", Rarity="Ancient"},
	["Summer's Scimitar"]={ItemName="Summer's Scimitar", Image="http://www.roblox.com/asset/?id=10042436887", ItemType="Knife", Rarity="Godly"},
	["Summer's Sword"]={ItemName="Summer's Sword", Image="http://www.roblox.com/asset/?id=10042439807", ItemType="Knife", Rarity="Godly"},
	["Summerween"]={ItemName="Summerween", Image="http://www.roblox.com/asset/?id=10042433636", ItemType="Knife", Rarity="Rare"},
	["Sun"]={ItemName="Sun", Image="http://www.roblox.com/asset/?id=10042421790", ItemType="Knife", Rarity="Common"},
	["Sweetheart"]={ItemName="Sweetheart", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=363150761", ItemType="Knife", Rarity="Common"},
	["SwirlyAxe"]={ItemName="Swirly Axe", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8304801000", ItemType="Knife", Rarity="Ancient"},
	["SwirlyBlade"]={ItemName="Swirly Blade", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8304805693", ItemType="Knife", Rarity="Godly"},
	["SwirlyGun"]={ItemName="Swirly Gun", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8305002569", ItemType="Gun", Rarity="Godly"},
	["TNL"]={ItemName="TNL", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=201542790", ItemType="Knife", Rarity="Common"},
	["Tailslide"]={ItemName="Tailslide", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=305506822", ItemType="Knife", Rarity="Common"},
	["TheSeer"]={ItemName="Seer", Image="http://www.roblox.com/asset/?id=3184139765", ItemType="Knife", Rarity="Godly"},
	["Tides"]={ItemName="Tides", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6017476161", ItemType="Knife", Rarity="Godly"},
	["Tiger"]={ItemName="Tiger", Image="http://www.roblox.com/asset/?id=5805747427", ItemType="Knife", Rarity="Uncommon"},
	["TimeKnife"]={ItemName="Prince", Image="http://www.roblox.com/asset/?id=143917700", ItemType="Knife", Rarity="Classic"},
	["Toxic's Edge"]={ItemName="Toxic's Edge", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10692534741", ItemType="Knife", Rarity="Godly"},
	["ToyBasketball"]={ItemName="Basketball", Image="rbxassetid://583505141", ItemType="Misc", Rarity="Christmas"},
	["ToyGameSystem"]={ItemName="Game System", Image="rbxassetid://583509564", ItemType="Misc", Rarity="Christmas"},
	["ToyRobot"]={ItemName="Toy Robot", Image="rbxassetid://583508162", ItemType="Misc", Rarity="Christmas"},
	["ToySkateboard"]={ItemName="Skateboard", Image="rbxassetid://583508609", ItemType="Misc", Rarity="Christmas"},
	["Tree"]={ItemName="Tree", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=331745577", ItemType="Knife", Rarity="Legendary"},
	["TreeGun"]={ItemName="Tree", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332497688", ItemType="Gun", Rarity="Legendary"},
	["Trees"]={ItemName="Trees", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6123336879", ItemType="Knife", Rarity="Common"},
	["Tulip"]={ItemName="Tulip", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=387874661", ItemType="Knife", Rarity="Common"},
	["Universe"]={ItemName="Universe", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238546660", ItemType="Gun", Rarity="Legendary"},
	["Valentine"]={ItemName="Valentine", Image="https://www.roblox.com/asset/?id=363362726", ItemType="Knife", Rarity="Common"},
	["Vampire"]={ItemName="Vampire", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873248", ItemType="Knife", Rarity="Uncommon"},
	["Viper"]={ItemName="Viper", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=160299600", ItemType="Gun", Rarity="Legendary"},
	["Virtual"]={ItemName="Virtual", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=386276987", ItemType="Knife", Rarity="Godly"},
	["Vortex"]={ItemName="Vortex", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=235371508", ItemType="Knife", Rarity="Rare"},
	["Vortex2"]={ItemName="Vortex", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=8084065311", ItemType="Knife", Rarity="Godly"},
	["Wanwood"]={ItemName="Wanwood", Image="http://www.roblox.com/asset/?id=192132094", ItemType="Knife", Rarity="Uncommon"},
	["Web"]={ItemName="Web", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=315104004", ItemType="Knife", Rarity="Legendary"},
	["Webs"]={ItemName="Webs", Image="http://www.roblox.com/asset/?id=10909347694", ItemType="Knife", Rarity="Uncommon"},
	["Whiteout"]={ItemName="Whiteout", Image="http://www.roblox.com/asset/?id=191788694", ItemType="Knife", Rarity="Common"},
	["Witch"]={ItemName="Witch", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873553", ItemType="Knife", Rarity="Common"},
	["Wolf"]={ItemName="Wolf", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=531873487", ItemType="Knife", Rarity="Uncommon"},
	["Wooden"]={ItemName="Wooden", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=238546356", ItemType="Gun", Rarity="Uncommon"},
	["WrapGun"]={ItemName="Wrap", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121867603", ItemType="Gun", Rarity="Uncommon"},
	["WrapKnife"]={ItemName="Wrap", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=6121854816", ItemType="Knife", Rarity="Uncommon"},
	["WrapPaperBoxGold"]={ItemName="Box of Gold Wrapping Paper", Image="rbxassetid://586083489", ItemType="Misc", Rarity="Christmas"},
	["WrapPaperBoxPurple"]={ItemName="Box of Purple Wrapping Paper", Image="rbxassetid://586083461", ItemType="Misc", Rarity="Christmas"},
	["WrapPaperBoxRed"]={ItemName="Box of Red Wrapping Paper", Image="rbxassetid://586083433", ItemType="Misc", Rarity="Christmas"},
	["Wrapped"]={ItemName="Wrapped", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=331745500", ItemType="Knife", Rarity="Uncommon"},
	["WrappedGun"]={ItemName="Wrapped", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332497103", ItemType="Gun", Rarity="Uncommon"},
	["Xbox"]={ItemName="Xbox", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=439325100", ItemType="Knife", Rarity="Common"},
	["Xmas"]={ItemName="Xmas", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=332077449", ItemType="Knife", Rarity="Godly"},
	["Yellow Iceblaster"]={ItemName="Yellow Iceblaster", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10530850715", ItemType="Gun", Rarity="Ancient"},
	["Yellow Icebreaker"]={ItemName="Yellow Icebreaker", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=10281925856", ItemType="Knife", Rarity="Ancient"},
	["YellowSeer"]={ItemName="Yellow Seer", Image="http://www.roblox.com/asset/?id=5809285257", ItemType="Knife", Rarity="Godly"},
	["Zombie"]={ItemName="Zombie", Image="http://www.roblox.com/asset/?id=10909339376", ItemType="Knife", Rarity="Common"},
	["iRevolver"]={ItemName="iRevolver", Image="http://www.roblox.com/Thumbs/Asset.ashx?format=png&width=250&height=250&assetId=203809168", ItemType="Gun", Rarity="Rare"},
}

-- Real MM2 pets extracted from the place file (48).
local PetDB = {
	["<3"]={Name="<3", Image="363155463", ItemType="Knife", Rarity="Common"},
	["AmericanEagle"]={Name="Sammy", Image="446052376", ItemType="Knife", Rarity="Godly"},
	["Badger"]={Name="Badger", Image="357817300", ItemType="Knife", Rarity="Common"},
	["Bat"]={Name="Bat", Image="4989103049", ItemType="Knife", Rarity="Legendary"},
	["Bear"]={Name="Bear", Image="4989101654", ItemType="Knife", Rarity="Rare"},
	["Bunny"]={Name="Bunny", Image="4989098177", ItemType="Knife", Rarity="Common"},
	["Cat"]={Name="Cat", Image="4989095647", ItemType="Knife", Rarity="Common"},
	["Chilly"]={Name="Chilly", Image="357821774", ItemType="Knife", Rarity="Uncommon"},
	["ChromaFireBat"]={Name="Fire Bat", Image="3215184228", ItemType="Knife", Rarity="Godly", Chroma=true},
	["ChromaFireBear"]={Name="Fire Bear", Image="3215184104", ItemType="Knife", Rarity="Godly", Chroma=true},
	["ChromaFireBunny"]={Name="Fire Bunny", Image="3215183621", ItemType="Knife", Rarity="Godly", Chroma=true},
	["ChromaFireCat"]={Name="Fire Cat", Image="3215183286", ItemType="Knife", Rarity="Godly", Chroma=true},
	["ChromaFireDog"]={Name="Fire Dog", Image="3215183415", ItemType="Knife", Rarity="Godly", Chroma=true},
	["ChromaFireFox"]={Name="Fire Fox", Image="3215183922", ItemType="Knife", Rarity="Godly", Chroma=true},
	["ChromaFirePig"]={Name="Fire Pig", Image="3215183776", ItemType="Knife", Rarity="Godly", Chroma=true},
	["Deathspeaker"]={Name="Deathspeaker", Image="357651865", ItemType="Knife", Rarity="Godly"},
	["Dog"]={Name="Dog", Image="4989094404", ItemType="Knife", Rarity="Common"},
	["Doge"]={Name="Doge", Image="357823389", ItemType="Knife", Rarity="Uncommon"},
	["Dogey"]={Name="Dogey", Image="357823389", ItemType="Knife", Rarity="Uncommon"},
	["Electro"]={Name="Electro", Image="386277688", ItemType="Knife", Rarity="Godly"},
	["Elfy"]={Name="Elf", Image="585798235", ItemType="Knife", Rarity="Common"},
	["Elitey"]={Name="Elitey", Image="357525407", ItemType="Knife", Rarity="Legendary"},
	["Eye"]={Name="Eyeball", Image="358134944", ItemType="Knife", Rarity="Rare"},
	["Fairy"]={Name="Fairy", Image="358125321", ItemType="Knife", Rarity="Uncommon"},
	["FireBat"]={Name="Fire Bat", Image="4989110877", ItemType="Knife", Rarity="Godly"},
	["FireBear"]={Name="Fire Bear", Image="4989109913", ItemType="Knife", Rarity="Godly"},
	["FireBunny"]={Name="Fire Bunny", Image="4989105489", ItemType="Knife", Rarity="Godly"},
	["FireCat"]={Name="Fire Cat", Image="4989104744", ItemType="Knife", Rarity="Godly"},
	["FireDog"]={Name="Fire Dog", Image="4964183897", ItemType="Knife", Rarity="Godly"},
	["FireFox"]={Name="Fire Fox", Image="4989107429", ItemType="Knife", Rarity="Godly"},
	["FirePig"]={Name="Fire Pig", Image="4989106599", ItemType="Knife", Rarity="Godly"},
	["Fox"]={Name="Fox", Image="4989100515", ItemType="Knife", Rarity="Uncommon"},
	["HeartBalloon"]={Name="<3", Image="363155463", ItemType="Knife", Rarity="Common"},
	["IcePhoenix"]={Name="Ice Phoenix", Image="6134733219", ItemType="Knife", Rarity="Godly"},
	["Jetstream"]={Name="Jetstream", Image="358126292", ItemType="Knife", Rarity="Rare"},
	["Mechbug"]={Name="Mechbug", Image="357789913", ItemType="Knife", Rarity="Rare"},
	["Nobledragon"]={Name="Nobledragon", Image="357813086", ItemType="Knife", Rarity="Legendary"},
	["Overseer Eye"]={Name="Overseer Eye", Image="358135658", ItemType="Knife", Rarity="Legendary"},
	["Pengy"]={Name="Pengy", Image="357655751", ItemType="Knife", Rarity="Common"},
	["Phoenix"]={Name="Phoenix", Image="365355267", ItemType="Knife", Rarity="Godly"},
	["Pig"]={Name="Pig", Image="4989099890", ItemType="Knife", Rarity="Uncommon"},
	["Piggy"]={Name="Piggy", Image="357816542", ItemType="Knife", Rarity="Common"},
	["Reindeer"]={Name="Reindeer", Image="585789096", ItemType="Knife", Rarity="Common"},
	["Seahorsey"]={Name="Seahorsey", Image="357818987", ItemType="Knife", Rarity="Uncommon"},
	["Skelly"]={Name="Skelly", Image="475477388", ItemType="Knife", Rarity="Godly"},
	["Steambird"]={Name="Steambird", Image="360615840", ItemType="Knife", Rarity="Godly"},
	["Tankie"]={Name="Tankie", Image="357793334", ItemType="Knife", Rarity="Rare"},
	["UFO"]={Name="UFO", Image="357654905", ItemType="Knife", Rarity="Common"},
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

	-- Platform-correct pick. Both the PC ("Trade") and the phone ("TradeGUI_Phone")
	-- layouts can coexist in PlayerGui, so we must match the current device: on a
	-- desktop (mouse) use the NON-phone GUI, on touch use the phone one. Driving the
	-- wrong one shows the phone layout on PC (what the user was seeing). Score each:
	-- platform match >> Enabled >> owns Container.Trade.
	local preferPhone = IsTouch
	local best, bestScore
	for _, gui in ipairs(candidates) do
		local s = 0
		if isPhone(gui) == preferPhone then s = s + 100 end
		if gui.Enabled then s = s + 10 end
		if resolve(gui, "Container.Trade") then s = s + 1 end
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

-- Items the user spawned into the inventory (key -> amount).
local SpawnedWeapons = {}
local SpawnedPets = {}

-- Items scraped from the REAL game inventory rendered in PlayerGui
-- (category -> { key = { visual = {Image,Name,Color,Chroma}, amount } }).
local RealInv = { Weapons = {}, Pets = {} }

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
			local rarity = data and data.Rarity
			-- Exactly like the live UpdateTrade: the ItemName PLATE is the rarity
			-- colour, grey for Common. (No bright label text — that was wrong.)
			local plate = (rarity == "Common") and RARITY_GREY
				or (rarity and Rarity[rarity]) or (visual and visual.Color) or RARITY_GREY
			local chroma = (visual and visual.Chroma) or (data and data.Chroma ~= nil) or false
			slot.Visible = true
			setProp(slot, "Container.Icon", "Image", img)
			setProp(slot, "ItemName.Label", "Text", name)
			setProp(slot, "ItemName.Label", "TextColor3", Color3.fromRGB(255, 255, 255))
			setProp(slot, "ItemName.RarityBar", "BackgroundColor3", plate)
			setProp(slot, "ItemName", "BackgroundColor3", plate)
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

-- ===== Real-inventory link ====================================================
-- The game renders the player's owned items as slots in PlayerGui (each slot's
-- .Name is the item key, with a real Icon image + rarity + amount). We scrape
-- those to mirror the REAL inventory into the trade — no server calls, no
-- catalog dependency. Open your inventory/trade so the slots exist, then Link.
local function slotIconImage(d)
	local icon
	if d:IsA("ImageLabel") or d:IsA("ImageButton") then icon = d
	else icon = d:FindFirstChild("Icon") or resolve(d, "Container.Icon") end
	if icon and (icon:IsA("ImageLabel") or icon:IsA("ImageButton")) then
		local img = icon.Image
		if type(img) == "string" and img ~= "" and img ~= "rbxassetid://0" then return img end
	end
	return nil
end

local function scrapeRealInventory()
	local result = { Weapons = {}, Pets = {} }
	local total = 0
	for _, d in ipairs(PlayerGui:GetDescendants()) do
		if d:IsA("GuiObject")
			and not d:GetAttribute("__MHSpawn")               -- skip slots we rendered
			and not d:FindFirstAncestor("TradeDebugPanel") then -- skip our own panel
			-- skip anything inside a trade OFFER frame (those are offered items)
			local inOffer = false
			for _, nm in ipairs({ "Offer1", "Offer2", "YourOffer", "TheirOffer" }) do
				if d:FindFirstAncestor(nm) then inOffer = true; break end
			end
			local img = (not inOffer) and slotIconImage(d) or nil
			if img then
				local key = d.Name
				local known = ItemDB[key] or PetDB[key]
				local nameLabel = resolve(d, "ItemName.Label")
					or (d:FindFirstChild("ItemName") and d.ItemName:FindFirstChildWhichIsA("TextLabel"))
					or (d:FindFirstChild("ItemName") and d.ItemName:IsA("TextLabel") and d.ItemName)
				-- only treat as an item slot if it has a name label or a known key
				if known or (nameLabel and nameLabel:IsA("TextLabel")) then
					local isPet = (d:FindFirstAncestor("Pets") or d:FindFirstAncestor("PetsFrame")) ~= nil
						or PetDB[key] ~= nil
					local cat = isPet and "Pets" or "Weapons"
					local visual = readSlotVisual(d)
					visual.Image = img
					if nameLabel and nameLabel:IsA("TextLabel") and tostring(nameLabel.Text) ~= "" then
						visual.Name = nameLabel.Text
					end
					-- Prefer clean catalog name/rarity when the key is known.
					local db = known and (isPet and PetDB or ItemDB)[key]
					if db then
						visual.Name = db.ItemName or db.Name or visual.Name
						visual.Color = (db.Rarity == "Common") and RARITY_GREY
							or (Rarity[db.Rarity] or visual.Color)
						visual.Chroma = db.Chroma == true
					end
					-- Amount from the slot ("x67" -> 67).
					local amtLabel = resolve(d, "Container.Amount") or d:FindFirstChild("Amount", true)
					local amount = 1
					if amtLabel and amtLabel:IsA("TextLabel") then
						local n = tonumber((tostring(amtLabel.Text):gsub("%D", "")))
						if n and n > 0 then amount = n end
					end
					if not result[cat][key] then
						result[cat][key] = { visual = visual, amount = amount }
						total = total + 1
					end
				end
			end
		end
	end
	return result, total
end
-- ============================================================================

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

local function findInventoryContainer(category)
	-- Desktop (GUI2 Menu_Trade): the exact tabbed grids. Prefer these so spawned
	-- items land in the real Weapons/Pets inventory panels shown in the trade UI.
	local direct = (category == "Pets") and PetsFrame or InventoryFrame
	if direct then
		local tmpl
		for _, slot in ipairs(direct:GetChildren()) do
			if slot:IsA("GuiObject") and (slot:FindFirstChild("ItemName") or resolve(slot, "Container.Icon")) then
				tmpl = slot; break
			end
		end
		tmpl = tmpl or anyTemplateSlot()
		if tmpl then return direct, tmpl end
	end
	-- Fallback: scan the picker for a category-matching real slot + its parent.
	if ItemsPicker then
		for _, slot in ipairs(ItemsPicker:GetDescendants()) do
			local icon = slot:FindFirstChild("Icon") or resolve(slot, "Container.Icon")
			local btn = resolve(slot, "Container.Button") or resolve(slot, "Container.ActionButton") or slot:FindFirstChild("Button")
			if icon and icon:IsA("ImageLabel") and btn and btn:IsA("GuiButton") then
				local isPet = (slot:FindFirstAncestor("Pets") or slot:FindFirstAncestor("PetsFrame")) ~= nil
				if (category == "Pets") == isPet then
					return slot.Parent, slot
				end
			end
		end
	end
	return nil, nil
end

-- Per-category cache of { container, template } captured from a real game slot
-- (correct size/style on phone). InvContainer kept for openItemsPicker reveal.
local InvCache = {}
local InvContainer

-- Stamp a catalog item onto a cloned slot. Matches the game's INVENTORY style:
-- the ItemName PLATE is coloured by rarity (grey for Common); the label text
-- keeps the template's own colour — this fixes the "wrong/too bright" colours.
local function paintSlot(slot, data, amount)
	slot.Name = data.ItemName or data.Name or "Item"
	slot.Visible = true
	slot:SetAttribute("__MHSpawn", true)
	local icon = slot:FindFirstChild("Icon") or resolve(slot, "Container.Icon")
	if icon then pcall(function() icon.Image = getImage(data.Image) end) end
	local nameFrame = slot:FindFirstChild("ItemName")
	local label = (nameFrame and nameFrame:FindFirstChild("Label")) or resolve(slot, "ItemName.Label")
		or slot:FindFirstChild("Label", true)
	if label and label:IsA("TextLabel") then
		pcall(function() label.Text = data.ItemName or data.Name or slot.Name end)
	end
	if nameFrame and nameFrame:IsA("GuiObject") then
		local col = (data.Rarity == "Common") and Color3.fromRGB(106, 106, 106)
			or (Rarity[data.Rarity] or Color3.fromRGB(140, 140, 145))
		pcall(function() nameFrame.BackgroundColor3 = col end)
	end
	local amt = resolve(slot, "Container.Amount") or slot:FindFirstChild("Amount", true)
	if amt and amt:IsA("TextLabel") then amt.Text = (amount and amount > 1) and ("x" .. amount) or "" end
	setProp(slot, "Tags.Chroma", "Visible", data.Chroma == true)
end

-- Paint a slot straight from a scraped real-inventory visual (no catalog needed).
local function paintSlotVisual(slot, visual, amount)
	slot.Name = visual.Name or "Item"
	slot.Visible = true
	slot:SetAttribute("__MHSpawn", true)
	local icon = slot:FindFirstChild("Icon") or resolve(slot, "Container.Icon")
	if icon then pcall(function() icon.Image = visual.Image end) end
	local nameFrame = slot:FindFirstChild("ItemName")
	local label = (nameFrame and nameFrame:FindFirstChild("Label")) or resolve(slot, "ItemName.Label")
		or slot:FindFirstChild("Label", true)
	if label and label:IsA("TextLabel") then pcall(function() label.Text = visual.Name end) end
	if nameFrame and nameFrame:IsA("GuiObject") then
		pcall(function() nameFrame.BackgroundColor3 = visual.Color end)
	end
	local amt = resolve(slot, "Container.Amount") or slot:FindFirstChild("Amount", true)
	if amt and amt:IsA("TextLabel") then amt.Text = (amount and amount > 1) and ("x" .. amount) or "" end
	setProp(slot, "Tags.Chroma", "Visible", visual.Chroma == true)
end

-- Render one inventory pane (Weapons/Pets): spawned catalog items first, then
-- items mirrored from the REAL game inventory. Each is a clone of a real slot so
-- the size/style matches the game.
local function renderPane(category, list, db)
	local cache = InvCache[category]
	if not (cache and cache.container and cache.template) then
		local container, sample = findInventoryContainer(category)
		if not container then return end            -- no real slot to template from yet
		cache = { container = container, template = sample:Clone() }
		InvCache[category] = cache
	end
	local container, template = cache.container, cache.template
	if category == "Weapons" then InvContainer = container end

	for _, c in ipairs(container:GetChildren()) do
		if c:IsA("GuiObject") then c:Destroy() end
	end

	local arr = {}
	for key, amount in pairs(list) do table.insert(arr, { key = key, amount = amount }) end
	table.sort(arr, function(a, b)
		local ra = RarityValue[(db[a.key] or {}).Rarity or "Common"] or 0
		local rb = RarityValue[(db[b.key] or {}).Rarity or "Common"] or 0
		if ra ~= rb then return ra > rb end
		return a.key < b.key
	end)

	local function wireOffer(slot, key, cat, visual)
		local btn = resolve(slot, "Container.Button") or resolve(slot, "Container.ActionButton") or slot:FindFirstChild("Button")
		if btn and btn:IsA("GuiButton") then
			trackRender(btn.MouseButton1Click:Connect(function()
				offerItemLocal(key, cat, visual)
			end))
		else
			-- No button in this template: make the slot itself clickable.
			if slot:IsA("GuiButton") then
				trackRender(slot.MouseButton1Click:Connect(function()
					offerItemLocal(key, cat, visual)
				end))
			end
		end
	end

	-- 1) Spawned catalog items.
	for _, e in ipairs(arr) do
		local data = db[e.key]
		if data then
			local slot = template:Clone()
			paintSlot(slot, data, e.amount)
			slot.Parent = container
			wireOffer(slot, e.key, category, catalogVisual(e.key, category))
		end
	end

	-- 2) Items mirrored from the REAL game inventory.
	local realArr = {}
	for key, rec in pairs(RealInv[category] or {}) do
		table.insert(realArr, { key = key, rec = rec })
	end
	table.sort(realArr, function(a, b) return tostring(a.rec.visual.Name) < tostring(b.rec.visual.Name) end)
	for _, e in ipairs(realArr) do
		if not list[e.key] then  -- don't duplicate an item that was also spawned
			local slot = template:Clone()
			paintSlotVisual(slot, e.rec.visual, e.rec.amount)
			slot.Parent = container
			wireOffer(slot, e.key, category, e.rec.visual)
		end
	end
end

local function renderInventory()
	renderPane("Weapons", SpawnedWeapons, ItemDB)
	renderPane("Pets", SpawnedPets, PetDB)
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
		ItemsPicker.Visible = true
	end
	-- Phone: the picker replaces the offers (they'd overlap on the small screen).
	-- Desktop: the inventory sits beside the offers, so keep BOTH visible.
	if IsPhone and TradeRoot then TradeRoot.Visible = false end
	renderInventory()  -- captures + reveals the inventory container, renders spawned
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

	RealInv = scrapeRealInventory()   -- mirror the real game inventory in automatically
	RenderTrade()
	renderInventory()  -- fill the inventory panels with your real + spawned items
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
local BG_IMAGE = "rbxassetid://136747514517812"

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
Bg.ImageTransparency = 0.15; Bg.ZIndex = 0; Bg.Parent = Window
-- Scrim over the image so text stays readable, but light enough to SEE the image.
local Overlay = Instance.new("Frame")
Overlay.Size = UDim2.new(1, 0, 1, 0); Overlay.BackgroundColor3 = C_BG
Overlay.BackgroundTransparency = 0.5; Overlay.BorderSizePixel = 0; Overlay.ZIndex = 0; Overlay.Parent = Window

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

local _, setP2Side = makeRowToggle(pTrade, "Add to Player 2 side", "off = your side (left) / on = right", false, function(on)
	OfferMode = on and "Player2" or "Player1"
end)
-- Every fresh trade starts on YOUR side again (fixes: a "fake" P2-side trade
-- left the toggle on, so the next real trade still filled the P2 side).
table.insert(onNewTrade, function() OfferMode = "Player1"; setP2Side(false) end)

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
	local _, rc = scrapeRealInventory()
	table.insert(lines, "real inventory slots found: " .. rc)
	Diag.Text = table.concat(lines, "\n")
	Diag.Visible = true
	-- also re-attempt the real fetch in the background
	task.spawn(applyRealData)
end)

-- Mirror the player's REAL in-game inventory into the trade. Open your
-- inventory/backpack so the game has rendered the slots, then tap Link.
makeRowButton(pSpawn, "Link real inventory", "show your real items — tap to add", "Link", C_GREEN, function()
	local inv, n = scrapeRealInventory()
	RealInv = inv
	renderInventory()
	CatLabel.Text = (n > 0)
		and ("real inventory linked: " .. n .. " item(s) — tap them in the trade")
		or "no real item slots found — open your inventory in-game, then Link again"
	CatLabel.TextColor3 = (n > 0) and C_GREEN or C_RED
end)

-- Add `amount` copies of a resolved catalog entry into the right inventory pane.
local function spawnEntry(it, amount)
	amount = math.max(1, math.floor(tonumber(amount) or 1))
	local list = (it.cat == "Pets") and SpawnedPets or SpawnedWeapons
	list[it.key] = (list[it.key] or 0) + amount
	renderInventory()
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
	SpawnMsg.Text = ("✓ %s  [%s]  → inventory  (x%d)"):format(it.name, tostring(it.rarity or "?"), total)
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
