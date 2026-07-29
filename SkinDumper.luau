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
-- A THUMBNAIL URL is not a mesh. This is the mistake that cost a whole dump:
-- "http://www.roblox.com/Thumbs/Asset.ashx?...assetId=15666596216" is the
-- PICTURE the shop shows for a weapon, and reading the number out of it gave
-- 981 records that pointed at images. The one weapon whose real ids are known —
-- Gingerscope, mesh 15374602183, texture 15409041564 — has 15666596216 as its
-- Image, and that is exactly the number the old dump recorded. So a thumbnail
-- url is refused here, whatever field it sits in.
local function isThumb(v)
	if type(v) ~= "string" then return false end
	local l = v:lower()
	return l:find("thumbs", 1, true) ~= nil or l:find("asset.ashx", 1, true) ~= nil
		or l:find("assetid=", 1, true) ~= nil or l:find("rbxthumb", 1, true) ~= nil
end

local function digits(v)
	if type(v) == "number" then
		if v ~= v or v < 1e5 then return nil end          -- NaN, or too short to be an id
		return string.format("%d", math.floor(v))
	end
	if type(v) ~= "string" then return nil end
	if isThumb(v) then return nil end
	return v:match("rbxassetid://(%d+)") or v:match("^(%d%d%d%d%d%d+)$")
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
-- The scan walks every table in the VM, and its own bookkeeping is in there
-- too: the candidate list, and the list getgc handed back. Both came back as
-- "finds" and filled the report with our own output. Mark them and skip them.
local MINE = setmetatable({}, { __mode = "k" })
MINE[found] = true

local function scan()
	found = {}
	MINE[found] = true
	if not GETGC then return nil, "this executor has no getgc, so memory cannot be read" end
	local objects
	local ok = pcall(function() objects = GETGC(true) end)
	if not ok or type(objects) ~= "table" then
		return nil, "getgc refused"
	end
	MINE[objects] = true
	local seen = {}
	for _, o in pairs(objects) do
		if type(o) == "table" and not seen[o] and not MINE[o] and o ~= _G
			and o ~= rawget(_G, "MH_MeshMap") then
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

--== anchored scan ============================================================
-- Ranking tables by shape can pick the wrong one. It already did: the first
-- dump off this tool ranked the item CATALOG highest, and every id in it was
-- the item's ICON, so the weapons came out wrong. The cure is to look for a
-- table that holds an id we KNOW is a mesh — the one on your own weapon right
-- now, or Gingerscope's 15374602183, which was checked by hand against the
-- game — and take the table that contains it.

