--!nocheck
--[[
================================================================================
  MollyMenu — the interface MollyHub is built in
================================================================================
  One file, no libraries, no asset ids. A top bar with the name, a sidebar of
  pages down the left, and the page itself as cards laid out in columns — the
  shape of the menus in the reference shots.

  It answers the same calls the old library did, so the hub did not have to be
  rewritten around it: CreateWindow, Tab, Section, Toggle, Slider, Dropdown,
  Colorpicker, Input, Keybind, Button, Paragraph, Divider, Space, Notify.

  Nothing here is fetched from anywhere. Icons are drawn out of frames, the
  shadow is drawn
  with frames, and the fonts are the ones in the client — so there is no asset
  to download and nothing to get wrong.
================================================================================
]]

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")

local UI = {}
UI.Windows = {}

--== theme =====================================================================
local T = {
	Bg      = Color3.fromRGB(11, 12, 16),   -- the page behind the groups
	Rail    = Color3.fromRGB(16, 17, 22),   -- the sidebar
	Panel   = Color3.fromRGB(21, 23, 29),   -- a group of rows
	Panel2  = Color3.fromRGB(27, 29, 36),   -- the active tab, a pressed control
	Hover   = Color3.fromRGB(33, 36, 44),
	Edge    = Color3.fromRGB(38, 41, 50),
	Text    = Color3.fromRGB(238, 240, 245),
	Muted   = Color3.fromRGB(132, 137, 152),
	Faint   = Color3.fromRGB(96, 100, 113),
	Accent  = Color3.fromRGB(58, 130, 247), -- the blue on the switches
	Accent2 = Color3.fromRGB(112, 96, 245),
	Good    = Color3.fromRGB(79, 211, 132),
	Bad     = Color3.fromRGB(255, 90, 112),
	Off     = Color3.fromRGB(88, 92, 104),  -- a switch that is off is just this dot
}

function UI:SetTheme(name)
	if type(name) == "table" then
		for k, v in pairs(name) do if T[k] ~= nil then T[k] = v end end
	end
	-- a string theme name is accepted and ignored: there is one look here
	return self
end

function UI:SetPalette(t)
	return self:SetTheme(t)
end

--== helpers ===================================================================
local function make(class, props, kids)
	local i = Instance.new(class)
	if props then
		for k, v in pairs(props) do
			if k ~= "Parent" then pcall(function() i[k] = v end) end
		end
	end
	if kids then
		for _, k in ipairs(kids) do k.Parent = i end
	end
	if props and props.Parent then i.Parent = props.Parent end
	return i
end

local function corner(r)
	return make("UICorner", { CornerRadius = UDim.new(0, r or 8) })
end

local function stroke(colr, tr, thick)
	return make("UIStroke", {
		Color = colr or T.Edge,
		Transparency = tr or 0.35,
		Thickness = thick or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function pad(l, r, t, b)
	return make("UIPadding", {
		PaddingLeft = UDim.new(0, l or 0),
		PaddingRight = UDim.new(0, r or l or 0),
		PaddingTop = UDim.new(0, t or 0),
		PaddingBottom = UDim.new(0, b or t or 0),
	})
end

local function list(gap, order)
	return make("UIListLayout", {
		Padding = UDim.new(0, gap or 8),
		SortOrder = order or Enum.SortOrder.LayoutOrder,
	})
end

local function tween(obj, secs, props)
	local ok = pcall(function()
		local info = TweenInfo.new(secs, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
		TweenService:Create(obj, info, props):Play()
	end)
	if not ok then
		for k, v in pairs(props) do pcall(function() obj[k] = v end) end
	end
end

local function num(v, fallback)
	v = tonumber(v)
	if v ~= v then return fallback end        -- NaN
	return v or fallback
end

-- ICONS ARE DRAWN, not typed. Gotham does not carry the shapes a menu wants —
-- a crosshair, a gear, an eye — so asking for them by character got a row of
-- empty boxes. These are built from plain frames instead: a few bars, a circle
-- made with a UIStroke, a dot. Nothing to install and nothing missing.
local function bit(parent, x, y, w, h, colr, round, rot)
	local f = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(x, y),
		Size = UDim2.fromScale(w, h),
		BackgroundColor3 = colr,
		BorderSizePixel = 0,
		Rotation = rot or 0,
		Parent = parent,
	})
	if round then corner(99).Parent = f end
	return f
end

local function ring(parent, x, y, d, colr, thick)
	local f = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(x, y),
		Size = UDim2.fromScale(d, d),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = parent,
	}, { corner(99), stroke(colr, 0, thick or 1.4) })
	return f
end

local DRAW = {}
function DRAW.box(h, c)
	bit(h, 0.5, 0.16, 0.72, 0.12, c)
	bit(h, 0.5, 0.84, 0.72, 0.12, c)
	bit(h, 0.16, 0.5, 0.12, 0.72, c)
	bit(h, 0.84, 0.5, 0.12, 0.72, c)
end
function DRAW.eye(h, c)
	ring(h, 0.5, 0.5, 0.9, c, 1.3)
	bit(h, 0.5, 0.5, 0.26, 0.26, c, true)
end
function DRAW.user(h, c)
	ring(h, 0.5, 0.3, 0.44, c, 1.3)
	local body = ring(h, 0.5, 0.86, 0.8, c, 1.3)
	pcall(function() body.Size = UDim2.fromScale(0.8, 0.5) end)
end
function DRAW.target(h, c)
	ring(h, 0.5, 0.5, 0.66, c, 1.3)
	bit(h, 0.5, 0.5, 0.18, 0.18, c, true)
	bit(h, 0.5, 0.04, 0.1, 0.2, c)
	bit(h, 0.5, 0.96, 0.1, 0.2, c)
	bit(h, 0.04, 0.5, 0.2, 0.1, c)
	bit(h, 0.96, 0.5, 0.2, 0.1, c)
end
function DRAW.gear(h, c)
	ring(h, 0.5, 0.5, 0.56, c, 1.4)
	for i = 0, 3 do
		local a = i * math.pi / 2
		bit(h, 0.5 + math.cos(a) * 0.38, 0.5 + math.sin(a) * 0.38, 0.2, 0.2, c)
	end
end
function DRAW.dots(h, c)
	bit(h, 0.18, 0.5, 0.2, 0.2, c, true)
	bit(h, 0.5, 0.5, 0.2, 0.2, c, true)
	bit(h, 0.82, 0.5, 0.2, 0.2, c, true)
end
function DRAW.info(h, c)
	ring(h, 0.5, 0.5, 0.9, c, 1.3)
	bit(h, 0.5, 0.28, 0.16, 0.16, c, true)
	bit(h, 0.5, 0.62, 0.14, 0.34, c)
end
function DRAW.spark(h, c)
	bit(h, 0.5, 0.5, 0.16, 0.86, c)
	bit(h, 0.5, 0.5, 0.86, 0.16, c)
	bit(h, 0.16, 0.16, 0.16, 0.16, c, true)
	bit(h, 0.84, 0.84, 0.16, 0.16, c, true)
end
function DRAW.map(h, c)
	bit(h, 0.5, 0.16, 0.86, 0.12, c)
	bit(h, 0.5, 0.5, 0.86, 0.12, c)
	bit(h, 0.5, 0.84, 0.86, 0.12, c)
end
function DRAW.dot(h, c)
	bit(h, 0.5, 0.5, 0.34, 0.34, c, true)
end
function DRAW.close(h, c)
	bit(h, 0.5, 0.5, 0.86, 0.13, c, false, 45)
	bit(h, 0.5, 0.5, 0.86, 0.13, c, false, -45)
end
function DRAW.search(h, c)
	ring(h, 0.42, 0.42, 0.62, c, 1.4)
	bit(h, 0.78, 0.78, 0.34, 0.13, c, false, 45)
end
function DRAW.save(h, c)
	bit(h, 0.5, 0.14, 0.76, 0.14, c)
	bit(h, 0.14, 0.5, 0.14, 0.76, c)
	bit(h, 0.86, 0.5, 0.14, 0.76, c)
	bit(h, 0.5, 0.86, 0.76, 0.14, c)
	bit(h, 0.5, 0.62, 0.42, 0.3, c)
end
function DRAW.chev(h, c)
	bit(h, 0.42, 0.28, 0.62, 0.14, c, false, 45)
	bit(h, 0.42, 0.72, 0.62, 0.14, c, false, -45)
end
function DRAW.caret(h, c)
	bit(h, 0.3, 0.42, 0.5, 0.13, c, false, 45)
	bit(h, 0.7, 0.42, 0.5, 0.13, c, false, -45)
end

-- the names the hub asks for, pointed at a shape that exists
local ICON = {
	crown = "spark", house = "map", box = "box", eye = "eye", target = "target",
	crosshair = "target", user = "user", users = "user", star = "spark",
	zap = "spark", flame = "spark", map = "map", ghost = "eye", gear = "gear",
	settings = "gear", wrench = "gear", hand = "dot", info = "info", x = "close",
	component = "box", sparkles = "spark", swords = "target", sword = "target",
	knife = "target", gun = "target", coins = "dot", palette = "eye", key = "dot",
	save = "save", trash = "close", bell = "dot", folder = "box",
	["gamepad-2"] = "box", move = "map", bitcoin = "dot", ["map-pin"] = "map",
	["person-standing"] = "user", laugh = "dot", ["package-plus"] = "box",
	["file-cog"] = "save", check = "dot", ["refresh-cw"] = "gear",
}

-- Put a drawn icon inside a holder. `kind` is a name from ICON or from DRAW.
local function icon(parent, kind, px, colr, x, y)
	local shape = DRAW[kind] or DRAW[ICON[tostring(kind or ""):lower()] or ""] or DRAW.dot
	local h = make("Frame", {
		Name = "Icon",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = x and UDim2.fromOffset(x, y) or UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(px, px),
		BackgroundTransparency = 1,
		Parent = parent,
	})
	shape(h, colr or T.Muted)
	return h
end

local function fits(o, ...)
	for _, k in ipairs({ ... }) do
		if o and o[k] ~= nil then return o[k] end
	end
	return nil
end

--== notifications =============================================================
local toastGui, toastHolder
local function toastRoot()
	if toastGui and toastGui.Parent then return toastHolder end
	toastGui = make("ScreenGui", {
		Name = "MollyMenuToasts",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 120,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	pcall(function() toastGui.Parent = PlayerGui end)
	toastHolder = make("Frame", {
		Name = "Holder",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -16),
		Size = UDim2.fromOffset(310, 400),
		BackgroundTransparency = 1,
		Parent = toastGui,
	}, {
		make("UIListLayout", {
			Padding = UDim.new(0, 8),
			VerticalAlignment = Enum.VerticalAlignment.Bottom,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	return toastHolder
end

function UI:Notify(o)
	o = o or {}
	local holder = toastRoot()
	if not holder then return end
	local card = make("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = T.Panel,
		BorderSizePixel = 0,
		Parent = holder,
	}, {
		corner(10), stroke(T.Edge, 0.25), pad(12, 12, 10, 12), list(4),
	})
	make("Frame", {
		Name = "Bar",
		Size = UDim2.fromOffset(26, 3),
		BackgroundColor3 = T.Accent,
		BorderSizePixel = 0,
		LayoutOrder = 0,
		Parent = card,
	}, { corner(99) })
	make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundTransparency = 1,
		Text = tostring(o.Title or "MollyHub"),
		TextColor3 = T.Text,
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 1,
		Parent = card,
	})
	make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Text = tostring(o.Content or o.Desc or ""),
		TextColor3 = T.Muted,
		TextSize = 12,
		Font = Enum.Font.Gotham,
		TextWrapped = true,
		RichText = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 2,
		Parent = card,
	})
	local secs = num(o.Duration, 5)
	task.delay(secs, function()
		tween(card, 0.2, { BackgroundTransparency = 1 })
		task.delay(0.22, function() pcall(function() card:Destroy() end) end)
	end)
	return card
