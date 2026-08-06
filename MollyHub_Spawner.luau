--!nocheck
--[[
================================================================================
  MollyHub - EQUIP SPAWNER
================================================================================
  Weapons only. Type or pick a name, spawn it into your inventory, then equip it
  from the game's OWN inventory - and it appears on you as the game builds it:
  the mesh, the texture, the scope, the decals, the particles, the chroma.

  The engine underneath is MollySkins, which does two things differently from
  everything we tried before:

    * it POLLS ProfileData.Weapons.Equipped rather than listening for a signal,
      because MM2's inventory writes that table directly and never raises one;
    * it HIDES the real weapon and welds a rebuilt copy in its place, rather
      than repainting one mesh, because a weapon is a whole model.

  All of it is on your screen only.
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
		gui.Name = "MollyHubError"
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
		local f = Instance.new("TextLabel")
		f.Size = UDim2.fromOffset(460, 110)
		f.Position = UDim2.new(0.5, -230, 0, 60)
		f.BackgroundColor3 = Color3.fromRGB(24, 16, 20)
		f.BorderSizePixel = 0
		f.TextColor3 = Color3.fromRGB(255, 170, 170)
		f.Font = Enum.Font.Code
		f.TextSize = 14
		f.TextWrapped = true
		f.Text = "  [MollyHub] " .. msg
		f.Parent = gui
		Instance.new("UICorner", f).CornerRadius = UDim.new(0, 10)
	end)
end

--== engine ====================================================================
-- The weapon data is a megabyte on its own, so it is a separate download and is
-- kept for the session: opening the spawner twice does not fetch it twice.
_G.MH_MeshesURL = raw("MollyMeshes.luau")
local okSkins, Skins = pcall(function()
	return loadstring(game:HttpGet(raw("MollySkins.luau")))()
end)
if not okSkins or type(Skins) ~= "table" then
	return fail("the skin engine could not be downloaded - check your connection")
end
if not Skins.ProfileData then
	return fail("could not reach the game's own inventory - are you in MM2?")
end
Skins.start()

--== interface =================================================================
local okUI, UI = pcall(function() return loadstring(game:HttpGet(raw("MollyUI.luau")))() end)
if not okUI or type(UI) ~= "table" then return fail("the interface could not be downloaded") end

Skins.Status = function(text)
	UI:Notify({ Title = "Skins", Content = tostring(text), Duration = 4 })
end

local Win = UI:CreateWindow({
	Title = "Item Spawner", SubTitle = "Murder Mystery 2", Badge = "MM2", Front = true,
})

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
	hero:Set({
		image = it.image, name = it.name, tag = info.ItemType or "item",
		meta = "Original: " .. tostring(it.key),
		sub = table.concat({ tostring(info.Rarity or "?"), tostring(info.ItemType or "?"),
			Skins.has(it.key) and "wearable" or "no skin data" }, "  |  "),
	})
	listView:Select(it.key)
	refresh()
end

S:Search({ Prefix = "find", Placeholder = "Search by name or original id...",
	Callback = function(v) query = v refresh() end })
S:Chips({ Values = { "All", "Guns", "Knives", "Chroma", "Wearable" }, Value = "All",
	Callback = function(v) filter = v refresh() end })
hero = S:Hero({})
listView = S:List({ Height = 300, Fill = true, Min = 150, Max = 460 })
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

S:Button({ Title = "Spawn selected", Style = "primary", Callback = spawnPicked })
S:Button({ Title = "Spawn and wear it now",
	Desc = "equips it for you instead of waiting for the inventory",
	Callback = wearPicked })

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
local B = Win:Tab({ Title = "Binds" })
B:Section({ Title = "Everything with a key" })
B:Keybind({ Title = "Show or hide the menu", Default = "RightShift",
	OnPress = function() Win:Toggle() end })
B:Keybind({ Title = "Spawn the selected item", Default = "K", OnPress = spawnPicked })
B:Keybind({ Title = "Spawn and wear it", Default = "L", OnPress = wearPicked })
B:Keybind({ Title = "Take the skin off", OnPress = function() Skins.clearAll() end })

--== go ========================================================================
refresh()
UI:Notify({ Title = "Spawner", Duration = 6,
	Content = known .. " weapons ready, " .. full .. " of them whole models" })
