--!nocheck
--[[
================================================================================
  MollyHub — TRADE + EQUIP SPAWNER
================================================================================
  The full sandbox with a front end built for it: a Trade screen (who you are
  with, the invitations, both sides of the deal, what goes on the table), the
  Spawner, the Skins page, and a Binds page where every action can take a key.

  The engine is the harness, loaded headless — it builds its own menu but keeps
  it off screen and publishes _G.MH_API. Nothing here reimplements the trade or
  spawn logic; it only drives it. TradeDebugHarness.luau is otherwise untouched
  and still works on its own as a fallback.
================================================================================
]]

local BRANCH = "https://raw.githubusercontent.com/overdrivehubx/forclode/"
	.. "claude/trading-ui-offline-harness-vxuc86/"
local RUBIS = "https://api.rubis.app/v2/scrap/D9CpDTMz8Hh4v1wA/raw"

-- GitHub keeps a raw file in a cache for minutes at a time, so a script updated
-- just now can arrive as an older build with nothing on screen to say so. A
-- query string GitHub ignores misses that cache, and the executor's too.
local function raw(file)
	return BRANCH .. file .. "?nc=" .. tostring(os.time()) .. "-" .. tostring(math.random(1, 1000000000))
end


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
local okSrc, src = pcall(function() return game:HttpGet(raw("TradeDebugHarness.luau")) end)
if not okSrc or type(src) ~= "string" or #src < 1024 then
	return fail("could not download the harness — check your connection")
end
-- Point the harness at our interface. The url is escaped into a literal pattern:
-- "." and friends would otherwise be wildcards, and a replace that quietly
-- matched the wrong thing is worse than one that does not match.
local literal = RUBIS:gsub("(%W)", "%%%1")
local swapped, n = src:gsub(literal, raw("MollyUI.luau"):gsub("%%", "%%%%"), 1)
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
local okUI, UI = pcall(function() return loadstring(game:HttpGet(raw("MollyUI.luau")))() end)
if not okUI or type(UI) ~= "table" then return fail("the interface could not be downloaded") end

local Win = UI:CreateWindow({
	Title = "MollyHub", SubTitle = "Murder Mystery 2  |  trade sandbox",
	Badge = "MM2", Front = true,
})

--== trade =====================================================================
-- One screen that reads like the table it drives: who you are trading with, the
-- two invitations, both sides of the deal with their accept state, and one way
-- to put an item on their side. No page of switches to hunt through.
local T = Win:Tab({ Title = "Trade" })

local partner = T:Player({
	Value = tostring((API.partner and API.partner()) or "Player2"),
	Desc = "tap to pick who you are trading with",
	Values = function() return (API.players and API.players()) or {} end,
	Callback = function(v)
		API.setPartner(v)
		UI:Notify({ Title = "Trading with", Content = tostring(v) })
	end,
})

-- One way in. The outgoing variant (you ask them, and wait) is still there —
-- it lives on the Binds page, where it is out of the way of the normal flow.
T:Button({ Title = "Start the trade", Style = "primary",
	Desc = "opens the trade window as if they had invited you",
	Callback = function() API.request(true) end })

T:Section({ Title = "The deal" })
local deal = T:Deal({})

-- what the table actually holds, rather than what we last pressed
local function pulse()
	if not API.state then return end
	local ok, s = pcall(API.state)
	if ok and type(s) == "table" then
		deal:Set(s)
		pcall(function() partner:Set(s.partner) end)
	end
	return ok and s or nil
end

-- The game refuses to accept an empty trade, so a tap can bounce back. Say why
-- rather than letting the card silently flip itself off again.
local function afterTap(want)
	task.delay(0.08, function()
		local s = pulse()
		if want and type(s) == "table" and not (s.youAccepted or s.theyAccepted) then
			UI:Notify({ Title = "Not yet", Content = "nothing is on the table to accept" })
		end
	end)
end
deal:OnYou(function(on) API.acceptP1(on) afterTap(on) end)
deal:OnThem(function(on)
	if API.acceptP2 then API.acceptP2(on) afterTap(on)
	else UI:Notify({ Title = "Trade", Content = "engine is out of date" }) end
end)
task.spawn(function()
	while true do
		task.wait(0.6)
		pcall(pulse)
	end
end)

-- Putting things on the table: yours on your side, anything on theirs.
local giveAmount = 1

local function catalogRows()
	local out = {}
	-- the WHOLE catalog: the picker has its own search, and half a catalog is
	-- worse than none — you cannot tell what is missing
	for _, it in ipairs(API.rank("", 0) or {}) do
		local d = API.item(it.key) or {}
		out[#out + 1] = { value = it.name, text = it.name,
			sub = tostring(d.Rarity or d.ItemType or "item"), image = d.Image }
	end
	return out
end

-- What you REALLY own, so a trade can be made of your own things and not only
-- of items conjured for it.
local function mineRows()
	local out = {}
	for _, e in ipairs((API.mine and API.mine()) or {}) do
		local d = API.item(e.key) or {}
		out[#out + 1] = { value = e.key, text = tostring(d.ItemName or e.key),
			sub = "x" .. tostring(e.count) .. "   " .. tostring(d.Rarity or d.ItemType or ""),
			image = d.Image }
	end
	return out
end