end

--== the window ================================================================
function UI:CreateWindow(o)
	o = o or {}
	local W = { _tabs = {}, _pages = {}, _cur = nil, _reg = {} }

	local wide = num(o.SideBarWidth, 200)
	local designW = math.max(num(fits(o, "Width"), 0), 0)
	local size = o.Size
	local cw = (size and size.X and num(size.X.Offset, 820)) or 820
	local ch = (size and size.Y and num(size.Y.Offset, 500)) or 500
	if designW > 0 then cw = designW end
	cw = math.max(cw, 640)
	ch = math.max(ch, 420)

	local gui = make("ScreenGui", {
		Name = "MollyMenu",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 100,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	pcall(function() gui.Parent = PlayerGui end)
	W._gui = gui

	-- a shadow drawn with frames: three soft rings, no image asset
	local shade = make("Frame", {
		Name = "Shade",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(cw + 26, ch + 26),
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 0.72,
		BorderSizePixel = 0,
		Parent = gui,
	}, { corner(20) })

	local card = make("Frame", {
		Name = "Window",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(cw, ch),
		BackgroundColor3 = T.Bg,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = gui,
	}, { corner(14), stroke(T.Edge, 0.15) })
	W._card = card

	local scale = make("UIScale", { Scale = 1, Parent = card })
	W._scale = scale

	local function refit()
		local cam = workspace.CurrentCamera
		if not cam then return end
		local vp = cam.ViewportSize
		local vw, vh = num(vp and vp.X, 1280), num(vp and vp.Y, 720)
		local k = math.min(vw / (cw + 90), vh / (ch + 90), 1) * num(W._userScale, 1)
		scale.Scale = math.clamp(k, 0.45, 1.6)
		shade.Size = UDim2.fromOffset(cw + 26, ch + 26)
		-- a narrow screen gets the icon rail instead of the full sidebar
		W._narrow = (vw * (1 / math.max(scale.Scale, 0.01))) < (cw + 240)
		if W._applyRail then W._applyRail() end
	end

	--== the sidebar: who you are, the pages, and you again at the foot ==========
	-- No top bar. In the reference the sidebar runs the full height and carries
	-- the name at the top and the player at the bottom, and the content area
	-- starts with the config strip instead of a title.
	local side = make("Frame", {
		Name = "Sidebar",
		Size = UDim2.new(0, wide, 1, 0),
		BackgroundColor3 = T.Rail,
		BorderSizePixel = 0,
		Parent = card,
	})
	make("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 1, 1, 0),
		BackgroundColor3 = T.Edge,
		BorderSizePixel = 0,
		Parent = side,
	})

	-- rbxthumb is a scheme the client resolves itself, so there is no asset id
	-- here to be wrong about
	local function headshot(userId, px)
		return "rbxthumb://type=AvatarHeadShot&id=" .. tostring(userId or 1)
			.. "&w=" .. tostring(px or 48) .. "&h=" .. tostring(px or 48)
	end

	local head = make("Frame", {
		Name = "Head",
		Position = UDim2.fromOffset(14, 14),
		Size = UDim2.new(1, -28, 0, 46),
		BackgroundTransparency = 1,
		Parent = side,
	})
	local badge = make("ImageLabel", {
		Name = "Badge",
		Size = UDim2.fromOffset(42, 42),
		BackgroundColor3 = T.Panel2,
		BorderSizePixel = 0,
		Image = headshot(LocalPlayer and LocalPlayer.UserId, 60),
		Parent = head,
	}, { corner(10), stroke(T.Edge, 0.4) })
	local logo = make("TextLabel", {
		Name = "Logo",
		Position = UDim2.fromOffset(54, 3),
		Size = UDim2.new(1, -54, 0, 22),
		BackgroundTransparency = 1,
		Text = tostring(o.Title or "Molly Hub"):upper(),
		TextColor3 = T.Text,
		TextSize = 17,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = head,
	})
	W._logo = logo
	make("TextLabel", {
		Position = UDim2.fromOffset(54, 25),
		Size = UDim2.new(1, -54, 0, 16),
		BackgroundTransparency = 1,
		Text = tostring(o.SubTitle or o.Author or "Murder Mystery 2"),
		TextColor3 = T.Faint,
		TextSize = 11,
		Font = Enum.Font.Gotham,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = head,
	})

	local footH = 58
	local tabbar = make("ScrollingFrame", {
		Name = "Tabs",
		Position = UDim2.fromOffset(10, 74),
		Size = UDim2.new(1, -20, 1, -(74 + footH + 10)),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 2,
		ScrollBarImageColor3 = T.Edge,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = side,
	}, { list(3) })
	W._tabbar = tabbar
	W._sidebar = true
	W._menuBtn = nil

	-- the profile at the foot, the way the reference has it
	local foot = make("TextButton", {
		Name = "Profile",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 10, 1, -10),
		Size = UDim2.new(1, -20, 0, footH - 12),
		BackgroundColor3 = T.Rail,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		Parent = side,
	}, { corner(10) })
	make("Frame", {
		Name = "Line",
		Position = UDim2.fromOffset(2, -8),
		Size = UDim2.new(1, -4, 0, 1),
		BackgroundColor3 = T.Edge,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Parent = foot,
	})
	make("ImageLabel", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 4, 0.5, 0),
		Size = UDim2.fromOffset(30, 30),
		BackgroundColor3 = T.Panel2,
		BorderSizePixel = 0,
		Image = headshot(LocalPlayer and LocalPlayer.UserId, 48),
		Parent = foot,
	}, { corner(8) })
	local whoName = make("TextLabel", {
		Position = UDim2.fromOffset(42, 4),
		Size = UDim2.new(1, -66, 0, 16),
		BackgroundTransparency = 1,
		Text = tostring((LocalPlayer and (LocalPlayer.DisplayName or LocalPlayer.Name)) or "player"),
		TextColor3 = T.Text,
		TextSize = 12,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = foot,
	})
	local whoSub = make("TextLabel", {
		Position = UDim2.fromOffset(42, 20),
		Size = UDim2.new(1, -66, 0, 14),
		BackgroundTransparency = 1,
		Text = "@" .. tostring((LocalPlayer and LocalPlayer.Name) or "player"),
		TextColor3 = T.Faint,
		TextSize = 10,
		Font = Enum.Font.Gotham,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = foot,
	})
	icon(foot, "chev", 9, T.Faint).Position = UDim2.new(1, -8, 0.5, 0)
	W._who = whoName
	pcall(function()
		foot.MouseEnter:Connect(function() tween(foot, 0.12, { BackgroundColor3 = T.Panel }) end)
		foot.MouseLeave:Connect(function() tween(foot, 0.12, { BackgroundColor3 = T.Rail }) end)
	end)

	--== content: the config strip, then the page ================================
	local content = make("Frame", {
		Name = "Content",
		Position = UDim2.fromOffset(wide, 0),
		Size = UDim2.new(1, -wide, 1, 0),
		BackgroundTransparency = 1,
		Parent = card,
	})
	local barH = 50
	local bar = make("Frame", {
		Name = "ConfigBar",
		Size = UDim2.new(1, 0, 0, barH),
		BackgroundTransparency = 1,
		Parent = content,
	})
	make("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = T.Edge,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		Parent = bar,
	})
	local saveBtn = make("TextButton", {
		Name = "Save",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 16, 0.5, 0),
		Size = UDim2.fromOffset(30, 28),
		BackgroundColor3 = T.Panel,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		Parent = bar,
	}, { corner(8), stroke(T.Edge, 0.45) })
	local saveMark = icon(saveBtn, "save", 13, T.Muted)
	local cfgPill = make("TextButton", {
		Name = "Config",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 52, 0.5, 0),
		Size = UDim2.fromOffset(132, 28),
		BackgroundColor3 = T.Panel,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		Parent = bar,
	}, { corner(8), stroke(T.Edge, 0.45) })
	local cfgText = make("TextLabel", {
		Position = UDim2.fromOffset(11, 0),
		Size = UDim2.new(1, -30, 1, 0),
		BackgroundTransparency = 1,
		Text = "default",
		TextColor3 = T.Text,
		TextSize = 12,
		Font = Enum.Font.GothamMedium,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = cfgPill,
	})
	icon(cfgPill, "caret", 9, T.Faint).Position = UDim2.new(1, -11, 0.5, 0)
	local closeBtn = make("TextButton", {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(28, 28),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Parent = bar,
	}, { corner(8) })
	local closeMark = icon(closeBtn, "close", 11, T.Muted)
	local searchBtn = make("TextButton", {
		Name = "Search",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -48, 0.5, 0),
		Size = UDim2.fromOffset(28, 28),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Parent = bar,
	}, { corner(8) })
	local searchMark = icon(searchBtn, "search", 13, T.Muted)
	W._hint = cfgText

	local searchBox = make("TextBox", {
		Name = "SearchBox",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -80, 0.5, 0),
		Size = UDim2.fromOffset(160, 28),
		BackgroundColor3 = T.Panel,
		BorderSizePixel = 0,
		Text = "",
		PlaceholderText = "find a setting",
		PlaceholderColor3 = T.Faint,
		TextColor3 = T.Text,
		TextSize = 12,
		Font = Enum.Font.Gotham,
		ClearTextOnFocus = false,
		Visible = false,
		Parent = bar,
	}, { corner(8), stroke(T.Edge, 0.45), pad(9, 9, 0, 0) })

	local pages = make("Frame", {
		Name = "Pages",
		Position = UDim2.fromOffset(14, barH + 8),
		Size = UDim2.new(1, -28, 1, -(barH + 18)),
		BackgroundTransparency = 1,
		Parent = content,
	})
	W._pageTitle = cfgText
	-- the config drop-down is built once the ConfigManager exists, further down;
	-- the settings button needs to be able to close it before then
	local cfgList

	-- the icon rail: on a narrow screen the sidebar keeps the icons and drops
	-- the words, and the page takes the room back
	function W._applyRail()
		local w = W._narrow and 54 or wide
		side.Size = UDim2.new(0, w, 1, 0)
		content.Position = UDim2.fromOffset(w, 0)
		content.Size = UDim2.new(1, -w, 1, 0)
		head.Size = UDim2.new(1, -28, 0, 46)
		logo.Visible = not W._narrow
		whoName.Visible = not W._narrow
		whoSub.Visible = not W._narrow
		for _, t in ipairs(W._tabs) do
			if t._label then t._label.Visible = not W._narrow end
		end
	end

	refit()
	pcall(function()
		local cam = workspace.CurrentCamera
		if cam then cam:GetPropertyChangedSignal("ViewportSize"):Connect(refit) end
		workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(refit)
	end)

	--== rows and cards =========================================================
	local function cardBox(parent, order)
		return make("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = T.Panel,
			BorderSizePixel = 0,
			LayoutOrder = order or 1,
			Parent = parent,
		}, { corner(10), pad(4, 4, 8, 10), list(0) })
	end

	-- A row is FLAT: the group is the panel, and the rows inside it are label and
	-- control on nothing at all, the way the reference reads. Boxing each one
	-- inside its own bordered card is what made it look like a form.
	local function row(parent, h)
		local r = make("Frame", {
			Size = UDim2.new(1, 0, 0, h or 38),
			BackgroundColor3 = T.Panel,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = parent,
		})
		pcall(function()
			r.MouseEnter:Connect(function()
				tween(r, 0.1, { BackgroundTransparency = 0.55, BackgroundColor3 = T.Hover })
			end)
			r.MouseLeave:Connect(function() tween(r, 0.1, { BackgroundTransparency = 1 }) end)
		end)
		corner(8).Parent = r
		return r
	end

	local function rowTitle(host, text, desc, rightGap)
		local hasDesc = desc ~= nil and tostring(desc) ~= ""
		local titleSize = hasDesc and UDim2.new(1, -(rightGap or 76), 0, 17)
			or UDim2.new(1, -(rightGap or 76), 1, 0)
		make("TextLabel", {
			Position = UDim2.fromOffset(12, hasDesc and 7 or 0),
			Size = titleSize,
			BackgroundTransparency = 1,
			Text = tostring(text or ""),
			TextColor3 = T.Text,
			TextSize = 13,
			Font = Enum.Font.GothamMedium,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = host,
		})
		if hasDesc then
			make("TextLabel", {
				Position = UDim2.fromOffset(12, 24),
				Size = UDim2.new(1, -(rightGap or 76), 0, 15),
				BackgroundTransparency = 1,
				Text = tostring(desc),
				TextColor3 = T.Muted,
				TextSize = 11,
				Font = Enum.Font.Gotham,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				RichText = true,
				Parent = host,
			})
		end
		return hasDesc
	end

	local function hover(obj, base, over)
		pcall(function()
			obj.MouseEnter:Connect(function() tween(obj, 0.12, { BackgroundColor3 = over }) end)
			obj.MouseLeave:Connect(function() tween(obj, 0.12, { BackgroundColor3 = base }) end)
		end)
	end

	--== a page =================================================================
	local function newPage(name, subtitle)
		local page = make("ScrollingFrame", {
			Name = name .. "Page",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = T.Accent,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			Visible = false,
			Parent = pages,
		})
		-- two columns when there is room, like the reference layout
		local flow = make("Frame", {
			Name = "Flow",
			Size = UDim2.new(1, -6, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Parent = page,
		}, {
			make("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 10),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		})
		local cols, heights = {}, {}
		local nCols = (cw - wide) >= 520 and 2 or 1
		for i = 1, nCols do
			cols[i] = make("Frame", {
				Name = "Col" .. i,
				Size = UDim2.new(1 / nCols, -5, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = i,
				Parent = flow,
			}, { list(10) })
			heights[i] = 0
		end
		return { page = page, cols = cols, heights = heights, n = nCols, sub = subtitle }
	end

	--== widgets ================================================================
	-- Every widget lands in a card. A Section starts a new one; anything added
	-- before the first Section gets a card of its own so nothing floats loose.
	local function mkTab(name, iconName, subtitle)
		local P = newPage(name, subtitle)
		local Tab = { Instance = P.page, _body = P.page, _cols = P.cols, _page = P }

		-- Anything with a value says so, and a config is then just the list of
		-- those values. The key is the page and the title, which is stable across
		-- runs as long as the menu keeps its wording.
		local function reg(title, get, set)
			if title == nil or tostring(title) == "" then return end
			W._reg[#W._reg + 1] = { key = name .. "/" .. tostring(title), get = get, set = set }
		end

		Tab._ctx = nil            -- which group new widgets land in

		local function shortest()
			local best, bh = 1, P.heights[1] or 0
			for i = 2, P.n do
				if (P.heights[i] or 0) < bh then best, bh = i, P.heights[i] end
			end
			return best
		end
		local function grow(h)
			local i = Tab._colIdx or 1
			P.heights[i] = (P.heights[i] or 0) + h
		end
		local function heading(box, text)
			make("TextLabel", {
				Size = UDim2.new(1, 0, 0, 26),
				BackgroundTransparency = 1,
				Text = tostring(text or ""),
				TextColor3 = T.Muted,
				TextSize = 12,
				Font = Enum.Font.GothamBold,
				TextXAlignment = Enum.TextXAlignment.Left,
				LayoutOrder = 0,
				Parent = box,
			}, { pad(8, 8, 4, 0) })
		end

		local function host(h)
			local ctx = Tab._ctx
			if ctx then
				if not ctx.card then
					ctx.col = shortest()
					Tab._order = (Tab._order or 0) + 1
					ctx.card = cardBox(P.cols[ctx.col], Tab._order)
					if ctx.title and ctx.title ~= "" then heading(ctx.card, ctx.title) end
					P.heights[ctx.col] = (P.heights[ctx.col] or 0) + 34
				end
				P.heights[ctx.col] = (P.heights[ctx.col] or 0) + h
				return ctx.card
			end
			if not Tab._card then
				Tab._colIdx = shortest()
				Tab._card = cardBox(P.cols[Tab._colIdx], (Tab._order or 0) + 1)
				Tab._order = (Tab._order or 0) + 1
			end
			grow(h)
			return Tab._card
		end

		function Tab:Section(so)
			so = so or {}
			-- inside a group, a Section is simply the next group
			if Tab._ctx then
				Tab._ctx.card = nil
				Tab._ctx.title = tostring(so.Title or "")
				return { Instance = host(0) }
			end
			Tab._colIdx = shortest()
			Tab._order = (Tab._order or 0) + 1
			local box = cardBox(P.cols[Tab._colIdx], Tab._order)
			Tab._card = box
			P.heights[Tab._colIdx] = (P.heights[Tab._colIdx] or 0) + 34
			make("TextLabel", {
				Size = UDim2.new(1, 0, 0, 26),
				BackgroundTransparency = 1,
				Text = tostring(so.Title or ""),
				TextColor3 = T.Muted,
				TextSize = 12,
				Font = Enum.Font.GothamBold,
				TextXAlignment = Enum.TextXAlignment.Left,
				LayoutOrder = 0,
				Parent = box,
			}, { pad(8, 8, 4, 0) })
			if so.Desc and tostring(so.Desc) ~= "" then
				make("TextLabel", {
					Size = UDim2.new(1, 0, 0, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1,
					Text = tostring(so.Desc),
					TextColor3 = T.Muted,
					TextSize = 11,
					Font = Enum.Font.Gotham,
					TextWrapped = true,
					RichText = true,
					TextXAlignment = Enum.TextXAlignment.Left,
					LayoutOrder = 1,
					Parent = box,
				})
			end
			return { Instance = box }
		end

		function Tab:Divider()
			make("Frame", {
				Size = UDim2.new(1, 0, 0, 1),
				BackgroundColor3 = T.Edge,
				BackgroundTransparency = 0.4,
				BorderSizePixel = 0,
				Parent = host(9),
			})
			return self
		end

		function Tab:Space()
			make("Frame", {
				Size = UDim2.new(1, 0, 0, 6),
				BackgroundTransparency = 1,
				Parent = host(6),
			})
			return self
		end

		function Tab:Paragraph(po)
			po = po or {}
			local box = row(host(60), 0)
			box.Size = UDim2.new(1, 0, 0, 0)
			box.AutomaticSize = Enum.AutomaticSize.Y
			pad(12, 12, 10, 11).Parent = box
			list(4).Parent = box
			make("TextLabel", {
				Size = UDim2.new(1, 0, 0, 17),
				BackgroundTransparency = 1,
				Text = tostring(po.Title or ""),
				TextColor3 = T.Text,
				TextSize = 12,
				Font = Enum.Font.GothamBold,
				TextXAlignment = Enum.TextXAlignment.Left,
				LayoutOrder = 0,
				Parent = box,
			})
			local body = make("TextLabel", {
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				Text = tostring(po.Desc or po.Description or ""),
				TextColor3 = T.Muted,
				TextSize = 11,
				Font = Enum.Font.Gotham,
				TextWrapped = true,
				RichText = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				LayoutOrder = 1,
				Parent = box,
			})
			local api = { Instance = box }
			function api:SetDesc(t) pcall(function() body.Text = tostring(t or "") end) end
			function api:SetTitle(t) end
			return api
		end

		function Tab:Button(bo)
			bo = bo or {}
			local desc = fits(bo, "Desc", "Description")
			local hasDesc = desc ~= nil and tostring(desc) ~= ""
			local h = hasDesc and 44 or 34
			local btn = make("TextButton", {
				Size = UDim2.new(1, 0, 0, h),
				BackgroundColor3 = (bo.Style == "primary") and T.Accent or T.Panel,
				BorderSizePixel = 0,
				Text = "",
				AutoButtonColor = false,
				Parent = host(h + 7),
			}, { corner(8) })
			local isPrimary = bo.Style == "primary"
			make("TextLabel", {
				Position = UDim2.fromOffset(12, hasDesc and 8 or 0),
				Size = hasDesc and UDim2.new(1, -46, 0, 17) or UDim2.new(1, -46, 1, 0),
				BackgroundTransparency = 1,
				Text = tostring(bo.Title or ""),
				TextColor3 = isPrimary and Color3.fromRGB(255, 255, 255) or T.Text,
				TextSize = 13,
				Font = Enum.Font.GothamMedium,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = btn,
			})
			if hasDesc then
				make("TextLabel", {
					Position = UDim2.fromOffset(12, 25),
					Size = UDim2.new(1, -46, 0, 15),
					BackgroundTransparency = 1,
					Text = tostring(desc),
					TextColor3 = isPrimary and Color3.fromRGB(235, 235, 255) or T.Muted,
					TextSize = 11,
					Font = Enum.Font.Gotham,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Parent = btn,
				})
			end
			icon(btn, "chev", 9, isPrimary and Color3.fromRGB(255, 255, 255) or T.Faint,
				nil, nil).Position = UDim2.new(1, -14, 0.5, 0)
			if not isPrimary then hover(btn, T.Panel, T.Hover) end
			pcall(function()
				btn.MouseButton1Click:Connect(function()
					local ok, err = pcall(bo.Callback or function() end)
					if not ok then warn("[MollyMenu] " .. tostring(bo.Title) .. ": " .. tostring(err)) end
				end)
			end)
			return { Instance = btn }
		end

		function Tab:Toggle(to)
			to = to or {}
			local state = fits(to, "Value", "Default") == true
			local desc = fits(to, "Desc", "Description")
			local hasDesc = desc ~= nil and tostring(desc) ~= ""
			local h = hasDesc and 44 or 34
			local r = row(host(h + 2), h)
			rowTitle(r, to.Title, hasDesc and desc or nil, 66)
			-- Off is a single grey dot with no track behind it, on is a blue pill
			-- with the dot at the far end. That difference is the whole tell in the
			-- reference, and it reads at a glance across a column of them.
			local sw = make("TextButton", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -10, 0.5, 0),
				Size = UDim2.fromOffset(40, 20),
				BackgroundColor3 = T.Accent,
				BackgroundTransparency = state and 0 or 1,
				BorderSizePixel = 0,
				Text = "",
				AutoButtonColor = false,
				Parent = r,
			}, { corner(99) })
			local knob = make("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = state and UDim2.new(1, -10, 0.5, 0) or UDim2.new(1, -10, 0.5, 0),
				Size = UDim2.fromOffset(16, 16),
				BackgroundColor3 = state and Color3.fromRGB(255, 255, 255) or T.Off,
				BorderSizePixel = 0,
				Parent = sw,
			}, { corner(99) })
			local api = { Instance = r }
			local function paint()
				tween(sw, 0.15, { BackgroundTransparency = state and 0 or 1 })
				tween(knob, 0.15, {
					Position = state and UDim2.new(1, -10, 0.5, 0) or UDim2.new(1, -10, 0.5, 0),
					BackgroundColor3 = state and Color3.fromRGB(255, 255, 255) or T.Off,
				})
			end
			local function fire()
				local ok, err = pcall(to.Callback or function() end, state)
				if not ok then warn("[MollyMenu] " .. tostring(to.Title) .. ": " .. tostring(err)) end
			end
			pcall(function()
				sw.MouseButton1Click:Connect(function()
					state = not state
					paint()
					fire()
				end)
			end)
			function api:Set(v)
				state = v == true
				paint()
				fire()
			end
			function api:Get() return state end
			reg(to.Title, function() return state end, function(v) api:Set(v == true) end)
			return api
		end

		function Tab:Slider(so)
			so = so or {}
			local v = so.Value
			local lo, hi, def
			if type(v) == "table" then
				lo, hi, def = num(v.Min, 0), num(v.Max, 100), num(v.Default, num(v.Min, 0))
			else
				lo, hi, def = num(so.Min, 0), num(so.Max, 100), num(so.Default or v, 0)
			end
			if hi <= lo then hi = lo + 1 end
			local step = num(so.Step, 0)
			local val = math.clamp(def, lo, hi)
			local desc = fits(so, "Desc", "Description")
			local hasDesc = desc ~= nil and tostring(desc) ~= ""
			local h = hasDesc and 62 or 48
			local r = row(host(h + 2), h)
			local function pretty(x)
				if step > 0 and step < 1 then return string.format("%.2f", x) end
				if x == math.floor(x) then return string.format("%d", x) end
				return string.format("%.2f", x)
			end
			local label = make("TextLabel", {
				Position = UDim2.fromOffset(12, 7),
				Size = UDim2.new(1, -70, 0, 17),
				BackgroundTransparency = 1,
				Text = tostring(so.Title or ""),
				TextColor3 = T.Text,
				TextSize = 13,
				Font = Enum.Font.GothamMedium,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = r,
			})
			local readout = make("TextLabel", {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -12, 0, 7),
				Size = UDim2.fromOffset(56, 17),
				BackgroundTransparency = 1,
				Text = pretty(val),
				TextColor3 = T.Accent,
				TextSize = 12,
				Font = Enum.Font.GothamBold,
				TextXAlignment = Enum.TextXAlignment.Right,
				Parent = r,
			})
			if hasDesc then
				make("TextLabel", {
					Position = UDim2.fromOffset(12, 25),
					Size = UDim2.new(1, -24, 0, 15),
					BackgroundTransparency = 1,
					Text = tostring(desc),
					TextColor3 = T.Muted,
					TextSize = 11,
					Font = Enum.Font.Gotham,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Parent = r,
				})
			end
			local track = make("Frame", {
				Position = UDim2.new(0, 12, 1, -18),
				Size = UDim2.new(1, -24, 0, 6),
				BackgroundColor3 = T.Off,
				BorderSizePixel = 0,
				Parent = r,
			}, { corner(99) })
			local fill = make("Frame", {
				Size = UDim2.fromScale((val - lo) / (hi - lo), 1),
				BackgroundColor3 = T.Accent,
				BorderSizePixel = 0,
				Parent = track,
			}, { corner(99) })
			pcall(function()
				make("UIGradient", {
					Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, T.Accent),
						ColorSequenceKeypoint.new(1, T.Accent2),
					}),
					Parent = fill,
				})
			end)
			local grab = make("TextButton", {
				Position = UDim2.fromOffset(0, -9),
				Size = UDim2.new(1, 0, 1, 18),
				BackgroundTransparency = 1,
				Text = "",
				Parent = track,
			})
			local api = { Instance = r }
			local function set(x, fire)
				if step > 0 then x = math.floor((x - lo) / step + 0.5) * step + lo end
				x = math.clamp(x, lo, hi)
				if x == val and fire ~= "force" then return end
				val = x
				readout.Text = pretty(val)
				tween(fill, 0.08, { Size = UDim2.fromScale((val - lo) / (hi - lo), 1) })
				local ok, err = pcall(so.Callback or function() end, val)
				if not ok then warn("[MollyMenu] " .. tostring(so.Title) .. ": " .. tostring(err)) end
			end
			local function fromX(x)
				local ax = num(track.AbsolutePosition and track.AbsolutePosition.X, nil)
				local aw = num(track.AbsoluteSize and track.AbsoluteSize.X, nil)
				if not ax or not aw or aw <= 0 then return end
				set(lo + (hi - lo) * math.clamp((num(x, ax) - ax) / aw, 0, 1))
			end
			local dragging = false
			pcall(function()
				grab.InputBegan:Connect(function(input)
					local t = input.UserInputType
					if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
						dragging = true
						fromX(input.Position and input.Position.X)
					end
				end)
				UserInputService.InputChanged:Connect(function(input)
					if not dragging then return end
					local t = input.UserInputType
					if t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch then
						fromX(input.Position and input.Position.X)
					end
				end)
				UserInputService.InputEnded:Connect(function(input)
					local t = input.UserInputType
					if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
						dragging = false
					end
				end)
			end)
			function api:Set(x) set(num(x, val), "force") end
			function api:Get() return val end
			reg(so.Title, function() return val end, function(v) api:Set(v) end)
			return api
		end

		function Tab:Input(io)
			io = io or {}
			local r = row(host(38), 36)
			rowTitle(r, io.Title, nil, 158)
			local box = make("TextBox", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -12, 0.5, 0),
				Size = UDim2.fromOffset(150, 28),
				BackgroundColor3 = T.Bg,
				BorderSizePixel = 0,
				Text = tostring(io.Value or io.Default or ""),
				PlaceholderText = tostring(io.Placeholder or ""),
				PlaceholderColor3 = T.Muted,
				TextColor3 = T.Text,
				TextSize = 12,
				Font = Enum.Font.Gotham,
				ClearTextOnFocus = false,
				Parent = r,
			}, { corner(7), stroke(T.Edge, 0.3), pad(8, 8, 0, 0) })
			pcall(function()
				box.FocusLost:Connect(function()
					local ok, err = pcall(io.Callback or function() end, box.Text)
					if not ok then warn("[MollyMenu] " .. tostring(io.Title) .. ": " .. tostring(err)) end
				end)
			end)
			local api = { Instance = r }
			function api:Set(t) pcall(function() box.Text = tostring(t or "") end) end
			function api:Get() return box.Text end
			reg(io.Title, function() return box.Text end, function(v) api:Set(v) end)
			return api
		end

		function Tab:Keybind(ko)
			ko = ko or {}
			local key = tostring(fits(ko, "Value", "Default", "Key") or "")
			local desc = fits(ko, "Desc", "Description")
			local hasDesc = desc ~= nil and tostring(desc) ~= ""
			local h = hasDesc and 44 or 34
			local r = row(host(h + 2), h)
			rowTitle(r, ko.Title, hasDesc and desc or nil, 106)
			local chip = make("TextButton", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -12, 0.5, 0),
				Size = UDim2.fromOffset(96, 28),
				BackgroundColor3 = T.Bg,
				BorderSizePixel = 0,
				Text = (key ~= "" and key or "none"),
				TextColor3 = key ~= "" and T.Text or T.Muted,
				TextSize = 12,
				Font = Enum.Font.GothamMedium,
				AutoButtonColor = false,
				Parent = r,
			}, { corner(7), stroke(T.Edge, 0.3) })
			local api = { Instance = r }
			local listening = false
			local function paint()
				chip.Text = listening and "press a key..." or (key ~= "" and key or "none")
				chip.TextColor3 = (key ~= "" and not listening) and T.Text or T.Muted
				chip.BackgroundColor3 = listening and T.Hover or T.Bg
			end
			pcall(function()
				chip.MouseButton1Click:Connect(function()
					listening = not listening
					paint()
				end)
				UserInputService.InputBegan:Connect(function(input, typed)
					local code = input.KeyCode
					if listening then
						if code == Enum.KeyCode.Escape or code == Enum.KeyCode.Backspace then
							key = ""
						elseif code and code ~= Enum.KeyCode.Unknown then
							key = tostring(code):gsub("^Enum%.KeyCode%.", "")
						end
						listening = false
						paint()
						pcall(ko.Callback or function() end, key)
						return
					end
					if typed or key == "" then return end
					if tostring(code):gsub("^Enum%.KeyCode%.", "") == key then
						pcall(ko.OnPress or ko.Pressed or function() end)
					end
				end)
			end)
			function api:Set(k) key = tostring(k or "") paint() end
			function api:Get() return key end
			reg(ko.Title, function() return key end, function(v) api:Set(v) end)
			return api
		end

		function Tab:Colorpicker(co)
			co = co or {}
			local colr = co.Default or co.Value or Color3.fromRGB(255, 255, 255)
			local r = row(host(38), 36)
			rowTitle(r, co.Title, nil, 76)
			local swatch = make("TextButton", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -12, 0.5, 0),
				Size = UDim2.fromOffset(46, 26),
				BackgroundColor3 = colr,
				BorderSizePixel = 0,
				Text = "",
				AutoButtonColor = false,
				Parent = r,
			}, { corner(7), stroke(T.Edge, 0.2) })
			-- three sliders under it, opened by the swatch: hue, saturation, value
			local drawer = make("Frame", {
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				Visible = false,
				Parent = r.Parent,
			}, { list(5) })
			local h0, s0, v0 = 0, 1, 1
			pcall(function() h0, s0, v0 = Color3.toHSV(colr) end)
			local hsv = { h0 or 0, s0 or 1, v0 or 1 }
			local function push()
				local c = Color3.fromHSV(hsv[1], hsv[2], hsv[3])
				swatch.BackgroundColor3 = c
				local ok, err = pcall(co.Callback or function() end, c)
				if not ok then warn("[MollyMenu] " .. tostring(co.Title) .. ": " .. tostring(err)) end
			end
			for i, nm in ipairs({ "hue", "saturation", "brightness" }) do
				local bar = make("Frame", {
					Size = UDim2.new(1, 0, 0, 26),
					BackgroundColor3 = T.Panel2,
					BorderSizePixel = 0,
					Parent = drawer,
				}, { corner(7), stroke(T.Edge, 0.45) })
				make("TextLabel", {
					Position = UDim2.fromOffset(10, 0),
					Size = UDim2.new(0, 78, 1, 0),
					BackgroundTransparency = 1,
					Text = nm,
					TextColor3 = T.Muted,
					TextSize = 11,
					Font = Enum.Font.Gotham,
					TextXAlignment = Enum.TextXAlignment.Left,
					Parent = bar,
				})
				local tr = make("Frame", {
					Position = UDim2.new(0, 92, 0.5, -3),
					Size = UDim2.new(1, -104, 0, 6),
					BackgroundColor3 = T.Off,
					BorderSizePixel = 0,
					Parent = bar,
				}, { corner(99) })
				local fl = make("Frame", {
					Size = UDim2.fromScale(hsv[i], 1),
					BackgroundColor3 = T.Accent,
					BorderSizePixel = 0,
					Parent = tr,
				}, { corner(99) })
				local hit = make("TextButton", {
					Position = UDim2.fromOffset(0, -8),
					Size = UDim2.new(1, 0, 1, 16),
					BackgroundTransparency = 1,
					Text = "",
					Parent = tr,
				})
				local dragging = false
				local function at(x)
					local ax = num(tr.AbsolutePosition and tr.AbsolutePosition.X, nil)
					local aw = num(tr.AbsoluteSize and tr.AbsoluteSize.X, nil)
					if not ax or not aw or aw <= 0 then return end
					hsv[i] = math.clamp((num(x, ax) - ax) / aw, 0, 1)
					fl.Size = UDim2.fromScale(hsv[i], 1)
					push()
				end
				pcall(function()
					hit.InputBegan:Connect(function(input)
						local ty = input.UserInputType
						if ty == Enum.UserInputType.MouseButton1 or ty == Enum.UserInputType.Touch then
							dragging = true
							at(input.Position and input.Position.X)
						end
					end)
					UserInputService.InputChanged:Connect(function(input)
						if dragging then at(input.Position and input.Position.X) end
					end)
					UserInputService.InputEnded:Connect(function() dragging = false end)
				end)
			end
			pcall(function()
				swatch.MouseButton1Click:Connect(function()
					drawer.Visible = not drawer.Visible
				end)
			end)
			local api = { Instance = r }
			function api:Set(c)
				pcall(function()
					swatch.BackgroundColor3 = c
					hsv = { Color3.toHSV(c) }
				end)
			end
			reg(co.Title, function()
				local c = swatch.BackgroundColor3
				return { r = num(c and c.R, 1), g = num(c and c.G, 1), b = num(c and c.B, 1) }
			end, function(v)
				if type(v) ~= "table" then return end
				local c = Color3.new(num(v.r, 1), num(v.g, 1), num(v.b, 1))
				api:Set(c)
				pcall(co.Callback or function() end, c)
			end)
			return api
		end

		function Tab:Dropdown(dobj)
			dobj = dobj or {}
			local values = dobj.Values or {}
			local multi = dobj.Multi == true
			local chosen = {}
			if multi then
				for _, v in ipairs(dobj.Value or {}) do chosen[tostring(v)] = true end
			elseif dobj.Value ~= nil then
				chosen[tostring(dobj.Value)] = true
			end
			local desc = fits(dobj, "Desc", "Description")
			local hasDesc = desc ~= nil and tostring(desc) ~= ""
			local h = hasDesc and 44 or 34
			local r = row(host(h + 2), h)
			rowTitle(r, dobj.Title, hasDesc and desc or nil, 148)
			local function label()
				local out = {}
				for _, v in ipairs(values) do
					if chosen[tostring(v)] then out[#out + 1] = tostring(v) end
				end
				if #out == 0 then return "none" end
				if #out <= 2 then return table.concat(out, ", ") end
				return #out .. " selected"
			end
			local shown = make("TextButton", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -12, 0.5, 0),
				Size = UDim2.fromOffset(138, 28),
				BackgroundColor3 = T.Bg,
				BorderSizePixel = 0,
				Text = label(),
				TextColor3 = T.Text,
				TextSize = 12,
				Font = Enum.Font.GothamMedium,
				TextTruncate = Enum.TextTruncate.AtEnd,
				AutoButtonColor = false,
				Parent = r,
			}, { corner(7), stroke(T.Edge, 0.3), pad(9, 20, 0, 0) })
			icon(shown, "caret", 8, T.Faint).Position = UDim2.new(1, -10, 0.5, 0)
			local drawer = make("ScrollingFrame", {
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				CanvasSize = UDim2.new(),
				ScrollBarThickness = 2,
				ScrollBarImageColor3 = T.Accent,
				BackgroundColor3 = T.Panel2,
				BorderSizePixel = 0,
				Visible = false,
				Parent = r.Parent,
			}, { corner(9), stroke(T.Edge, 0.4), list(4), pad(6, 6, 6, 6) })
			local api = { Instance = r }
			local function fire()
				if multi then
					local out = {}
					for _, v in ipairs(values) do
						if chosen[tostring(v)] then out[#out + 1] = tostring(v) end
					end
					pcall(dobj.Callback or function() end, out)
				else
					for _, v in ipairs(values) do
						if chosen[tostring(v)] then
							pcall(dobj.Callback or function() end, tostring(v))
							return
						end
					end
					pcall(dobj.Callback or function() end, nil)
				end
			end
			local function build()
				for _, c in ipairs(drawer:GetChildren()) do
					if c:IsA("TextButton") then c:Destroy() end
				end
				for i, v in ipairs(values) do
					local nameV = tostring(v)
					local item = make("TextButton", {
						Size = UDim2.new(1, 0, 0, 28),
						BackgroundColor3 = chosen[nameV] and T.Accent or T.Bg,
						BorderSizePixel = 0,
						Text = nameV,
						TextColor3 = chosen[nameV] and Color3.fromRGB(255, 255, 255) or T.Text,
						TextSize = 12,
						Font = Enum.Font.Gotham,
						TextXAlignment = Enum.TextXAlignment.Left,
						AutoButtonColor = false,
						LayoutOrder = i,
						Parent = drawer,
					}, { corner(6), pad(9, 9, 0, 0) })
					pcall(function()
						item.MouseButton1Click:Connect(function()
							if multi then
								chosen[nameV] = not chosen[nameV] or nil
							else
								chosen = { [nameV] = true }
								drawer.Visible = false
							end
							shown.Text = label()
							build()
							fire()
						end)
					end)
				end
				drawer.Size = UDim2.new(1, 0, 0, math.min(#values * 32 + 12, 168))
			end
			build()
			pcall(function()
				shown.MouseButton1Click:Connect(function()
					drawer.Visible = not drawer.Visible
				end)
			end)
			function api:Refresh(vals)
				values = vals or {}
				for k in pairs(chosen) do
					local keep = false
					for _, v in ipairs(values) do if tostring(v) == k then keep = true end end
					if not keep then chosen[k] = nil end
				end
				shown.Text = label()
				build()
			end
			function api:Select(vals)
				chosen = {}
				if type(vals) == "table" then
					for _, v in ipairs(vals) do chosen[tostring(v)] = true end
				elseif vals ~= nil then
					chosen[tostring(vals)] = true
				end
				shown.Text = label()
				build()
			end
			function api:Get()
				local out = {}
				for _, v in ipairs(values) do
					if chosen[tostring(v)] then out[#out + 1] = tostring(v) end
				end
				return multi and out or out[1]
			end
			reg(dobj.Title, function() return api:Get() end, function(v)
				api:Select(v)
				fire()
			end)
			return api
		end

		-- A GROUP on a page: its own heading, its own card, and every widget call
		-- forwarded to this tab. It lets several of the old pages share one tab
		-- without their rows running into each other.
		local WIDGETS = { "Section", "Divider", "Space", "Paragraph", "Button", "Toggle",
			"Slider", "Input", "Keybind", "Colorpicker", "Dropdown", "Label" }
		function Tab:Sub(title)
			local ctx = { title = tostring(title or ""), card = nil }
			local S = { _ctx = ctx, _parent = Tab, Instance = P.page }
			for _, m in ipairs(WIDGETS) do
				S[m] = function(_, arg)
					local prev = Tab._ctx
					Tab._ctx = ctx
					local a1, a2 = Tab[m](Tab, arg)
					Tab._ctx = prev
					return a1, a2
				end
			end
			function S:Sub(t) return Tab:Sub(t) end
			return S
		end

		-- names the old library also answered to
		Tab.Label = Tab.Paragraph
		Tab.Dropdown_Multi = Tab.Dropdown
		return Tab, P
	end

	--== tabs ===================================================================
	local order = 0
	local function addTab(to)
		to = to or {}
		order = order + 1
		local name = tostring(to.Title or ("Page " .. order))
		local subtitle = tostring(to.Desc or to.SubTitle or "")
		local Tab, P = mkTab(name, to.Icon, subtitle)

		local btn = make("TextButton", {
			Name = name .. "Tab",
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, 38),
			BackgroundColor3 = T.Panel2,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = false,
			Parent = tabbar,
		}, { corner(8) })
		local mark = make("Frame", {
			Name = "Mark",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 0, 0.5, 0),
			Size = UDim2.fromOffset(2, 18),
			BackgroundColor3 = T.Accent,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = btn,
		}, { corner(99) })
		local ico = make("Frame", {
			Name = "IconHolder",
			Position = UDim2.fromOffset(10, 0),
			Size = UDim2.fromOffset(22, 38),
			BackgroundTransparency = 1,
			Parent = btn,
		})
		local icoBits = icon(ico, to.Icon, 15, T.Faint)
		local lab = make("TextLabel", {
			Name = "Label",
			Position = UDim2.fromOffset(38, 0),
			Size = UDim2.new(1, -46, 1, 0),
			BackgroundTransparency = 1,
			Text = name:upper(),
			TextColor3 = T.Muted,
			TextSize = 11,
			Font = Enum.Font.GothamBold,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = btn,
		})
		Tab._btn, Tab._label, Tab._icon, Tab._mark = btn, lab, ico, mark
		Tab._icoBits = icoBits
		Tab.Name = name
		W._tabs[#W._tabs + 1] = Tab
		W._pages[name] = P

		local function select()
			if W._cur == name then return end
			-- there is no page title in this layout: the group headings do that job,
			-- and the strip at the top belongs to the config
			W._cur = name
			for _, t in ipairs(W._tabs) do
				local on = t.Name == name
				tween(t._btn, 0.15, { BackgroundTransparency = on and 0 or 1 })
				for _, piece in ipairs(t._icoBits and t._icoBits:GetDescendants() or {}) do
					if piece:IsA("Frame") then
						tween(piece, 0.15, { BackgroundColor3 = on and T.Accent or T.Faint })
					elseif piece:IsA("UIStroke") then
						pcall(function() piece.Color = on and T.Accent or T.Faint end)
					end
				end
				tween(t._label, 0.15, { TextColor3 = on and T.Text or T.Muted })
				tween(t._mark, 0.15, { BackgroundTransparency = on and 0 or 1 })
				t._page.page.Visible = on
			end
		end
		Tab.Select = select
		pcall(function()
			btn.MouseButton1Click:Connect(select)
			btn.MouseEnter:Connect(function()
				if W._cur ~= name then tween(btn, 0.12, { BackgroundTransparency = 0.55 }) end
			end)
			btn.MouseLeave:Connect(function()
				if W._cur ~= name then tween(btn, 0.12, { BackgroundTransparency = 1 }) end
			end)
		end)
		if not W._cur then select() end
		if W._applyRail then W._applyRail() end
		return Tab
	end

	function W:Tab(to) return addTab(to) end

	-- A Section on the window is a heading in the sidebar with tabs under it.
	function W:Section(so)
		so = so or {}
		order = order + 1
		make("TextLabel", {
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, 22),
			BackgroundTransparency = 1,
			Text = tostring(so.Title or ""):upper(),
			TextColor3 = T.Muted,
			TextSize = 10,
			Font = Enum.Font.GothamBold,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTransparency = 0.25,
			Parent = tabbar,
		}, { pad(12, 0, 6, 0) })
		return { Tab = function(_, to) return addTab(to) end }
	end

	function W:Divider()
		order = order + 1
		make("Frame", {
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, 1),
			BackgroundColor3 = T.Edge,
			BackgroundTransparency = 0.4,
			BorderSizePixel = 0,
			Parent = tabbar,
		})
		return self
	end

	--== the settings the menu itself has ======================================
	-- Live recolouring without a registry of every object: a colour is swapped by
	-- walking the window and replacing exactly the old value with the new one.
	-- Nothing has to remember it uses the accent, so widgets built later pick the
	-- change up too.
	-- ONE walk, however many colours are changing. Six separate walks of a window
	-- with three thousand objects in it is where the two to four seconds went when
	-- you switched the background. Anything inside the settings panel is left
	-- alone, or picking a colour would repaint the swatch you picked it from and
	-- every swatch beside it.
	local settingsPanel                     -- assigned when the panel is built
	local function recolour(pairsList)
		local n = 0
		for _, e in ipairs(pairsList) do
			if e[1] ~= e[2] then n = n + 1 end
		end
		if n == 0 then return end
		pcall(function()
			local skip = settingsPanel
			for _, d in ipairs(gui:GetDescendants()) do
				local inPanel = false
				if skip then
					local node = d
					for _ = 1, 6 do
						if node == skip then inPanel = true break end
						node = node.Parent
						if not node then break end
					end
				end
				if not inPanel then
					if d:IsA("UIStroke") then
						for _, e in ipairs(pairsList) do
							if d.Color == e[1] then d.Color = e[2] break end
						end
					elseif d:IsA("GuiObject") then
						for _, e in ipairs(pairsList) do
							if d.BackgroundColor3 == e[1] then d.BackgroundColor3 = e[2] break end
						end
						if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
							for _, e in ipairs(pairsList) do
								if d.TextColor3 == e[1] then d.TextColor3 = e[2] break end
							end
						end
						if d:IsA("ScrollingFrame") then
							for _, e in ipairs(pairsList) do
								if d.ScrollBarImageColor3 == e[1] then
									d.ScrollBarImageColor3 = e[2]
									break
								end
							end
						end
						if d:IsA("ImageLabel") or d:IsA("ImageButton") then
							for _, e in ipairs(pairsList) do
								if d.ImageColor3 == e[1] then d.ImageColor3 = e[2] break end
							end
						end
					end
				end
			end
		end)
	end

	local afterAccent                        -- the panel refreshes its own chips
	local function setAccent(c)
		local was = T.Accent
		if was == c then return end
		T.Accent = c
		recolour({ { was, c } })
		pcall(function()
			for _, g in ipairs(logo:GetChildren()) do
				if g:IsA("UIGradient") then
					g.Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
						ColorSequenceKeypoint.new(1, c),
					})
				end
			end
		end)
		if afterAccent then afterAccent() end
	end

	-- Tones are generated from one hue, one saturation and a ramp, so the six
	-- panel shades always sit together instead of being six numbers typed by hand.
	local function ramp(h, sat, base)
		local steps = { 0, 0.028, 0.055, 0.085, 0.12, 0.165 }
		local keys = { "Bg", "Rail", "Panel", "Panel2", "Hover", "Edge" }
		local out = {}
		for i, k in ipairs(keys) do
			local v = math.clamp(base + steps[i], 0, 1)
			local s2 = sat * (1 - i * 0.06)
			out[k] = Color3.fromHSV(h, math.clamp(s2, 0, 1), v)
		end
		return out
	end
	local TONES = {
		Midnight = ramp(0.62, 0.30, 0.045),
		Graphite = ramp(0.62, 0.05, 0.075),
		Mono     = ramp(0.00, 0.00, 0.035),
		Ocean    = ramp(0.52, 0.36, 0.055),
		Orchid   = ramp(0.79, 0.32, 0.055),
		Forest   = ramp(0.38, 0.28, 0.045),
		Wine     = ramp(0.97, 0.34, 0.050),
		Sand     = ramp(0.09, 0.22, 0.060),
	}
	local TONE_NAMES = { "Midnight", "Graphite", "Mono", "Ocean",
		"Orchid", "Forest", "Wine", "Sand" }
	local toneNow = "Midnight"
	local afterTone
	local function setTone(nm)
		local t = TONES[nm]
		if not t then return end
		toneNow = nm
		local list = {}
		local keys = { "Bg", "Rail", "Panel", "Panel2", "Hover", "Edge" }
		for _, k in ipairs(keys) do list[#list + 1] = { T[k], t[k] } end
		recolour(list)
		for _, k in ipairs(keys) do T[k] = t[k] end
		pcall(function() card.BackgroundColor3 = T.Bg end)
		if afterTone then afterTone() end
	end

	--== weather ================================================================
	-- Drawn behind the page, out of frames, on one loop that only runs while an
	-- effect is on. The group panels are solid, so it shows in the space around
	-- them the way weather behind a window should.
	local fxLayer = make("Frame", {
		Name = "Weather",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 0,
		ClipsDescendants = true,
		Parent = card,
	})
	local FX_KINDS = { "None", "Rain", "Snow", "Embers", "Stars", "Bubbles", "Aurora" }
	local weather = { kind = "None", amount = 1, bits = {}, conn = nil }

	local function clearWeather()
		if weather.conn then pcall(function() weather.conn:Disconnect() end) weather.conn = nil end
		for _, b in ipairs(weather.bits) do pcall(function() b.f:Destroy() end) end
		weather.bits = {}
	end

	local function newBit(kind)
		local b = { x = math.random(), y = math.random(), seed = math.random() * 6.28 }
		local f
		if kind == "Rain" then
			b.v = 0.9 + math.random() * 0.8
			f = make("Frame", {
				Size = UDim2.fromOffset(1, 11 + math.random(0, 9)),
				BackgroundColor3 = T.Accent,
				BackgroundTransparency = 0.55,
				BorderSizePixel = 0,
				Rotation = 8,
				Parent = fxLayer,
			})
		elseif kind == "Snow" then
			b.v = 0.1 + math.random() * 0.12
			local d = 2 + math.random(0, 2)
			f = make("Frame", {
				Size = UDim2.fromOffset(d, d),
				BackgroundColor3 = Color3.fromRGB(255, 255, 255),
				BackgroundTransparency = 0.35,
				BorderSizePixel = 0,
				Parent = fxLayer,
			}, { corner(99) })
		elseif kind == "Embers" then
			b.v = -(0.12 + math.random() * 0.16)
			local d = 2 + math.random(0, 2)
			f = make("Frame", {
				Size = UDim2.fromOffset(d, d),
				BackgroundColor3 = T.Accent,
				BackgroundTransparency = 0.3,
				BorderSizePixel = 0,
				Parent = fxLayer,
			}, { corner(99) })
		elseif kind == "Bubbles" then
			b.v = -(0.05 + math.random() * 0.08)
			local d = 5 + math.random(0, 12)
			f = make("Frame", {
				Size = UDim2.fromOffset(d, d),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Parent = fxLayer,
			}, { corner(99), stroke(T.Accent, 0.55, 1) })
		elseif kind == "Aurora" then
			b.v = 0.02 + math.random() * 0.03
			f = make("Frame", {
				Size = UDim2.new(0.7, 0, 0, 90 + math.random(0, 80)),
				BackgroundColor3 = T.Accent,
				BackgroundTransparency = 0.9,
				BorderSizePixel = 0,
				Rotation = -12 + math.random(0, 24),
				Parent = fxLayer,
			}, { corner(99) })
		else -- Stars
			b.v = 0
			local d = 1 + math.random(0, 2)
			f = make("Frame", {
				Size = UDim2.fromOffset(d, d),
				BackgroundColor3 = Color3.fromRGB(255, 255, 255),
				BackgroundTransparency = 0.5,
				BorderSizePixel = 0,
				Parent = fxLayer,
			}, { corner(99) })
		end
		b.f = f
		return b
	end

	local function startWeather()
		clearWeather()
		local kind = weather.kind
		if kind == "None" then return end
		local counts = { Rain = 70, Snow = 55, Embers = 40, Stars = 90, Bubbles = 26, Aurora = 3 }
		local n = math.floor((counts[kind] or 40) * math.clamp(weather.amount, 0.2, 2))
		for _ = 1, n do weather.bits[#weather.bits + 1] = newBit(kind) end
		local RunService = game:GetService("RunService")
		weather.conn = RunService.RenderStepped:Connect(function(dt)
			dt = math.min(num(dt, 1 / 60), 0.1)
			local t = os.clock()
			for _, b in ipairs(weather.bits) do
				if kind == "Stars" then
					pcall(function()
						b.f.Position = UDim2.fromScale(b.x, b.y)
						b.f.BackgroundTransparency = 0.35 + 0.5 * (0.5 + 0.5 * math.sin(t * 2 + b.seed))
					end)
				elseif kind == "Aurora" then
					b.x = (b.x + b.v * dt) % 1.4
					pcall(function()
						b.f.Position = UDim2.fromScale(b.x - 0.35, b.y * 0.8)
						b.f.BackgroundTransparency = 0.86 + 0.08 * math.sin(t * 0.6 + b.seed)
					end)
				else
					b.y = b.y + b.v * dt
					if b.y > 1.05 then b.y = -0.05 b.x = math.random() end
					if b.y < -0.05 then b.y = 1.05 b.x = math.random() end
					local sway = (kind == "Snow" or kind == "Bubbles")
						and math.sin(t * 1.2 + b.seed) * 0.02 or 0
					pcall(function()
						b.f.Position = UDim2.fromScale(math.clamp(b.x + sway, -0.05, 1.05), b.y)
					end)
				end
			end
		end)
	end

	--== the settings panel =====================================================
	local setBtn = make("TextButton", {
		Name = "Settings",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 190, 0.5, 0),
		Size = UDim2.fromOffset(30, 28),
		BackgroundColor3 = T.Panel,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		Parent = bar,
	}, { corner(8), stroke(T.Edge, 0.45) })
	icon(setBtn, "gear", 13, T.Muted)

	local panel = make("Frame", {
		Name = "SettingsPanel",
		Position = UDim2.fromOffset(190, barH - 4),
		Size = UDim2.fromOffset(266, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = T.Panel,
		BorderSizePixel = 0,
		Visible = false,
		Active = true,          -- a Frame does not stop a click; this does
		ZIndex = 9,
		Parent = content,
	}, { corner(10), stroke(T.Edge, 0.35), pad(10, 10, 10, 12), list(8) })
	settingsPanel = panel
	-- if it ever grows past the page, it scrolls rather than running off the bottom
	pcall(function()
		panel:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			local room = num(content.AbsoluteSize and content.AbsoluteSize.Y, 0) - barH - 16
			local tall = num(panel.AbsoluteSize and panel.AbsoluteSize.Y, 0)
			if room > 80 and tall > room then
				panel.AutomaticSize = Enum.AutomaticSize.None
				panel.Size = UDim2.fromOffset(266, room)
				panel.ClipsDescendants = true
			end
		end)
	end)
	-- The tap-catcher goes BEHIND the panel, not inside it. Inside, its size was
	-- given relative to the panel while the panel sized itself from its children:
	-- a circle Roblox breaks by making the panel nothing at all, which is the
	-- empty plate. As a sibling it costs the layout nothing, still swallows a tap
	-- meant for the panel, and closes it when you tap away.
	local scrim = make("TextButton", {
		Name = "Scrim",
		Position = UDim2.fromOffset(0, barH),
		Size = UDim2.new(1, 0, 1, -barH),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Visible = false,
		ZIndex = 8,
		Parent = content,
	})

	local function panelHead(text, order)
		make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 16),
			BackgroundTransparency = 1,
			Text = tostring(text),
			TextColor3 = T.Muted,
			TextSize = 11,
			Font = Enum.Font.GothamBold,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = order,
			Parent = panel,
		})
	end

	-- accent swatches
	panelHead("MENU COLOUR", 1)
	local swatchRow = make("Frame", {
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = panel,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local ACCENTS = {
		{ 58, 130, 247 }, { 112, 96, 245 }, { 196, 92, 240 }, { 244, 88, 140 },
		{ 240, 104, 76 }, { 240, 176, 60 }, { 74, 205, 132 }, { 60, 200, 214 },
		{ 232, 234, 240 },
	}
	local swatches = {}
	for i, rgb in ipairs(ACCENTS) do
		local c = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		local sw = make("TextButton", {
			Size = UDim2.fromOffset(20, 20),
			BackgroundColor3 = c,
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = false,
			LayoutOrder = i,
			Parent = swatchRow,
		}, { corner(6), stroke(Color3.fromRGB(255, 255, 255), 1, 2) })
		swatches[#swatches + 1] = { btn = sw, colr = c }
		pcall(function()
			sw.MouseButton1Click:Connect(function() setAccent(c) end)
		end)
	end
	local function paintSwatches()
		for _, e in ipairs(swatches) do
			for _, k in ipairs(e.btn:GetChildren()) do
				if k:IsA("UIStroke") then
					pcall(function() k.Transparency = (e.colr == T.Accent) and 0 or 1 end)
				end
			end
		end
	end
	paintSwatches()

	-- tone
	panelHead("BACKGROUND", 3)
	-- A UIGridLayout does not grow its frame: asking AutomaticSize to work it out
	-- resolves to nothing, and the panel came up an empty plate. The height is
	-- worked out here from the number of cells instead.
	local function gridRows(count, perRow, cellH, gap)
		local rows = math.max(math.ceil(count / perRow), 1)
		return rows * cellH + (rows - 1) * gap
	end
	local toneRow = make("Frame", {
		Size = UDim2.new(1, 0, 0, gridRows(#TONE_NAMES, 4, 26, 6)),
		BackgroundTransparency = 1,
		LayoutOrder = 4,
		Parent = panel,
	}, {
		make("UIGridLayout", {
			CellSize = UDim2.fromOffset(54, 26),
			CellPadding = UDim2.fromOffset(6, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local toneBtns = {}
	for i, nm in ipairs(TONE_NAMES) do
		local swatch = TONES[nm]
		local b2 = make("TextButton", {
			Size = UDim2.fromOffset(54, 26),
			BackgroundColor3 = swatch.Panel,
			BorderSizePixel = 0,
			Text = nm,
			TextColor3 = T.Text,
			TextSize = 10,
			Font = Enum.Font.GothamMedium,
			AutoButtonColor = false,
			LayoutOrder = i,
			Parent = toneRow,
		}, { corner(6), stroke(Color3.fromRGB(255, 255, 255), 1, 2) })
		toneBtns[#toneBtns + 1] = { btn = b2, name = nm }
		pcall(function() b2.MouseButton1Click:Connect(function() setTone(nm) end) end)
	end
	local function paintTones()
		for _, e in ipairs(toneBtns) do
			for _, k in ipairs(e.btn:GetChildren()) do
				if k:IsA("UIStroke") then
					pcall(function() k.Transparency = (e.name == toneNow) and 0.2 or 1 end)
				end
			end
		end
	end
	paintTones()

	-- a small slider for the panel's own use
	local function panelSlider(label, lo, hi, def, order, onChange)
		local holder = make("Frame", {
			Size = UDim2.new(1, 0, 0, 34),
			BackgroundTransparency = 1,
			LayoutOrder = order,
			Parent = panel,
		})
		local cap = make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 14),
			BackgroundTransparency = 1,
			Text = label .. "  " .. string.format("%.2f", def),
			TextColor3 = T.Text,
			TextSize = 11,
			Font = Enum.Font.GothamMedium,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = holder,
		})
		local track = make("Frame", {
			Position = UDim2.new(0, 0, 1, -8),
			Size = UDim2.new(1, 0, 0, 5),
			BackgroundColor3 = T.Off,
			BorderSizePixel = 0,
			Parent = holder,
		}, { corner(99) })
		local fill = make("Frame", {
			Size = UDim2.fromScale((def - lo) / (hi - lo), 1),
			BackgroundColor3 = T.Accent,
			BorderSizePixel = 0,
			Parent = track,
		}, { corner(99) })
		local hit = make("TextButton", {
			Position = UDim2.fromOffset(0, -8),
			Size = UDim2.new(1, 0, 1, 16),
			BackgroundTransparency = 1,
			Text = "",
			Parent = track,
		})
		local drag = false
		local function at(x)
			local ax = num(track.AbsolutePosition and track.AbsolutePosition.X, nil)
			local aw = num(track.AbsoluteSize and track.AbsoluteSize.X, nil)
			if not ax or not aw or aw <= 0 then return end
			local k = math.clamp((num(x, ax) - ax) / aw, 0, 1)
			local v = lo + (hi - lo) * k
			cap.Text = label .. "  " .. string.format("%.2f", v)
			fill.Size = UDim2.fromScale(k, 1)
			onChange(v)
		end
		pcall(function()
			hit.InputBegan:Connect(function(input)
				local ty = input.UserInputType
				if ty == Enum.UserInputType.MouseButton1 or ty == Enum.UserInputType.Touch then
					drag = true
					at(input.Position and input.Position.X)
				end
			end)
			UserInputService.InputChanged:Connect(function(input)
				if drag then at(input.Position and input.Position.X) end
			end)
			UserInputService.InputEnded:Connect(function() drag = false end)
		end)
		return function(v)
			cap.Text = label .. "  " .. string.format("%.2f", v)
			fill.Size = UDim2.fromScale((v - lo) / (hi - lo), 1)
		end
	end

	panelHead("SIZE", 5)
	local setSizeCap = panelSlider("menu size", 0.6, 1.4, 1, 6, function(v)
		W._userScale = v
		refit()
	end)

	-- weather
	panelHead("EFFECT", 7)
	local effRow = make("Frame", {
		Size = UDim2.new(1, 0, 0, gridRows(#FX_KINDS, 3, 22, 6)),
		BackgroundTransparency = 1,
		LayoutOrder = 8,
		Parent = panel,
	}, {
		make("UIGridLayout", {
			CellSize = UDim2.fromOffset(70, 22),
			CellPadding = UDim2.fromOffset(6, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local effChips = {}
	local function paintChips()
		for nm, chip in pairs(effChips) do
			local on = (weather.kind == nm)
			pcall(function()
				chip.BackgroundColor3 = on and T.Accent or T.Panel2
				chip.TextColor3 = on and Color3.fromRGB(255, 255, 255) or T.Muted
			end)
		end
	end
	for i, nm in ipairs(FX_KINDS) do
		local chip = make("TextButton", {
			BackgroundColor3 = T.Panel2,
			BorderSizePixel = 0,
			Text = nm,
			TextColor3 = T.Muted,
			TextSize = 10,
			Font = Enum.Font.GothamMedium,
			AutoButtonColor = false,
			LayoutOrder = i,
			Parent = effRow,
		}, { corner(6) })
		effChips[nm] = chip
		pcall(function()
			chip.MouseButton1Click:Connect(function()
				weather.kind = nm
				paintChips()
				startWeather()
			end)
		end)
	end
	paintChips()
	-- the panel paints its own marks after any change, because the recolour walk
	-- deliberately skips it
	afterAccent = function()
		paintSwatches()
		paintChips()
		pcall(function()
			for _, e in ipairs(swatches) do e.btn.BackgroundColor3 = e.colr end
		end)
	end
	afterTone = function()
		paintTones()
		paintChips()
		pcall(function()
			panel.BackgroundColor3 = T.Panel
			for _, k in ipairs(panel:GetChildren()) do
				if k:IsA("UIStroke") then k.Color = T.Edge end
			end
			for _, e in ipairs(toneBtns) do e.btn.BackgroundColor3 = TONES[e.name].Panel end
			for _, l in ipairs(panel:GetDescendants()) do
				if l:IsA("TextLabel") then l.TextColor3 = T.Muted end
			end
		end)
	end
	local setAmountCap = panelSlider("how much", 0.2, 2, 1, 9, function(v)
		weather.amount = v
		if weather.kind ~= "None" then startWeather() end
	end)

	pcall(function()
		setBtn.MouseButton1Click:Connect(function()
			panel.Visible = not panel.Visible
			scrim.Visible = panel.Visible
			if cfgList then cfgList.Visible = false end
		end)
		scrim.MouseButton1Click:Connect(function()
			panel.Visible = false
			scrim.Visible = false
		end)
		setBtn.MouseEnter:Connect(function() tween(setBtn, 0.12, { BackgroundColor3 = T.Hover }) end)
		setBtn.MouseLeave:Connect(function() tween(setBtn, 0.12, { BackgroundColor3 = T.Panel }) end)
	end)

	-- the look travels with a config, so a saved config brings its menu back too
	W._reg[#W._reg + 1] = { key = "menu/accent",
		get = function()
			local c = T.Accent
			return { r = c.R, g = c.G, b = c.B }
		end,
		set = function(v)
			if type(v) == "table" then
				setAccent(Color3.new(num(v.r, 0.2), num(v.g, 0.5), num(v.b, 1)))
			end
		end }
	W._reg[#W._reg + 1] = { key = "menu/tone",
		get = function() return toneNow end,
		set = function(v) setTone(tostring(v)) end }
	W._reg[#W._reg + 1] = { key = "menu/size",
		get = function() return num(W._userScale, 1) end,
		set = function(v)
			W._userScale = num(v, 1)
			setSizeCap(W._userScale)
			refit()
		end }
	W._reg[#W._reg + 1] = { key = "menu/effect",
		get = function() return weather.kind end,
		set = function(v)
			weather.kind = tostring(v)
			paintChips()
			startWeather()
		end }
	W._reg[#W._reg + 1] = { key = "menu/effectAmount",
		get = function() return weather.amount end,
		set = function(v)
			weather.amount = num(v, 1)
			setAmountCap(weather.amount)
			if weather.kind ~= "None" then startWeather() end
		end }

	--== show, hide, drag =======================================================
	local open = true
	local function setOpen(v)
		open = v and true or false
		card.Visible = open
		shade.Visible = open
		if open then
			card.GroupTransparency = 1
			tween(card, 0.18, { GroupTransparency = 0 })
			refit()
		end
	end
	W.Toggle = function() setOpen(not open) end
	W.SetOpen = function(_, v) setOpen(v) end
	W.Destroy = function() pcall(function() gui:Destroy() end) end
	W.Close = W.Destroy

	local reopen = make("TextButton", {
		Name = "Reopen",
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.fromOffset(16, 16),
		Size = UDim2.fromOffset(126, 34),
		BackgroundColor3 = T.Panel,
		BorderSizePixel = 0,
		Text = tostring((o.OpenButton and o.OpenButton.Title) or o.Title or "Molly Hub"),
		TextColor3 = T.Text,
		TextSize = 12,
		Font = Enum.Font.GothamBold,
		AutoButtonColor = false,
		Visible = false,
		Parent = gui,
	}, { corner(10), stroke(T.Edge, 0.2) })
	pcall(function()
		reopen.MouseButton1Click:Connect(function() setOpen(true) end)
		closeBtn.MouseButton1Click:Connect(function() setOpen(false) end)
		closeBtn.MouseEnter:Connect(function()
			tween(closeBtn, 0.12, { BackgroundColor3 = T.Bad,
				TextColor3 = Color3.fromRGB(255, 255, 255) })
		end)
		closeBtn.MouseLeave:Connect(function()
			tween(closeBtn, 0.12, { BackgroundColor3 = T.Panel2, TextColor3 = T.Muted })
		end)
	end)
	-- the reopen button only matters while the window is away
	task.spawn(function()
		while gui.Parent do
			pcall(function() reopen.Visible = not open end)
			task.wait(0.4)
		end
	end)

	local toggleKey = Enum.KeyCode.RightShift
	function W:SetToggleKey(k)
		if typeof and typeof(k) == "EnumItem" then toggleKey = k
		elseif type(k) == "string" and k ~= "" then
			pcall(function() toggleKey = Enum.KeyCode[k] end)
		end
		pcall(function()
			local nm = tostring(toggleKey):gsub("^Enum%.KeyCode%.", "")
			reopen.Text = tostring(o.Title or "Molly Hub") .. "   " .. nm
		end)
		return self
	end
	W:SetToggleKey(toggleKey)
	pcall(function()
		UserInputService.InputBegan:Connect(function(input, typed)
			if typed then return end
			if input.KeyCode == toggleKey then setOpen(not open) end
		end)
	end)

	local dragging, from, at0 = false, nil, nil
	pcall(function()
		local function grip(where)
			where.InputBegan:Connect(function(input)
				local t = input.UserInputType
				if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
					dragging = true
					from = input.Position
					at0 = card.Position
				end
			end)
		end
		grip(head)
		grip(bar)
		UserInputService.InputChanged:Connect(function(input)
			if not dragging or not from or not at0 then return end
			local t = input.UserInputType
			if t ~= Enum.UserInputType.MouseMovement and t ~= Enum.UserInputType.Touch then return end
			local dx = num(input.Position and input.Position.X, 0) - num(from.X, 0)
			local dy = num(input.Position and input.Position.Y, 0) - num(from.Y, 0)
			card.Position = UDim2.new(at0.X.Scale, num(at0.X.Offset, 0) + dx,
				at0.Y.Scale, num(at0.Y.Offset, 0) + dy)
			shade.Position = card.Position
		end)
		UserInputService.InputEnded:Connect(function(input)
			local t = input.UserInputType
			if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
				dragging = false
			end
		end)
	end)

	-- the old library let you set the strip in the top bar
	function W:Tag(text) pcall(function() cfgText.Text = tostring(text or "") end) return self end
	W.SetHint = W.Tag
	function W:SetIconSize() return self end

	--== configs ================================================================
	-- Every widget registered its value, so a config is that list written out.
	-- Files where the executor has them, memory where it does not, so the page
	-- works either way instead of erroring.
	local FOLDER = tostring(o.Folder or "MollyHub")
	local memory = {}
	local HS = game:GetService("HttpService")

	local function canFiles()
		return type(writefile) == "function" and type(readfile) == "function"
	end
	local function ensureFolder()
		pcall(function()
			if type(isfolder) == "function" and type(makefolder) == "function" then
				if not isfolder(FOLDER) then makefolder(FOLDER) end
				if not isfolder(FOLDER .. "/configs") then makefolder(FOLDER .. "/configs") end
			end
		end)
	end
	local function pathFor(nm) return FOLDER .. "/configs/" .. tostring(nm) .. ".json" end

	local function readAll()
		local out = {}
		if canFiles() then
			pcall(function()
				if type(listfiles) ~= "function" then return end
				for _, f in ipairs(listfiles(FOLDER .. "/configs") or {}) do
					local nm = tostring(f):match("([^/\\]+)%.json$")
					if nm then out[#out + 1] = nm end
				end
			end)
		end
		for nm in pairs(memory) do
			local seen = false
			for _, v in ipairs(out) do if v == nm then seen = true end end
			if not seen then out[#out + 1] = nm end
		end
		table.sort(out)
		return out
	end

	local function loadRaw(nm)
		if memory[nm] then return memory[nm] end
		local data
		pcall(function()
			if canFiles() and type(isfile) == "function" and isfile(pathFor(nm)) then
				data = HS:JSONDecode(readfile(pathFor(nm)))
			end
		end)
		return data
	end

	local function saveRaw(nm, data)
		memory[nm] = data
		local wrote = false
		pcall(function()
			if canFiles() then
				ensureFolder()
				writefile(pathFor(nm), HS:JSONEncode(data))
				wrote = true
			end
		end)
		return wrote or true          -- memory counts as saved for this session
	end

	local CM = {}
	local function configObject(nm)
		local C = { Name = nm }
		function C:Save()
			local vals = {}
			for _, e in ipairs(W._reg) do
				local ok, v = pcall(e.get)
				if ok and v ~= nil then vals[e.key] = v end
			end
			local was = loadRaw(nm) or {}
			return saveRaw(nm, { Values = vals, AutoLoad = was.AutoLoad or false })
		end
		function C:Load()
			local data = loadRaw(nm)
			if type(data) ~= "table" or type(data.Values) ~= "table" then return false end
			for _, e in ipairs(W._reg) do
				local v = data.Values[e.key]
				if v ~= nil then pcall(e.set, v) end
			end
			return true
		end
		function C:SetAutoLoad(on)
			local data = loadRaw(nm) or { Values = {} }
			data.AutoLoad = on and true or false
			saveRaw(nm, data)
			return true
		end
		function C:GetAutoLoad()
			local data = loadRaw(nm)
			return type(data) == "table" and data.AutoLoad == true
		end
		return C
	end

	function CM:AllConfigs() return readAll() end
	function CM:Config(nm) return configObject(tostring(nm or "default")) end
	function CM:CreateConfig(nm) return configObject(tostring(nm or "default")) end
	function CM:GetConfig(nm)
		local data = loadRaw(tostring(nm or "default"))
		return type(data) == "table" and data or { Values = {}, AutoLoad = false }
	end
	function CM:GetAutoLoadConfigs()
		local out = {}
		for _, nm in ipairs(readAll()) do
			local data = loadRaw(nm)
			if type(data) == "table" and data.AutoLoad then out[#out + 1] = nm end
		end
		return out
	end
	W.ConfigManager = CM
	W.CurrentConfig = configObject("default")

	--== the config strip does what it looks like it does =======================
	local picked = "default"
	cfgList = make("ScrollingFrame", {
		Name = "ConfigList",
		Active = true,
		Position = UDim2.fromOffset(52, barH - 4),
		Size = UDim2.fromOffset(132, 0),
		BackgroundColor3 = T.Panel,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 2,
		ScrollBarImageColor3 = T.Edge,
		Visible = false,
		ZIndex = 8,
		Parent = content,
	}, { corner(8), stroke(T.Edge, 0.4), list(3), pad(5, 5, 5, 5) })

	local function drawList()
		for _, c in ipairs(cfgList:GetChildren()) do
			if c:IsA("TextButton") then c:Destroy() end
		end
		local all = CM:AllConfigs()
		if #all == 0 then all = { "default" } end
		for i, nm in ipairs(all) do
			local item = make("TextButton", {
				Size = UDim2.new(1, 0, 0, 26),
				BackgroundColor3 = (nm == picked) and T.Accent or T.Bg,
				BorderSizePixel = 0,
				Text = nm,
				TextColor3 = (nm == picked) and Color3.fromRGB(255, 255, 255) or T.Text,
				TextSize = 12,
				Font = Enum.Font.Gotham,
				TextXAlignment = Enum.TextXAlignment.Left,
				AutoButtonColor = false,
				LayoutOrder = i,
				Parent = cfgList,
			}, { corner(6), pad(8, 8, 0, 0) })
			pcall(function()
				item.MouseButton1Click:Connect(function()
					picked = nm
					cfgText.Text = nm
					cfgList.Visible = false
					W.CurrentConfig = configObject(nm)
					if W.CurrentConfig:Load() then
						UI:Notify({ Title = "Config", Content = "loaded " .. nm })
					end
					drawList()
				end)
			end)
		end
		cfgList.Size = UDim2.fromOffset(132, math.min(#all * 29 + 10, 190))
	end
	drawList()

	pcall(function()
		cfgPill.MouseButton1Click:Connect(function()
			cfgList.Visible = not cfgList.Visible
			if cfgList.Visible then drawList() end
			panel.Visible = false
			scrim.Visible = false
		end)
		saveBtn.MouseButton1Click:Connect(function()
			W.CurrentConfig = configObject(picked)
			if W.CurrentConfig:Save() then
				UI:Notify({ Title = "Config", Content = "saved " .. picked })
			end
			drawList()
		end)
		saveBtn.MouseEnter:Connect(function()
			tween(saveBtn, 0.12, { BackgroundColor3 = T.Hover, TextColor3 = T.Text })
		end)
		saveBtn.MouseLeave:Connect(function()
			tween(saveBtn, 0.12, { BackgroundColor3 = T.Panel, TextColor3 = T.Muted })
		end)
	end)

	-- the magnifier: type a word and only the rows that match stay on the page
	pcall(function()
		searchBtn.MouseButton1Click:Connect(function()
			searchBox.Visible = not searchBox.Visible
			if searchBox.Visible then
				pcall(function() searchBox:CaptureFocus() end)
			else
				searchBox.Text = ""
			end
		end)
		local function apply()
			local q = tostring(searchBox.Text or ""):lower()
			for _, t in ipairs(W._tabs) do
				for _, colFrame in ipairs(t._cols or {}) do
					for _, box in ipairs(colFrame:GetChildren()) do
						if box:IsA("Frame") then
							local anyShown, rows = false, 0
							for _, r in ipairs(box:GetChildren()) do
								if r:IsA("Frame") or r:IsA("TextButton") then
									rows = rows + 1
									local text = ""
									for _, l in ipairs(r:GetDescendants()) do
										if l:IsA("TextLabel") then text = text .. " " .. tostring(l.Text) end
									end
									if r:IsA("TextButton") then text = text .. " " .. tostring(r.Text) end
									local hit = (q == "") or text:lower():find(q, 1, true) ~= nil
									r.Visible = hit
									if hit then anyShown = true end
								end
							end
							if rows > 0 then box.Visible = anyShown or q == "" end
						end
					end
				end
			end
		end
		searchBox:GetPropertyChangedSignal("Text"):Connect(apply)
	end)

	UI.Windows[#UI.Windows + 1] = W
	return W
end

return UI