-- Every mesh id currently worn by your character, newest first. GLOBAL-ish.
local function meshOnMe()
	local out = {}
	pcall(function()
		local char = game:GetService("Players").LocalPlayer.Character
		if not char then return end
		for _, d in ipairs(char:GetDescendants()) do
			local id
			if d:IsA("SpecialMesh") or d:IsA("MeshPart") then id = tostring(d.MeshId) end
			local n = id and id:match("(%d%d%d%d%d+)")
			if n then out[#out + 1] = n end
		end
	end)
	return out
end

local function anchoredScan(want)
	found = {}
	MINE[found] = true
	if not GETGC then return nil, "this executor has no getgc, so memory cannot be read" end
	local id = tostring(want or ""):match("(%d+)")
	if not id then return nil, "type an asset id to look for" end
	local objects
	local ok = pcall(function() objects = GETGC(true) end)
	if not ok or type(objects) ~= "table" then return nil, "getgc refused" end
	MINE[objects] = true
	local function holds(v)
		if type(v) == "number" then return string.format("%d", math.floor(v)) == id end
		if type(v) == "string" then return v == id or v:match("(%d%d%d%d%d+)") == id end
		return false
	end
	local seen = {}
	for _, o in pairs(objects) do
		if type(o) == "table" and not seen[o] and not MINE[o] and o ~= _G
			and o ~= rawget(_G, "MH_MeshMap") then
			seen[o] = true
			local at, field
			local okw = pcall(function()
				for k, v in pairs(o) do
					if holds(v) then at, field = k, nil return end
					if type(v) == "table" then
						for k2, v2 in pairs(v) do
							if holds(v2) then at, field = k, k2 return end
						end
					end
				end
			end)
			if okw and at ~= nil then
				-- score() gives up on anything that is not already shaped like a
				-- weapon map, and then reports nothing. Count it ourselves, so a
				-- table that holds a real mesh id is never dropped for being an
				-- odd shape — that shape is exactly what we are trying to see.
				local entries, withId, named = 0, 0, 0
				pcall(function()
					for k, v in pairs(o) do
						entries = entries + 1
						if entries > 4000 then break end
						if type(k) == "string" then named = named + 1 end
						if digits(v) then
							withId = withId + 1
						elseif type(v) == "table" then
							for _, vv in pairs(v) do
								if digits(vv) then withId = withId + 1 break end
							end
						end
					end
				end)
				local sc = score(o)
				found[#found + 1] = {
					table = o, score = math.max(tonumber(sc) or 0, 1), entries = entries,
					withId = withId, named = named,
					sample = { key = at, value = o[at] },
					note = "holds " .. id .. " at [" .. tostring(at) .. "]"
						.. (field and ("." .. tostring(field)) or ""),
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
local MESH_HINTS = { "mesh", "model" }
local TEX_HINTS = { "tex", "texture", "skin" }
-- fields that hold a picture of the item, never anything you can wear
local ICON_HINTS = { "image", "icon", "thumb", "preview", "display" }

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
	local rec, ids, vecs = {}, {}, {}
	for k, v in pairs(value) do
		local id = digits(v)
		if id and looksLike(k, ICON_HINTS) then
			id = nil                                   -- a picture, not a skin
		end
		if id then
			-- mesh before texture: "TextureId" contains neither "mesh" nor "model",
			-- while "MeshId" must not be read as a texture just because pairs()
			-- reached it second
			if looksLike(k, MESH_HINTS) and not rec.mesh then rec.mesh = id
			elseif looksLike(k, TEX_HINTS) and not rec.tex then rec.tex = id
			else ids[#ids + 1] = id end
		elseif type(v) == "number" then
			local lk = tostring(k):lower()
			if lk:find("scale") then rec.sx, rec.sy, rec.sz = v, v, v end
		elseif type(v) == "string" then
			local lv = v:lower()
			if lv == "gun" or lv == "knife" then rec.slot = (lv == "gun") and "Gun" or "Knife" end
		elseif typeof(v) == "CFrame" then
			-- Where the weapon hangs on you, and how it sits in your hand. These
			-- are what make a swapped weapon look right rather than merely be the
			-- right mesh, and the harness reads both.
			local nums
			pcall(function() nums = { v:GetComponents() } end)
			if nums and #nums >= 12 then
				local lk = tostring(k):lower()
				if lk:find("grip") then rec.grip = nums
				elseif not rec.cf then rec.cf = nums end
			end
		elseif typeof(v) == "Vector3" then
			local lk = tostring(k):lower()
			if lk:find("offset") then
				rec.ox, rec.oy, rec.oz = v.X, v.Y, v.Z
			elseif lk:find("vertex") or lk:find("colou") then
				rec.vx, rec.vy, rec.vz = v.X, v.Y, v.Z
			else
				-- an unnamed three-number value: remember it and decide at the end,
				-- because Offset (0,0,0) and VertexColor (1,1,1) are Vector3 too and
				-- pairs() can reach either of them before the scale
				vecs[#vecs + 1] = { key = lk, v = v }
			end
		end
	end
	-- the scale, out of whatever three-number values had no helpful name
	if not rec.sx then
		local best
		for _, c in ipairs(vecs) do
			local v = c.v
			local zero = (v.X == 0 and v.Y == 0 and v.Z == 0)
			local one = (v.X == 1 and v.Y == 1 and v.Z == 1)
			if c.key:find("scale") or c.key:find("size") then best = c break end
			if not zero and not one and not best then best = c end
		end
		if not best then
			for _, c in ipairs(vecs) do
				if not (c.v.X == 0 and c.v.Y == 0 and c.v.Z == 0) then best = c break end
			end
		end
		if best then
			local v = best.v
			rec.sx, rec.sy, rec.sz = v.X, v.Y, v.Z
			local lo = math.min(v.X, v.Y, v.Z)
			local hi = math.max(v.X, v.Y, v.Z)
			if best.key:find("size") then rec.k = "size"
			elseif best.key:find("scale") then rec.k = "scale"
			elseif lo > 0 and (hi - lo) / hi < 0.02 then rec.k = "scale"
			else rec.k = "size" end
		end
	end
	-- whatever was left over, in the order it was found
	for _, id in ipairs(ids) do
		if not rec.mesh then rec.mesh = id
		elseif not rec.tex then rec.tex = id end
	end
	-- A texture that is its own mesh id is not a texture. It happens when the
	-- source keeps one id under two names, and shipping it makes the weapon
	-- render untextured — which looks exactly like the skin failing.
	if rec.tex == rec.mesh then rec.tex = nil end
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

--== finding it by SHAPE, not by a lucky id ===================================
-- Anchoring on an id only works if you already wear a weapon the other script
-- knows. Anchoring on the SHAPE does not: a weapon record is the only thing in
-- a game that carries an asset id AND a placement — a Scale, an Offset, a
-- CFrame, a Grip. The item catalog has ids and no geometry; a list of parts has
-- geometry and no ids. Nothing else in memory has both, per entry, hundreds of
-- times over.
local function shapeScan()
	found = {}
	MINE[found] = true
	if not GETGC then return nil, "this executor has no getgc, so memory cannot be read" end
	local objects
	local ok = pcall(function() objects = GETGC(true) end)
	if not ok or type(objects) ~= "table" then return nil, "getgc refused" end
	MINE[objects] = true
	local seen = {}
	for _, o in pairs(objects) do
		if type(o) == "table" and not seen[o] and not MINE[o] and o ~= _G
			and o ~= rawget(_G, "MH_MeshMap") then
			seen[o] = true
			local recs, entries, placed, sample = 0, 0, 0, nil
			pcall(function()
				for k, v in pairs(o) do
					entries = entries + 1
					if entries > 4000 then break end
					if type(k) == "string" and #k > 1 and #k < 64 and type(v) == "table" then
						local rec = toRecord(v)
						if rec then
							recs = recs + 1
							if rec.sx or rec.cf or rec.grip then placed = placed + 1 end
							if not sample then sample = { key = k, value = v } end
						end
					end
				end
			end)
			-- a handful of placed records is already more than a catalog can fake
			if placed >= 3 then
				found[#found + 1] = {
					table = o, score = placed * 10 + recs, entries = entries,
					withId = recs, named = recs, sample = sample,
					note = recs .. " weapon record(s), " .. placed .. " with a placement",
				}
			end
		end
	end
	table.sort(found, function(a, b) return a.score > b.score end)
	return found
end

--== describing a table we cannot convert =====================================
-- A candidate that will not turn into skins is still the most useful thing on
-- screen: its shape says whether it is a mesh list at all. So write out what is
-- actually in it, in plain text, rather than refusing to save anything.
local function brief(v, depth)
	local t = type(v)
	if t == "string" then
		if #v > 90 then return string.format("%q...", v:sub(1, 90)) end
		return string.format("%q", v)
	end
	if t == "number" or t == "boolean" or t == "nil" then return tostring(v) end
	if t == "userdata" or t == "vector" then
		local ok, tn = pcall(function() return typeof(v) end)
		return "<" .. (ok and tostring(tn) or t) .. " " .. tostring(v) .. ">"
	end
	if t ~= "table" then return "<" .. t .. ">" end
	if (depth or 0) >= 2 then return "{...}" end
	local bits, n = {}, 0
	pcall(function()
		for k, vv in pairs(v) do
			n = n + 1
			if n > 14 then bits[#bits + 1] = "..." break end
			bits[#bits + 1] = tostring(k) .. " = " .. brief(vv, (depth or 0) + 1)
		end
	end)
	return "{ " .. table.concat(bits, ", ") .. " }"
end

local function describe(list, limit)
	local parts = {
		"MollyHub - what these tables actually contain",
		"(" .. tostring(#list) .. " candidate(s); send this over and the right one can be read off it)",
		"",
	}
	for i, c in ipairs(list) do
		if i > (limit or 25) then break end
		local keyKind = "?"
		pcall(function()
			for k in pairs(c.table) do keyKind = type(k) break end
		end)
		parts[#parts + 1] = string.format("== candidate %d == %s entries, keys are %s, %s ids%s",
			i, tostring(c.entries or "?"), keyKind, tostring(c.withId or "?"),
			c.note and ("  |  " .. c.note) or "")
		local shown = 0
		pcall(function()
			for k, v in pairs(c.table) do
				shown = shown + 1
				if shown > 12 then break end
				parts[#parts + 1] = "   [" .. tostring(k) .. "] = " .. brief(v, 0)
			end
		end)
		parts[#parts + 1] = ""
	end
	return table.concat(parts, "\n")
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
		if r.ox then
			bits[#bits + 1] = string.format("ox = %s, oy = %s, oz = %s",
				tostring(r.ox), tostring(r.oy), tostring(r.oz))
		end
		if r.vx then
			bits[#bits + 1] = string.format("vx = %s, vy = %s, vz = %s",
				tostring(r.vx), tostring(r.vy), tostring(r.vz))
		end
		for _, f in ipairs({ "cf", "grip" }) do
			local t = r[f]
			if type(t) == "table" and #t >= 12 then
				local n = {}
				for i = 1, 12 do n[i] = tostring(t[i]) end
				bits[#bits + 1] = f .. " = { " .. table.concat(n, ", ") .. " }"
			end
		end
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
	return loadstring(game:HttpGet(BRANCH .. "MollyUI.luau?nc="
		.. tostring(os.time()) .. "-" .. tostring(math.random(1, 1000000000))))()
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
			sub = c.note or ("first: " .. key:sub(1, 40)),
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

T:Section({ Title = "Or look for an id you know is a mesh" })
T:Paragraph({
	Title = "Two ways past the item catalog",
	Desc = "By shape is the one to try first — a weapon record is the only thing "
		.. "carrying an asset id and a placement together, which no catalog does. "
		.. "By id is the fallback: put in a number you know IS a mesh, or leave the "
		.. "box empty to try Gingerscope's and whatever you are wearing.",
})

local anchorId = ""
T:Search({
	Prefix = "id",
	Placeholder = "asset id, or blank for the one you are wearing",
	Callback = function(v) anchorId = v end,
})
T:Button({
	Title = "Find a weapon table by its shape",
	Desc = "no id needed: looks for records that carry an asset id AND a placement",
	Style = "primary",
	Callback = function()
		local list, why = shapeScan()
		if not list then
			return UI:Notify({ Title = "Cannot scan", Content = tostring(why), Duration = 8 })
		end
		listView:Set(rows(), #found .. " table(s) shaped like a weapon list")
		UI:Notify({ Title = #found > 0 and "Found" or "Nothing shaped like one", Duration = 10,
			Content = #found > 0 and (found[1].note .. "  -  best of " .. #found)
				or "no table holds records with both an id and a placement. Run the "
					.. "other script first and let it finish loading." })
	end,
})

T:Button({
	Title = "Find the table holding it",
	Desc = "the id search: every id is tried and the results are merged",
	Callback = function()
		local tries = {}
		if tostring(anchorId):match("%d+") then
			tries[#tries + 1] = tostring(anchorId):match("(%d+)")
		else
			-- Gingerscope first: it is a SKIN mesh, so a skin list would hold it.
			-- The mesh you happen to be wearing is usually the default weapon,
			-- which a skin list has no reason to contain — searching only for
			-- that is why the last scan came back with nothing but lists of parts.
			tries[#tries + 1] = "15374602183"
			for _, id in ipairs(meshOnMe()) do tries[#tries + 1] = id end
		end
		local all, why = {}, nil
		for _, id in ipairs(tries) do
			local list, w = anchoredScan(id)
			why = w or why
			for _, c in ipairs(list or {}) do
				local dup = false
				for _, e in ipairs(all) do if e.table == c.table then dup = true break end end
				if not dup then all[#all + 1] = c end
			end
		end
		found = all
		MINE[found] = true
		table.sort(found, function(a, b) return (a.score or 0) > (b.score or 0) end)
		listView:Set(rows(), #found .. " table(s) across " .. #tries .. " id(s)")
		UI:Notify({ Title = #found > 0 and "Found" or "Nothing holds them", Duration = 10,
			Content = #found > 0 and (#found .. " table(s), best has "
				.. tostring(found[1].entries) .. " entries")
				or (why or ("tried " .. #tries .. " id(s) and nothing in memory holds any")) })
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
			-- not a name -> skin map. Save what it IS, which is the thing worth
			-- looking at, instead of leaving the button dead.
			local txt = describe({ c }, 1)
			local where = {}
			pcall(function()
				if WRITEFILE then
					WRITEFILE("MollyHub_table_" .. tostring(picked or 1) .. ".txt", txt)
					where[#where + 1] = "MollyHub_table_" .. tostring(picked or 1) .. ".txt"
				end
			end)
			pcall(function() if SETCLIP then SETCLIP(txt) end end)
			return UI:Notify({ Title = "Not a skin list - saved what it is", Duration = 12,
				Content = (#where > 0 and (where[1] .. " and the clipboard") or "the clipboard")
					.. "  -  send it over and the shape can be read off it" })
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
	Title = "Save what all of these look like",
	Desc = "plain text: the shape and a dozen entries from each, always works",
	Callback = function()
		if #found == 0 then
			return UI:Notify({ Title = "Nothing to describe", Content = "scan first" })
		end
		local txt = describe(found, 25)
		local where = {}
		pcall(function()
			if WRITEFILE then
				WRITEFILE("MollyHub_tables.txt", txt)
				where[#where + 1] = "MollyHub_tables.txt"
			end
		end)
		pcall(function() if SETCLIP then SETCLIP(txt) end end)
		UI:Notify({ Title = "Described " .. #found .. " table(s)", Duration = 12,
			Content = (#where > 0 and (where[1] .. " and the clipboard") or "the clipboard only") })
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