local function addMine()
	if not API.stage then return UI:Notify({ Title = "Trade", Content = "engine is out of date" }) end
	local rows = mineRows()
	if #rows == 0 then
		return UI:Notify({ Title = "Your items", Content = "the game has not handed over your inventory yet" })
	end
	T:Pick({ Title = "Your items", Values = rows, Noun = "item", Callback = function(v)
		local n = API.stage(v, giveAmount) or 0
		pulse()
		UI:Notify({ Title = (n > 0) and "On your side" or "Could not stage",
			Content = (n > 0) and (tostring(v) .. "  x" .. tostring(n))
				or "four stacks a side is the limit, same as the game" })
	end })
end

local function giveThem()
	T:Pick({ Title = "Give them", Values = catalogRows(), Noun = "item", Callback = function(v)
		API.spawn(v, giveAmount, true)
		pulse()
		UI:Notify({ Title = "On their side", Content = tostring(v) .. "  x" .. tostring(giveAmount) })
	end })
end

T:Actions({ Items = {
	{ Title = "Add your items", Desc = "from your real inventory", Callback = addMine },
	{ Title = "Give them an item", Desc = "anything in the game", Callback = giveThem },
} })
T:Slider({ Title = "How many", Min = 1, Max = 100, Default = 1,
	Callback = function(v) giveAmount = v end })

-- Overlay on a real trade is deliberately not shown. The engine still has it
-- (API.overlay), it is just off the menu for now.
T:Actions({ Height = 40, Items = {
	{ Title = "Clear the table", Callback = function()
		if API.clear then API.clear() pulse() UI:Notify({ Title = "Trade", Content = "both sides emptied" })
		else UI:Notify({ Title = "Trade", Content = "engine is out of date" }) end
	end },
	{ Title = "Terminate", Style = "danger", Callback = function() API.terminate() end },
} })

--== spawner ===================================================================
local S = Win:Tab({ Title = "Spawner" })

local query, filter, picked, amount = "", "All", nil, 1
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
	for _, it in ipairs(API.rank(query, 0) or {}) do
		if passes(it) then
			total = total + 1
			if #out < 120 then
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
listView = S:List({ Height = 260, Fill = true, Min = 140, Max = 430 })
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
-- Their side is filled from the Trade screen, so there is no switch here to
-- forget you left on.
local function spawnPicked()
	if not picked then return UI:Notify({ Title = "Spawner", Content = "pick an item first" }) end
	API.spawn(picked.name, amount, false)
	UI:Notify({ Title = "Spawned", Content = picked.name .. "  x" .. tostring(amount) })
end
S:Button({ Title = "Spawn selected", Style = "primary", Callback = spawnPicked })

--== skins =====================================================================
local K = Win:Tab({ Title = "Skins" })
K:Section({ Title = "Where skins come from" })
local function learnNearby()
	task.spawn(function()
		local learned, total = MH_learnMeshes()
		UI:Notify({ Title = "Skins", Content = "+" .. learned .. " learned, " .. total .. " known" })
	end)
end
local function dropSkin()
	UI:Notify({ Title = "Skins", Content = "restored " .. MH_restoreSkins() .. " mesh(es)" })
end
K:Button({ Title = "Learn from players nearby", Style = "primary", Callback = learnNearby })
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

K:Section({ Title = "What do I know?" })
K:Button({ Title = "Count the skins I have",
	Desc = "built in = shipped with the script, on disk = what you learned",
	Callback = function()
		UI:Notify({ Title = "Skins", Duration = 10, Content = MH_skinCounts() })
	end })
K:Button({ Title = "Check the selected item",
	Desc = "says whether this weapon has a mesh to wear",
	Callback = function()
		if not picked then return UI:Notify({ Title = "Skins", Content = "pick an item first" }) end
		UI:Notify({ Title = "Skins", Duration = 10, Content = MH_skinLookup(picked.key) })
	end })

K:Button({ Title = "Why did nothing change?",
	Desc = "the report from the last weapon you clicked in the inventory",
	Callback = function()
		UI:Notify({ Title = "Skins", Duration = 14,
			Content = tostring(_G.MH_LastEquip or "click a weapon in the game's inventory first") })
	end })

K:Section({ Title = "Undo" })
K:Actions({ Height = 40, Items = {
	{ Title = "Remove skin", Callback = dropSkin },
	{ Title = "Forget them all", Style = "danger", Callback = function()
		MH_restoreSkins()
		UI:Notify({ Title = "Skins", Content = "forgot " .. MH_forgetSkins() .. " entries" })
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
B:Keybind({ Title = "Start the trade", Default = "F", OnPress = function() API.request(true) end })
B:Keybind({ Title = "You invite them instead", Desc = "the outgoing request, if you want it",
	OnPress = function() API.request(false) end })
B:Keybind({ Title = "They accept", Default = "G",
	OnPress = function() if API.acceptP2 then API.acceptP2(true) pulse() end end })
B:Keybind({ Title = "You accept", Default = "H",
	OnPress = function() API.acceptP1(true) pulse() end })
B:Keybind({ Title = "Add your items", OnPress = addMine })
B:Keybind({ Title = "Give them an item", OnPress = giveThem })
B:Keybind({ Title = "Clear the table", Default = "J",
	OnPress = function() if API.clear then API.clear() pulse() end end })

B:Section({ Title = "Spawner and skins" })
B:Keybind({ Title = "Spawn the selected item", Default = "K", OnPress = spawnPicked })
B:Keybind({ Title = "Learn skins nearby", OnPress = learnNearby })
B:Keybind({ Title = "Remove skin", OnPress = dropSkin })

--== go ========================================================================
refresh()
pulse()

task.spawn(function()
	local seen = select(2, rows())
	for _ = 1, 12 do
		task.wait(1.5)
		local now = select(2, rows())
		if now ~= seen then seen = now refresh() end
	end
end)
