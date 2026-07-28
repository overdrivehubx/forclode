--!nocheck
--[[
================================================================================
  MollyHub — SKIN DUMPER
================================================================================
  Pulls a weapon/skin table out of a script that is already running, and writes
  it out in the shape MollyHub's own skin map uses.

  The point: you do not have to defeat the obfuscator. Luraph protects the CODE,
  not the DATA. Once the script has run, its weapon table is an ordinary Lua
  table sitting in the same VM as this one, with plain strings in it — so we
  walk the garbage collector and take a copy. Nothing is decompiled and nothing
  is patched.

  How to use it:

    1. Run the obfuscated script first and let its menu finish loading. If its
       list of weapons only fills in when you open a tab, open that tab.
    2. Run this.
    3. Press SCAN. Every table that looks like a weapon list is scored and
       listed, biggest and most convincing first.
    4. Press a row to see what is actually in it.
    5. Press SAVE to write it to disk and to your clipboard.

  If the scan comes up empty, the strings are probably still encrypted and only
  decoded as each item is used. WATCH mode covers that case: it records what
  actually lands on your character as you equip things, which is the same route
  MollyHub's own "learn skins" takes.

  Nothing here is sent anywhere. It reads memory in your own client and writes
  files through your executor.
================================================================================
]]

local BRANCH = "https://raw.githubusercontent.com/overdrivehubx/forclode/"
	.. "claude/trading-ui-offline-harness-vxuc86/"

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

--== executor bits, each optional =============================================
local function grab(name)
	local f = rawget(_G, name)
	if type(f) == "function" then return f end
	if type(getgenv) == "function" then
		local ok, env = pcall(getgenv)
		if ok and type(env) == "table" and type(env[name]) == "function" then return env[name] end
	end
	local ok, v = pcall(function() return (loadstring or load)("return " .. name)() end)
	if ok and type(v) == "function" then return v end
	return nil
end
local GETGC = grab("getgc")
local WRITEFILE = grab("writefile")
local SETCLIP = grab("setclipboard")

--== what a weapon record looks like ==========================================
-- We do not know the other script's field names, so recognise the CONTENT: a
-- Roblox asset id is a long run of digits, and a weapon table is a lot of
-- entries whose values carry one or two of those.
local function digits(v)
	if type(v) == "number" then
		if v ~= v or v < 1e5 then return nil end          -- NaN, or too short to be an id
		return string.format("%d", math.floor(v))
	end
	if type(v) ~= "string" then return nil end
	local id = v:match("[Aa]sset[Ii][Dd]=(%d+)") or v:match("rbxassetid://(%d+)")
		or v:match("^(%d%d%d%d%d%d+)$")
	return id
end

-- Score one candidate table: how much does it look like "name -> skin"?
local function score(t)
	local entries, withId, named, sample = 0, 0, 0, nil
	local ok = pcall(function()
		for k, v in pairs(t) do
			entries = entries + 1
			if entries > 4000 then break end             -- do not walk something enormous
			if type(k) == "string" and #k > 1 and #k < 64 then named = named + 1 end
			local hit = false
			if type(v) == "table" then
				local fields = 0
				for _, vv in pairs(v) do
					fields = fields + 1
					if fields > 24 then break end
					if digits(vv) then hit = true end
				end
			elseif digits(v) then
				hit = true
			end
			if hit then
				withId = withId + 1
				if not sample then sample = { key = k, value = v } end
			end
		end
	end)
	if not ok or entries < 8 then return 0 end
	-- a real weapon map is mostly ids, and mostly keyed by name
	local idShare = withId / entries
	local nameShare = named / entries
	if idShare < 0.4 then return 0 end
	return math.floor(entries * (0.5 + idShare) * (0.5 + nameShare)), entries, withId, named, sample
end

--== the scan =================================================================
local found = {}

