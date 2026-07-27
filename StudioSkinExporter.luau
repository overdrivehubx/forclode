--[[
================================================================================
  MollyHub — SKIN EXPORTER FOR ROBLOX STUDIO
================================================================================
  What it is for
  --------------
  The harness learns a weapon's mesh, texture and scale by wearing the item and
  reading them off your own body — which only works for items the server agrees
  you own. Everything else stays unknown.

  A place file opened in Studio has all of them sitting there in plain sight.
  Mesh and texture assets render on ANY account (only MODEL assets are
  ownership-gated), so ids read here work in the live game.

  You cannot open the real MM2 in Studio — it is copylocked. This needs a place
  file you can actually open.

  How to use it
  -------------
  Either way works:

  A. View -> Command Bar, paste this whole file in, press Enter. It writes
     ServerStorage.MH_MeshMap_export — open that and copy everything.
  B. Put it in ServerScriptService as a Script and press Play. Studio will not
     let a running script write another script's source, so it prints the table
     to Output instead — select it all there and copy.

  Then paste what you copied over the _G.MH_MeshMap = { ... } table near the top
  of TradeDebugHarness.luau.

  Hand-written entries always beat learned ones, so anything exported here wins
  over whatever the in-game learner picked up.

  Reads only. It creates one ModuleScript and changes nothing else.
================================================================================
]]

local ServerStorage = game:GetService("ServerStorage")

-- The place's own item database, so exported skins are keyed the way the game
-- keys them rather than by whatever the model happens to be called.
local DB
pcall(function()
	local d = game:GetService("ReplicatedStorage"):FindFirstChild("Database")
	local sync = d and d:FindFirstChild("Sync")
	local item = sync and sync:FindFirstChild("Item")
	if item then DB = require(item) end
end)

local byName = {}
if type(DB) == "table" then
	for k, v in pairs(DB) do
		if type(v) == "table" then
			local lk = tostring(k):lower()
			byName[lk] = byName[lk] or k
			if v.ItemName then
				local ln = tostring(v.ItemName):lower()
				byName[ln] = byName[ln] or k
			end
		end
	end
end

-- Never the first run of digits: an icon url looks like "...width=250...assetId=123",
-- so the first number is the image width. Prefer the id parameter, else longest.
local function assetId(s)
	local t = tostring(s or "")
	local id = t:match("[Aa]sset[Ii][Dd]=(%d+)") or t:match("[?&]id=(%d+)")
		or t:match("rbxassetid://(%d+)")
	if id then return id end
	local best = ""
	for run in t:gmatch("%d+") do
		if #run > #best then best = run end
	end
	return best
end

-- The item a mesh belongs to: itself, or the nearest container named after one.
local function keyFor(inst)
	local node = inst
	for _ = 1, 5 do
		if not node then break end
		local hit = byName[tostring(node.Name):lower()]
		if hit then return hit end
		node = node.Parent
	end
	return nil
end

local function cfList(cf)
	local c = { cf:GetComponents() }
	for i, v in ipairs(c) do c[i] = string.format("%.6g", v) end
	return "{ " .. table.concat(c, ", ") .. " }"
end

local out, seen, meshes, parts = {}, {}, 0, 0

for _, d in ipairs(game:GetDescendants()) do
	local isSM = d:IsA("SpecialMesh")
	local isMP = d:IsA("MeshPart")
	if isSM or isMP then
		local key = keyFor(d)
		if key and not seen[key] then
			local host = isSM and d.Parent or d
			local mesh = assetId(d.MeshId)
			if mesh ~= "" and host and host:IsA("BasePart") then
				seen[key] = true
				if isSM then meshes = meshes + 1 else parts = parts + 1 end

				local fields = {}
				-- the readable name goes in too, so the table can be eyeballed
				local disp = DB and DB[key] and DB[key].ItemName
				if disp then fields[#fields + 1] = string.format("name = %q", tostring(disp)) end
				fields[#fields + 1] = string.format('mesh = "%s"', mesh)
				local tex = assetId(isSM and d.TextureId or d.TextureID)
				if tex ~= "" then fields[#fields + 1] = string.format('tex = "%s"', tex) end

				if isSM then
					-- SpecialMesh.Scale is a MULTIPLIER over the mesh
					fields[#fields + 1] = string.format('sx = %.6g, sy = %.6g, sz = %.6g, k = "scale"',
						d.Scale.X, d.Scale.Y, d.Scale.Z)
					fields[#fields + 1] = string.format("ox = %.6g, oy = %.6g, oz = %.6g",
						d.Offset.X, d.Offset.Y, d.Offset.Z)
					fields[#fields + 1] = string.format("vx = %.6g, vy = %.6g, vz = %.6g",
						d.VertexColor.X, d.VertexColor.Y, d.VertexColor.Z)
				else
					-- MeshPart.Size is ABSOLUTE studs, which is a different thing
					fields[#fields + 1] = string.format('sx = %.6g, sy = %.6g, sz = %.6g, k = "size"',
						d.Size.X, d.Size.Y, d.Size.Z)
				end

				local slot = (DB and DB[key] and DB[key].ItemType) or nil
				if slot == "Gun" or slot == "Knife" then
					fields[#fields + 1] = string.format('slot = "%s"', slot)
				end

				-- where it sits on the body, and how it sits in the hand
				local at = host:FindFirstChild("Attachment")
				if at and at:IsA("Attachment") then
					fields[#fields + 1] = "cf = " .. cfList(at.CFrame)
					fields[#fields + 1] = 'an = "Attachment"'
				end
				local tool = host:FindFirstAncestorWhichIsA("Tool")
				if tool then fields[#fields + 1] = "grip = " .. cfList(tool.Grip) end

				out[#out + 1] = string.format("\t[%q] = { %s },", key, table.concat(fields, ", "))
			end
		end
	end
end

table.sort(out)

local body = "-- exported from " .. game.Name .. " by StudioSkinExporter\nreturn {\n"
	.. table.concat(out, "\n") .. "\n}\n"

-- From the Command Bar we can hand the result over as a script to copy from.
-- A script running in Play mode cannot write another script's source, so fall
-- back to printing it line by line — Output keeps whole lines, so it survives
-- select-all and copy.
local wrote = pcall(function()
	local old = ServerStorage:FindFirstChild("MH_MeshMap_export")
	if old then old:Destroy() end
	local mod = Instance.new("ModuleScript")
	mod.Name = "MH_MeshMap_export"
	mod.Source = body
	mod.Parent = ServerStorage
	if mod.Source ~= body then error("source not writable here") end
end)

print(("[MollyHub] exported %d skins (%d SpecialMesh, %d MeshPart)")
	:format(#out, meshes, parts))
if wrote then
	print("[MollyHub] open ServerStorage.MH_MeshMap_export and copy it")
else
	print("[MollyHub] copy everything between the markers below")
	print("---------------- 8< ---------------- MH_MeshMap ---------------- 8< ----")
	for line in body:gmatch("[^\n]+") do print(line) end
	print("---------------- 8< ---------------- end ----------------------- 8< ----")
end
if #out == 0 then
	warn("[MollyHub] nothing matched. Either this place has no item database at "
		.. "ReplicatedStorage.Database.Sync.Item, or its weapon models are not named "
		.. "after their items — say so and the matching can be widened.")
end
