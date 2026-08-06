--!nocheck
--[[
================================================================================
  MollySkins - wearing a weapon you do not own
================================================================================
  Ported from a build that works, and the two things that make it work are worth
  saying out loud, because our own attempts got both of them wrong.

  1. HOW AN EQUIP IS NOTICED. MM2's inventory does not call
     EquipService.EquipItem. It writes ProfileData.Weapons.Equipped and fires the
     remote itself, so EquippedChanged never fires and anything hooked to it
     never hears. This POLLS ProfileData.Weapons.Equipped instead - every equip
     path writes there, whichever inventory the game happens to be using.

  2. HOW A WEAPON IS SHOWN. Not by repainting the mesh the game already put on
     you: a weapon is a whole model - scope, blade, decals, particles, lights -
     and one mesh id cannot be any of that. The real display is HIDDEN (locally)
     and a rebuilt copy is welded in its place, from data scraped out of the
     game itself.

  The build happens in two phases on purpose. Creating a MeshPart yields, and by
  the time it comes back the arm has moved; so phase one creates the tree and
  phase two - synchronous, from a freshly read CFrame - places and welds it.
  Doing it in one pass is what leaves a weapon floating where your hand used to
  be.

  Client-side only, as everything here is: nobody else sees any of it.
================================================================================
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local InsertService     = game:GetService("InsertService")
local LocalPlayer       = Players.LocalPlayer

local S = {}
S.PollRate = 0.1
S.HideOriginal = true
S.Status = nil            -- set to a function(text, colour) to hear about it

--== the game's own modules ====================================================
local ClientServices = ReplicatedStorage:WaitForChild("ClientServices", 10)
local EquipService, ProfileData, WeaponDB, InvDataChanged

pcall(function() EquipService = require(ClientServices:WaitForChild("EquipService", 10)) end)
pcall(function()
	ProfileData = require(ReplicatedStorage:WaitForChild("Modules", 10)
		:WaitForChild("ProfileData", 10))
end)
pcall(function()
	local Sync = require(ReplicatedStorage:WaitForChild("Database", 10):WaitForChild("Sync", 10))
	WeaponDB = Sync.Weapons or Sync.Item
end)
pcall(function()
	InvDataChanged = ReplicatedStorage:WaitForChild("Remotes", 10)
		:WaitForChild("Inventory", 10):WaitForChild("InventoryDataChanged", 10)
end)

S.EquipService, S.ProfileData, S.WeaponDB = EquipService, ProfileData, WeaponDB

--== the weapon data ===========================================================
-- injected (tests, or a script that already has it) or fetched once
local MESHES = _G.MH_Meshes
if type(MESHES) ~= "table" then
	local url = _G.MH_MeshesURL
	if type(url) == "string" then
		local ok, src = pcall(function() return game:HttpGet(url) end)
		if ok and type(src) == "string" and #src > 1000 then
			local fn = loadstring(src)
			if fn then
				local ok2, data = pcall(fn)
				if ok2 and type(data) == "table" then MESHES = data end
			end
		end
	end
end
if type(MESHES) ~= "table" then MESHES = {} end
_G.MH_Meshes = MESHES
S.Meshes = MESHES

local function say(text, colr)
	if type(S.Status) == "function" then pcall(S.Status, text, colr) end
end

--== helpers ===================================================================
local function trimAsset(v)
	if type(v) == "string" then return (v:gsub("^%s+", ""):gsub("%s+$", "")) end
	return v
end

local function applyProps(inst, props, skip)
	for k, v in pairs(props or {}) do
		if not (skip and skip[k]) then
			if k == "MeshId" or k == "TextureId" or k == "TextureID" or k == "Texture" then
				v = trimAsset(v)
			end
			pcall(function() inst[k] = v end)
		end
	end
end

-- The string signature of CreateMeshPartAsync is the one every executor takes;
-- the Content-object form is newer and not everywhere. A plain Part with a
-- SpecialMesh is the fallback when the call is missing altogether.
local function createMeshPart(props)
	local meshId = trimAsset(props.MeshId or "")
	local size = props.Size or Vector3.new(1, 1, 1)
	local part
	pcall(function()
		part = InsertService:CreateMeshPartAsync(meshId,
			Enum.CollisionFidelity.Box, Enum.RenderFidelity.Precise)
	end)
	if part then
		pcall(function() part.Size = size end)
		return part
	end
	local p = Instance.new("Part")
	p.Size = size
	local sm = Instance.new("SpecialMesh")
	sm.MeshType = Enum.MeshType.FileMesh
	pcall(function() sm.MeshId = meshId end)
	pcall(function() sm.TextureId = trimAsset(props.TextureID or "") end)
	sm.Parent = p
	return p
end

--== chroma ====================================================================
local CHROMA = {
	Color3.fromRGB(255, 0, 0), Color3.fromRGB(255, 255, 0), Color3.fromRGB(0, 255, 0),
	Color3.fromRGB(0, 255, 255), Color3.fromRGB(0, 0, 255), Color3.fromRGB(255, 0, 255),
}
local CHROMA_FLASH_RATE = 1.8
local CHROMA_LAYER = "rbxassetid://18363392181"   -- MM2's own neutral chroma sheet

local function chromaColor(t)
	local n = #CHROMA
	local phase = t % n
	local i = math.floor(phase)
	return CHROMA[i + 1]:Lerp(CHROMA[((i + 1) % n) + 1], phase - i)
end

local function isChroma(name, data)
	if data.Meta and data.Meta.Chroma == true then return true end
	return tostring(name):sub(-6) == "Chroma"
end

-- Bulbs snap between colours; a garland or a strip slides through them. The
-- scraped data says which is which; without tags, only Neon parts flash and only
-- a decal named chroma cycles, so a green tree stays a green tree.
local function startChroma(overlay)
	local flash, decals, other = {}, {}, {}
	local tagged = false
	for _, d in ipairs(overlay:GetDescendants()) do
		local role = d:GetAttribute("MM2Chroma")
		if role then
			tagged = true
			if role == "part" then
				flash[#flash + 1] = d
			elseif role == "decal" and d:IsA("Decal") then
				pcall(function() d.Texture = CHROMA_LAYER end)
				decals[#decals + 1] = d
			elseif role == "fire" then
				other[#other + 1] = d
			end
		end
	end
	if not tagged then
		for _, d in ipairs(overlay:GetDescendants()) do
			if d:IsA("BasePart")
				and (d.Material == Enum.Material.Neon or d.Name:lower():find("light")) then
				flash[#flash + 1] = d
			elseif d:IsA("Decal") and d.Name:lower():find("chroma") then
				decals[#decals + 1] = d
			elseif d:IsA("Fire") then
				other[#other + 1] = d
			end
		end
		if #decals == 0 then other[#other + 1] = overlay end
	end
	if #flash == 0 and #decals == 0 and #other == 0 then return nil end
	return RunService.Heartbeat:Connect(function()
		local now = os.clock()
		local col = chromaColor(now)
		for _, s in ipairs(decals) do s.Color3 = col end
		for _, s in ipairs(other) do
			if s:IsA("Fire") then s.Color = col elseif s:IsA("BasePart") then s.Color = col end
		end
		local step = math.floor(now * CHROMA_FLASH_RATE)
		for i, b in ipairs(flash) do
			b.Color = CHROMA[((step + i - 1) % #CHROMA) + 1]
		end
	end)
end

--== building the copy =========================================================
-- joints are rebuilt as welds at the end, so the scraped ones are skipped
local STRUCTURAL = {
	WeldConstraint = true, Weld = true, Motor6D = true, RigidConstraint = true,
	Bone = true, Snap = true, ManualWeld = true, Rotate = true, RotateP = true,
	RotateV = true,
}
local PARTICLES = {
	ParticleEmitter = true, Fire = true, Smoke = true, Sparkles = true,
	PointLight = true, SpotLight = true, SurfaceLight = true,
}

local function chromaTag(inst, node)
	if not (inst and node.Tags) then return end
	for _, t in ipairs(node.Tags) do
		local r = (t == "ChromaPart" and "part")
			or (t == "ChromaDecal" and "decal")
			or (t == "ChromaFire" and "fire") or nil
		if r then pcall(function() inst:SetAttribute("MM2Chroma", r) end) end
	end
end

local function instantiate(node)
	local cls = node.Class
	if STRUCTURAL[cls] then return nil end
	local inst
	if cls == "MeshPart" then
		inst = createMeshPart(node.Props)
		applyProps(inst, node.Props, { MeshId = true, Size = true, RelCF = true, CanCollide = true })
	else
		local ok, res = pcall(Instance.new, cls)
		if not ok or not res then return nil end
		inst = res
		applyProps(inst, node.Props, { RelCF = true })
	end
	chromaTag(inst, node)
	return inst
end

-- PHASE ONE. Creates the tree; may yield on any MeshPart. Nothing is placed or
-- welded here, because where the hand is now is not where it will be when this
-- returns.
local function rebuildTree(node, parentInst, root, idToInst, parts, deferred)
	for _, child in ipairs(node.Children or {}) do
		local inst = instantiate(child)
		if inst then
			idToInst[child.Id] = inst
			if inst:IsA("BasePart") then
				inst.Anchored, inst.CanCollide = false, false
				inst.CanQuery, inst.CanTouch, inst.Massless = false, false, true
				parts[#parts + 1] = { inst = inst, relcf = child.Props.RelCF }
				inst.Parent = root
				rebuildTree(child, inst, root, idToInst, parts, deferred)
			elseif inst:IsA("Attachment") then
				if child.Props.RelCF then pcall(function() inst.CFrame = child.Props.RelCF end) end
				inst.Parent = root
				rebuildTree(child, inst, root, idToInst, parts, deferred)
			elseif inst:IsA("Beam") or inst:IsA("Trail") then
				inst.Parent = parentInst
				deferred[#deferred + 1] = { inst = inst, a0 = child.Att0, a1 = child.Att1 }
				rebuildTree(child, inst, root, idToInst, parts, deferred)
			else
				inst.Parent = parentInst
				rebuildTree(child, inst, root, idToInst, parts, deferred)
			end
		else
			rebuildTree(child, parentInst, root, idToInst, parts, deferred)
		end
	end
end

local function buildFull(data)
	local rn = data.Model
	if not rn then return nil end
	local root
	if rn.Class == "MeshPart" then
		root = createMeshPart(rn.Props)
		applyProps(root, rn.Props, { MeshId = true, Size = true, RelCF = true, CanCollide = true })
	else
		root = Instance.new("Part")
		applyProps(root, rn.Props, { RelCF = true, CanCollide = true })
	end
	chromaTag(root, rn)
	root.Anchored, root.CanCollide = false, false
	root.CanQuery, root.CanTouch, root.Massless = false, false, true
	local idToInst = { [rn.Id] = root }
	local parts, deferred = {}, {}
	rebuildTree(rn, root, root, idToInst, parts, deferred)
	for _, d in ipairs(deferred) do
		if d.a0 and idToInst[d.a0] then pcall(function() d.inst.Attachment0 = idToInst[d.a0] end) end
		if d.a1 and idToInst[d.a1] then pcall(function() d.inst.Attachment1 = idToInst[d.a1] end) end
	end
	return { root = root, parts = parts }
end

local function buildFlat(data)
	local root, meshes, decals, effects = nil, {}, {}, {}
	for _, e in ipairs(data.Display or {}) do
		if e.Path == "(root)" then root = e
		elseif e.Class == "SpecialMesh" then meshes[#meshes + 1] = e
		elseif e.Class == "Decal" or e.Class == "Texture" then decals[#decals + 1] = e
		elseif PARTICLES[e.Class] then effects[#effects + 1] = e end
	end
	if not root then return nil end
	local part
	if root.Class == "MeshPart" then
		part = createMeshPart(root.Props)
		applyProps(part, root.Props, { MeshId = true, Size = true, CanCollide = true })
	else
		part = Instance.new("Part")
		part.Size = root.Props.Size or Vector3.new(1, 1, 1)
		applyProps(part, root.Props, { Size = true, CanCollide = true })
		for _, m in ipairs(meshes) do
			local sm = Instance.new("SpecialMesh")
			sm.MeshType = Enum.MeshType.FileMesh
			applyProps(sm, m.Props)
			sm.Parent = part
		end
	end
	part.Anchored, part.CanCollide = false, false
	part.CanQuery, part.CanTouch, part.Massless = false, false, true
	for _, d in ipairs(decals) do
		local dc = Instance.new("Decal")
		applyProps(dc, d.Props)
		dc.Parent = part
	end
	for _, e in ipairs(effects) do
		local ok, inst = pcall(Instance.new, e.Class)
		if ok and inst then applyProps(inst, e.Props) inst.Parent = part end
	end
	return { root = part, parts = {} }
end

local function buildAny(data)
	if data.Model then return buildFull(data) end
	if data.Display then return buildFlat(data) end
	return nil
end

-- PHASE TWO. Synchronous, from a CFrame read a moment ago, so nothing lands
-- where the arm used to be.
local function finalize(built, targetCF)
	local root = built.root
	pcall(function() root.CFrame = targetCF end)
	for _, p in ipairs(built.parts) do
		if p.relcf then pcall(function() p.inst.CFrame = targetCF * p.relcf end) end
		local w = Instance.new("WeldConstraint")
		w.Part0, w.Part1 = p.inst, root
		w.Parent = p.inst
	end
	return root
end

local function targetMeshId(data)
	if data.Model then
		local rn = data.Model
		if rn.Class == "MeshPart" then return trimAsset(rn.Props.MeshId or "") end
		for _, c in ipairs(rn.Children or {}) do
			if c.Class == "SpecialMesh" then return trimAsset(c.Props.MeshId or "") end
		end
		return ""
	end
	for _, e in ipairs(data.Display or {}) do
		if e.Path == "(root)" and e.Class == "MeshPart" then
			return trimAsset(e.Props.MeshId or "")
		end
		if e.Class == "SpecialMesh" then return trimAsset(e.Props.MeshId or "") end
	end
	return ""
end

local function baseMeshId(base)
	if not base then return "" end
	if base:IsA("MeshPart") then return trimAsset(base.MeshId or "") end
	local sm = base:FindFirstChildWhichIsA("SpecialMesh", true)
	return sm and trimAsset(sm.MeshId or "") or ""
end

--== hiding what is really there ===============================================
local function hideInto(list, inst)
	if not S.HideOriginal then return end
	if inst:IsA("BasePart") or inst:IsA("Decal") then
		list[#list + 1] = { inst = inst, prop = "Transparency", val = inst.Transparency }
		pcall(function() inst.Transparency = 1 end)
	elseif inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam")
		or inst:IsA("Fire") or inst:IsA("Smoke") or inst:IsA("Sparkles") then
		list[#list + 1] = { inst = inst, prop = "Enabled", val = inst.Enabled }
		pcall(function() inst.Enabled = false end)
	end
end

local function restore(hidden)
	for _, h in ipairs(hidden or {}) do pcall(function() h.inst[h.prop] = h.val end) end
end

--== the weapon hanging on you (lobby) =========================================
local function char() return LocalPlayer.Character end

local function displayValue(slot)
	local c = char()
	if not c then return nil end
	local ref = c:FindFirstChild("DisplayRef" .. slot)
	return ref and ref.Value or nil
end

local function waitDisplay(slot, timeout)
	local deadline = os.clock() + (timeout or 1)
	while os.clock() < deadline do
		local v = displayValue(slot)
		if v then return v end
		task.wait(0.05)
	end
	return displayValue(slot)
end

local state, lastApplied, token = {}, {}, {}

local function cleanup(slot)
	local st = state[slot]
	if not st then return end
	if st.chroma then pcall(function() st.chroma:Disconnect() end) end
	if st.overlay then pcall(function() st.overlay:Destroy() end) end
	restore(st.hidden)
	state[slot] = nil
end

-- A token per slot: an equip that arrives while an earlier build is still
-- yielding must win, and the earlier one must throw its work away.
function S.apply(slot, name)
	if state[slot] and lastApplied[slot] == name and name ~= nil then return end
	token[slot] = (token[slot] or 0) + 1
	local mine = token[slot]
	cleanup(slot)
	local data = name and MESHES[name]
	if not data then lastApplied[slot] = name return end
	lastApplied[slot] = name
	local base = displayValue(slot) or waitDisplay(slot, 1.5)
	if token[slot] ~= mine then return end
	if not base then
		say("no " .. slot .. " on show - equip a normal one first")
		return
	end
	if baseMeshId(base) == targetMeshId(data) and baseMeshId(base) ~= "" then return end
	local hidden = {}
	hideInto(hidden, base)
	for _, d in ipairs(base:GetDescendants()) do hideInto(hidden, d) end
	local built = buildAny(data)
	if not built or not built.root or token[slot] ~= mine or not base.Parent then
		restore(hidden)
		if built and built.root then pcall(function() built.root:Destroy() end) end
		return
	end
	finalize(built, base.CFrame)
	local overlay = built.root
	overlay.Parent = base.Parent or base
	local w = Instance.new("WeldConstraint")
	w.Part0, w.Part1 = overlay, base
	w.Parent = overlay
	local chroma = isChroma(name, data) and startChroma(overlay) or nil
	state[slot] = { overlay = overlay, hidden = hidden, chroma = chroma }
	say("wearing " .. tostring(name) .. " (" .. slot .. ")")
end

function S.clear(slot)
	lastApplied[slot] = nil
	cleanup(slot)
end

--== the weapon in your hand (in a round) ======================================
local toolState = {}

local function isMine(inst)
	if inst:IsDescendantOf(LocalPlayer) then return true end
	local c = char()
	return c ~= nil and inst:IsDescendantOf(c)
end

local function overlayTool(tool, slot)
	if toolState[tool] then return end
	local handle = tool:FindFirstChild("Handle") or tool:WaitForChild("Handle", 5)
	if not handle then return end
	local skin = ProfileData and ProfileData.Weapons.Equipped[slot]
	local data = skin and MESHES[skin]
	if not data then return end
	local built = buildAny(data)
	if not built or not built.root then return end
	local hidden = {}
	hideInto(hidden, handle)
	for _, d in ipairs(handle:GetDescendants()) do hideInto(hidden, d) end
	finalize(built, handle.CFrame)
	local overlay = built.root
	overlay.Parent = handle
	local w = Instance.new("WeldConstraint")
	w.Part0, w.Part1 = overlay, handle
	w.Parent = overlay
	local chroma = isChroma(skin, data) and startChroma(overlay) or nil
	toolState[tool] = { overlay = overlay, hidden = hidden, chroma = chroma }
end

local function unoverlayTool(tool)
	local st = toolState[tool]
	if not st then return end
	if st.chroma then pcall(function() st.chroma:Disconnect() end) end
	if st.overlay then pcall(function() st.overlay:Destroy() end) end
	restore(st.hidden)
	toolState[tool] = nil
end

--== names and spawning ========================================================
local lookup = {}
for key, info in pairs(WeaponDB or {}) do
	if type(info) == "table" then
		local kl = tostring(key):lower()
		lookup[kl] = lookup[kl] or key
		local dn = info.ItemName or info.DisplayName or info.Name
		if dn then
			dn = tostring(dn):lower()
			lookup[dn] = lookup[dn] or key
		end
	end
end

function S.resolve(text)
	if not text then return nil end
	text = tostring(text):gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then return nil end
	if WeaponDB and WeaponDB[text] then return text end
	return lookup[text:lower()]
end

function S.has(name) return MESHES[name] ~= nil end

-- Owning something is a number in ProfileData and a remote telling the inventory
-- to redraw. That is the whole spawn.
function S.spawn(name, amount, itemType)
	amount = amount or 1
	itemType = itemType or "Weapons"
	if not ProfileData or not ProfileData[itemType] then return false end
	local owned = ProfileData[itemType].Owned
	owned[name] = (owned[name] or 0) + amount
	pcall(function() InvDataChanged:Fire(itemType, name, owned[name]) end)
	pcall(function() InvDataChanged:Fire() end)
	return true
end

function S.give(name, amount, itemType)
	return S.spawn(name, amount, itemType)
end

function S.take(name, amount, itemType)
	itemType = itemType or "Weapons"
	amount = amount or 1
	if not ProfileData or not ProfileData[itemType] then return false end
	local owned = ProfileData[itemType].Owned[name]
	if not owned then return false end
	if owned - amount > 0 then
		ProfileData[itemType].Owned[name] = owned - amount
	else
		ProfileData[itemType].Owned[name] = nil
	end
	pcall(function() InvDataChanged:Fire() end)
	return true
end

function S.list()
	local out = {}
	for key, info in pairs(WeaponDB or {}) do
		if type(info) == "table" and (info.ItemType == "Knife" or info.ItemType == "Gun") then
			out[#out + 1] = {
				key = key, name = info.ItemName or key,
				type = info.ItemType, rarity = info.Rarity or "",
				image = info.Image, skin = MESHES[key] ~= nil,
			}
		end
	end
	table.sort(out, function(a, b)
		if a.type ~= b.type then return a.type < b.type end
		if a.rarity ~= b.rarity then return a.rarity < b.rarity end
		return a.name:lower() < b.name:lower()
	end)
	return out
end

-- equip it the way the game would, then wear it
function S.equip(name)
	local key = S.resolve(name) or name
	if not key then return false end
	pcall(function() EquipService:EquipItem("Weapons", key) end)
	local info = WeaponDB and WeaponDB[key]
	local slot = (info and info.ItemType) or (MESHES[key] and "Knife")
	if slot ~= "Knife" and slot ~= "Gun" then slot = "Knife" end
	task.spawn(function() S.apply(slot, key) end)
	return true
end

--== keeping up ================================================================
local running, conns = false, {}
local lastEquipped = { Knife = nil, Gun = nil }

local function watchCharacter(c)
	local cc = c.ChildAdded:Connect(function(child)
		local n = child.Name
		if n == "DisplayRefKnife" or n == "DisplayRefGun" then
			local slot = (n == "DisplayRefKnife") and "Knife" or "Gun"
			task.delay(0.2, function()
				local cur = state[slot] and lastApplied[slot]
				if cur then state[slot] = nil S.apply(slot, cur) end
			end)
		end
	end)
	conns[#conns + 1] = cc
end

function S.start()
	if running then return end
	running = true
	pcall(function()
		lastEquipped.Knife = ProfileData.Weapons.Equipped.Knife
		lastEquipped.Gun = ProfileData.Weapons.Equipped.Gun
	end)

	-- THE POLL. Not a signal: the game's own inventory writes ProfileData and
	-- never calls EquipItem, so a signal hears nothing.
	task.spawn(function()
		for _, slot in ipairs({ "Knife", "Gun" }) do
			local eq
			pcall(function() eq = ProfileData.Weapons.Equipped[slot] end)
			if eq then task.spawn(function() S.apply(slot, eq) end) end
		end
		while running do
			for _, slot in ipairs({ "Knife", "Gun" }) do
				local eq
				pcall(function() eq = ProfileData.Weapons.Equipped[slot] end)
				if eq ~= lastEquipped[slot] then
					lastEquipped[slot] = eq
					local name = eq
					task.spawn(function() S.apply(slot, name) end)
					for tool in pairs(toolState) do
						local ts = CollectionService:HasTag(tool, "Weapon_Gun") and "Gun" or "Knife"
						if ts == slot then
							task.spawn(function() unoverlayTool(tool) overlayTool(tool, slot) end)
						end
					end
				end
			end
			task.wait(S.PollRate)
		end
	end)

	pcall(function()
		conns[#conns + 1] = EquipService.EquippedChanged.Event:Connect(function(itemType, name)
			if itemType == "Knife" or itemType == "Gun" then
				lastEquipped[itemType] = name
				task.spawn(function() S.apply(itemType, name) end)
			end
		end)
	end)

	if char() then watchCharacter(char()) end
	conns[#conns + 1] = LocalPlayer.CharacterAdded:Connect(function(c)
		for _, slot in ipairs({ "Knife", "Gun" }) do
			local st = state[slot]
			if st and st.overlay then pcall(function() st.overlay:Destroy() end) end
		end
		state = {}
		watchCharacter(c)
		task.delay(1, function()
			for _, slot in ipairs({ "Knife", "Gun" }) do
				if lastApplied[slot] then S.apply(slot, lastApplied[slot]) end
			end
		end)
	end)

	-- the weapon actually in your hands during a round is tagged
	for _, tag in ipairs({ "Weapon_Knife", "Weapon_Gun" }) do
		local slot = (tag == "Weapon_Gun") and "Gun" or "Knife"
		for _, t in ipairs(CollectionService:GetTagged(tag)) do
			if isMine(t) then task.spawn(function() overlayTool(t, slot) end) end
		end
		conns[#conns + 1] = CollectionService:GetInstanceAddedSignal(tag):Connect(function(t)
			if isMine(t) then task.spawn(function() overlayTool(t, slot) end) end
		end)
		conns[#conns + 1] = CollectionService:GetInstanceRemovedSignal(tag):Connect(function(t)
			unoverlayTool(t)
		end)
	end
end

function S.stop()
	running = false
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	conns = {}
	for slot in pairs(state) do pcall(cleanup, slot) end
	for tool in pairs(toolState) do pcall(unoverlayTool, tool) end
end

function S.clearAll()
	for slot in pairs(state) do pcall(cleanup, slot) end
	for tool in pairs(toolState) do pcall(unoverlayTool, tool) end
	lastApplied = {}
end

function S.counts()
	local n, full = 0, 0
	for _, v in pairs(MESHES) do
		n = n + 1
		if v.Model then full = full + 1 end
	end
	return n, full
end

return S