local function scan()
	found = {}
	if not GETGC then return nil, "this executor has no getgc, so memory cannot be read" end
	local objects
	local ok = pcall(function() objects = GETGC(true) end)
	if not ok or type(objects) ~= "table" then
		return nil, "getgc refused"
	end
	local seen = {}
	for _, o in pairs(objects) do
		if type(o) == "table" and not seen[o] then
			seen[o] = true
			local s, entries, withId, named, sample = score(o)
			if s > 0 then
				found[#found + 1] = {
					table = o, score = s, entries = entries,
					withId = withId, named = named, sample = sample,
				}
			end
		end
	end
	table.sort(found, function(a, b) return a.score > b.score end)
	return found
end

--== turning what we found into MollyHub's shape ==============================
-- Their field names are their own, so map by meaning: the first id that looks
-- like a mesh, the second like a texture, and any three numbers together like
-- a scale or a size.
local MESH_HINTS = { "mesh", "meshid", "model", "id", "asset" }
local TEX_HINTS = { "tex", "texture", "textureid", "image", "skin" }

local function looksLike(key, hints)
	key = tostring(key):lower()
	for _, h in ipairs(hints) do
		if key:find(h, 1, true) then return true end
	end
	return false
end

local function toRecord(value)
	if type(value) ~= "table" then
		local id = digits(value)
		return id and { mesh = id } or nil
	end
	local rec, ids = {}, {}
	for k, v in pairs(value) do
		local id = digits(v)
		if id then
			if looksLike(k, TEX_HINTS) and not rec.tex then rec.tex = id
			elseif looksLike(k, MESH_HINTS) and not rec.mesh then rec.mesh = id
			else ids[#ids + 1] = id end
		elseif type(v) == "number" then
			local lk = tostring(k):lower()
			if lk:find("scale") then rec.sx, rec.sy, rec.sz = v, v, v end
		elseif type(v) == "string" then
			local lv = v:lower()
			if lv == "gun" or lv == "knife" then rec.slot = (lv == "gun") and "Gun" or "Knife" end
		elseif typeof(v) == "Vector3" and not rec.sx then
			-- Their field might be called "sc", or "Sz", or nothing helpful at all,
			-- so take any three-number value as the size and work out what KIND it
			-- is the way the harness does: a mesh scale is one number three times,
			-- while a part size is three different ones.
			rec.sx, rec.sy, rec.sz = v.X, v.Y, v.Z
			local lo = math.min(v.X, v.Y, v.Z)
			local hi = math.max(v.X, v.Y, v.Z)
			local lk = tostring(k):lower()
			if lk:find("size") then rec.k = "size"
			elseif lk:find("scale") then rec.k = "scale"
			elseif lo > 0 and (hi - lo) / hi < 0.02 then rec.k = "scale"
			else rec.k = "size" end
		end
	end
	-- whatever was left over, in the order it was found
	for _, id in ipairs(ids) do
		if not rec.mesh then rec.mesh = id
		elseif not rec.tex then rec.tex = id end
	end
	return rec.mesh and rec or nil
end

local function toMeshMap(t)
	local out, n = {}, 0
	pcall(function()
		for k, v in pairs(t) do
			if type(k) == "string" then
				local rec = toRecord(v)
				if rec then
					out[k] = rec
					n = n + 1
				end
			end
		end
	end)
	return out, n
end

--== writing it out ===========================================================
local function serialise(map)
	local names = {}
	for k in pairs(map) do names[#names + 1] = k end
	table.sort(names)
	local parts = { "_G.MH_MeshMap = _G.MH_MeshMap or {}\nlocal M = _G.MH_MeshMap\n" }
	for _, name in ipairs(names) do
		local r = map[name]
		local bits = { string.format("mesh = %q", tostring(r.mesh)) }
		if r.tex then bits[#bits + 1] = string.format("tex = %q", tostring(r.tex)) end
		if r.sx then
			bits[#bits + 1] = string.format("sx = %s, sy = %s, sz = %s",
				tostring(r.sx), tostring(r.sy), tostring(r.sz))
		end
		if r.k then bits[#bits + 1] = string.format("k = %q", r.k) end
		if r.slot then bits[#bits + 1] = string.format("slot = %q", r.slot) end
		parts[#parts + 1] = string.format("M[%q] = { %s }", name, table.concat(bits, ", "))
	end
	return table.concat(parts, "\n")
end

local function save(map, count, tag)
	local lua = serialise(map)
	local json = "{}"
	pcall(function() json = HttpService:JSONEncode(map) end)
	local wrote = {}
	if WRITEFILE then
		pcall(function()
			WRITEFILE("MollyHub_skins_" .. tag .. ".lua", lua)
			wrote[#wrote + 1] = "MollyHub_skins_" .. tag .. ".lua"
		end)
		pcall(function()
			WRITEFILE("MollyHub_skins_" .. tag .. ".json", json)
			wrote[#wrote + 1] = "MollyHub_skins_" .. tag .. ".json"
		end)
	end
	if SETCLIP then pcall(SETCLIP, lua) end
	-- and straight into this session, so it can be used without a restart
	_G.MH_MeshMap = _G.MH_MeshMap or {}
	for k, v in pairs(map) do _G.MH_MeshMap[k] = v end
	return wrote, count
end

--== interface ================================================================
local okUI, UI = pcall(function()
	return loadstring(game:HttpGet(BRANCH .. "MollyUI.luau"))()
end)
if not okUI or type(UI) ~= "table" then
	warn("[MollyHub] the interface could not be downloaded")
	return
end

local Win = UI:CreateWindow({
	Title = "Skin Dumper", SubTitle = "read a weapon table out of memory",
	Badge = "MH", Front = true,
})
local T = Win:Tab({ Title = "Dump" })

T:Paragraph({
	Title = "How this works",
	Desc = "Run the other script first and let it finish loading. Luraph hides the "
		.. "code, not the data — once its table exists it is a plain Lua table in "
		.. "this same VM, so we copy it. Nothing is decompiled.",
})

local picked, listView
local function rows()
	local out = {}
	for i, c in ipairs(found) do
		local key = c.sample and tostring(c.sample.key) or "?"
		out[#out + 1] = {
			key = tostring(i),
			name = c.entries .. " entries  ·  " .. c.withId .. " with ids",
			sub = "first: " .. key:sub(1, 40),
			badges = { "score " .. c.score },
		}
		if i >= 25 then break end
	end
	return out
end

T:Button({
	Title = "Scan memory",
	Desc = "walks the collector for anything shaped like a weapon list",
	Style = "primary",
	Callback = function()
		local list, why = scan()
		if not list then
			return UI:Notify({ Title = "Cannot scan", Content = tostring(why), Duration = 8 })
		end
		listView:Set(rows(), #found .. " candidate table(s)")
		UI:Notify({
			Title = "Scan done",
			Content = #found > 0 and (#found .. " candidates, best has "
				.. found[1].entries .. " entries") or "nothing that looks like a weapon list",
			Duration = 6,
		})
	end,
})

listView = T:List({ Height = 220, Fill = true, Min = 140, Max = 380 })
listView:OnPick(function(it)
	picked = tonumber(it.key)
	local c = found[picked]
	if not c then return end
	local _, n = toMeshMap(c.table)
	listView:Select(it.key)
	UI:Notify({
		Title = "Candidate " .. it.key,
		Content = c.entries .. " entries, " .. n .. " of them turn into skins",
		Duration = 7,
	})
end)

T:Button({
	Title = "Save the selected table",
	Desc = "to a file, to the clipboard, and into this session",
	Callback = function()
		local c = found[picked or 1]
		if not c then
			return UI:Notify({ Title = "Nothing picked", Content = "scan, then choose a row" })
		end
		local map, n = toMeshMap(c.table)
		if n == 0 then
			return UI:Notify({ Title = "Nothing usable",
				Content = "no asset ids came out of that one", Duration = 7 })
		end
		local wrote = save(map, n, tostring(picked or 1))
		UI:Notify({
			Title = "Saved " .. n .. " skins",
			Content = (#wrote > 0 and table.concat(wrote, " and ") or "clipboard only")
				.. "  ·  also loaded into this session",
			Duration = 10,
		})
	end,
})

T:Button({
	Title = "Save every candidate",
	Desc = "when you cannot tell which one it is",
	Callback = function()
		local total, files = 0, 0
		for i, c in ipairs(found) do
			local map, n = toMeshMap(c.table)
			if n >= 8 then
				local wrote = save(map, n, tostring(i))
				total = total + n
				files = files + #wrote
			end
			if i >= 25 then break end
		end
		UI:Notify({
			Title = "Saved everything worth saving",
			Content = total .. " records across " .. files .. " file(s)",
			Duration = 10,
		})
	end,
})

--== watch mode ===============================================================
local W = Win:Tab({ Title = "Watch" })
W:Paragraph({
	Title = "When the scan finds nothing",
	Desc = "Some builds keep their strings encrypted until each one is used. Turn "
		.. "this on and equip weapons in the other script's menu: whatever lands on "
		.. "your character is recorded, one weapon per equip.",
})

local watching, watchCount = false, 0
local watchStatus = W:Paragraph({ Title = "Not watching", Desc = "nothing recorded yet" })

-- The character's own weapon display is where the truth ends up, whichever
-- script put it there. This is the same place MollyHub reads for its own skins.
local function displayOf(slot)
	local char = LocalPlayer.Character
	local ref = char and char:FindFirstChild("DisplayRef" .. slot)
	local part = ref and ref.Value
	if not part then return nil end
	local mesh = part:FindFirstChild("Mesh") or part:FindFirstChildWhichIsA("SpecialMesh")
	return part, mesh
end

local function readNow(slot)
	local part, mesh = displayOf(slot)
	if not part then return nil end
	local rec
	pcall(function()
		if mesh then
			rec = {
				mesh = tostring(mesh.MeshId):match("%d+"),
				tex = tostring(mesh.TextureId):match("%d+"),
				sx = mesh.Scale.X, sy = mesh.Scale.Y, sz = mesh.Scale.Z,
				k = "scale", slot = slot,
			}
		elseif part:IsA("MeshPart") then
			rec = {
				mesh = tostring(part.MeshId):match("%d+"),
				tex = tostring(part.TextureID):match("%d+"),
				sx = part.Size.X, sy = part.Size.Y, sz = part.Size.Z,
				k = "size", slot = slot,
			}
		end
	end)
	if rec and rec.mesh then return rec end
	return nil
end

local caught = {}
W:Toggle({
	Title = "Watch what gets equipped",
	Desc = "records a weapon each time the display changes",
	Callback = function(on)
		watching = on
		if not on then return end
		task.spawn(function()
			local lastGun, lastKnife
			while watching do
				task.wait(0.4)
				for slot, last in pairs({ Gun = lastGun, Knife = lastKnife }) do
					local rec = readNow(slot)
					if rec and rec.mesh ~= last then
						if slot == "Gun" then lastGun = rec.mesh else lastKnife = rec.mesh end
						-- named after whatever the game says is equipped
						local name = tostring(LocalPlayer:GetAttribute("Equipped" .. slot) or "")
						if name == "" then name = slot .. "_" .. rec.mesh end
						if not caught[name] then
							caught[name] = rec
							watchCount = watchCount + 1
							pcall(function()
								watchStatus:Set("Watching  ·  " .. watchCount
									.. " recorded, last was " .. name)
							end)
						end
					end
				end
			end
		end)
	end,
})
W:Button({
	Title = "Save what was watched",
	Style = "primary",
	Callback = function()
		local n = 0
		for _ in pairs(caught) do n = n + 1 end
		if n == 0 then
			return UI:Notify({ Title = "Nothing yet", Content = "equip something first" })
		end
		local wrote = save(caught, n, "watched")
		UI:Notify({
			Title = "Saved " .. n .. " skins",
			Content = (#wrote > 0 and table.concat(wrote, " and ") or "clipboard only"),
			Duration = 9,
		})
	end,
})

listView:Set({}, "press scan")
UI:Notify({
	Title = "Skin Dumper",
	Content = "run the other script first, then press Scan",
	Duration = 8,
})
