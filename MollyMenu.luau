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

  Nothing here is fetched from anywhere. Icons are glyphs, the shadow is drawn
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
	Bg      = Color3.fromRGB(9, 10, 14),
	Panel   = Color3.fromRGB(15, 17, 23),
	Panel2  = Color3.fromRGB(20, 22, 30),
	Hover   = Color3.fromRGB(27, 30, 40),
	Edge    = Color3.fromRGB(42, 45, 58),
	Text    = Color3.fromRGB(241, 242, 247),
	Muted   = Color3.fromRGB(147, 151, 166),
	Accent  = Color3.fromRGB(99, 121, 255),
	Accent2 = Color3.fromRGB(149, 96, 255),
	Good    = Color3.fromRGB(79, 211, 132),
	Bad     = Color3.fromRGB(255, 90, 112),
	Off     = Color3.fromRGB(50, 53, 65),
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

-- A name for an icon, drawn as a glyph. The hub asks for these by the names the
-- old library used, so the same call keeps working.
local GLYPH = {
	crown = "\u{2654}", house = "\u{2302}", box = "\u{25A3}", eye = "\u{25C9}",
	target = "\u{2316}", ["crosshair"] = "\u{2316}", user = "\u{263A}",
	users = "\u{263A}", star = "\u{2605}", zap = "\u{26A1}", flame = "\u{2668}",
	map = "\u{25A6}", ghost = "\u{25CC}", gear = "\u{2699}", settings = "\u{2699}",
	wrench = "\u{2692}", hand = "\u{270B}", info = "\u{24D8}", x = "\u{00D7}",
	component = "\u{25C8}", sparkles = "\u{2727}", swords = "\u{2694}",
	knife = "\u{2694}", gun = "\u{2316}", coins = "\u{25CE}", palette = "\u{25D0}",
	key = "\u{26B7}", save = "\u{25A4}", trash = "\u{2612}", bell = "\u{1F514}",
}
local function glyph(name)
	if type(name) ~= "string" or name == "" then return "\u{2022}" end
	if #name <= 2 then return name end          -- already a glyph
	return GLYPH[name:lower()] or "\u{2022}"
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
		local k = math.min(vw / (cw + 90), vh / (ch + 90), 1)
		scale.Scale = math.clamp(k, 0.55, 1)
		shade.Size = UDim2.fromOffset(cw + 26, ch + 26)
		-- a narrow screen gets the icon rail instead of the full sidebar
		W._narrow = (vw * (1 / math.max(scale.Scale, 0.01))) < (cw + 240)
		if W._applyRail then W._applyRail() end
	end

	--== top bar ================================================================
	local barH = 58
	local top = make("Frame", {
		Name = "TopBar",
		Size = UDim2.new(1, 0, 0, barH),
		BackgroundColor3 = T.Panel,
		BorderSizePixel = 0,
		Parent = card,
	})
	make("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = T.Edge,
		BorderSizePixel = 0,
		Parent = top,
	})
	local logo = make("TextLabel", {
		Name = "Logo",
		Position = UDim2.fromOffset(20, 0),
		Size = UDim2.fromOffset(230, barH),
		BackgroundTransparency = 1,
		Text = tostring(o.Title or "Molly Hub"),
		TextColor3 = T.Text,
		TextSize = 23,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = top,
	})
	pcall(function()
		make("UIGradient", {
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
				ColorSequenceKeypoint.new(0.5, Color3.fromRGB(207, 211, 255)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(180, 129, 255)),
			}),
			Parent = logo,
		})
	end)
	W._logo = logo

	local pill = make("Frame", {
		Name = "Status",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -66, 0.5, 0),
		Size = UDim2.fromOffset(150, 30),
		BackgroundColor3 = T.Panel2,
		BorderSizePixel = 0,
		Parent = top,
	}, { corner(8), stroke(T.Edge, 0.3) })
	make("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 11, 0.5, 0),
		Size = UDim2.fromOffset(7, 7),
		BackgroundColor3 = T.Good,
		BorderSizePixel = 0,
		Parent = pill,
	}, { corner(99) })
	local pillText = make("TextLabel", {
		Position = UDim2.fromOffset(26, 0),
		Size = UDim2.new(1, -32, 1, 0),
		BackgroundTransparency = 1,
		Text = tostring(o.SubTitle or o.Author or "Murder Mystery 2"),
		TextColor3 = T.Muted,
		TextSize = 11,
		Font = Enum.Font.GothamMedium,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = pill,
	})
	W._hint = pillText

	local closeBtn = make("TextButton", {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -16, 0.5, 0),
		Size = UDim2.fromOffset(34, 34),
		BackgroundColor3 = T.Panel2,
		BorderSizePixel = 0,
		Text = "\u{00D7}",
		TextColor3 = T.Muted,
		TextSize = 22,
		Font = Enum.Font.GothamMedium,
		AutoButtonColor = false,
		Parent = top,
	}, { corner(9), stroke(T.Edge, 0.3) })

	--== sidebar ================================================================
	local side = make("Frame", {
		Name = "Sidebar",
		Position = UDim2.fromOffset(0, barH),
		Size = UDim2.new(0, wide, 1, -barH),
		BackgroundColor3 = T.Panel,
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
	local tabbar = make("ScrollingFrame", {
		Name = "Tabs",
		Position = UDim2.fromOffset(10, 14),
		Size = UDim2.new(1, -20, 1, -70),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 2,
		ScrollBarImageColor3 = T.Accent,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = side,
	}, { list(6) })
	W._tabbar = tabbar
	W._sidebar = true
	W._menuBtn = nil

	local keyHint = make("TextLabel", {
		Name = "KeyHint",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -12),
		Size = UDim2.new(1, -20, 0, 38),
		BackgroundColor3 = T.Panel2,
		BorderSizePixel = 0,
		Text = "RightShift  \u{2022}  hide",
		TextColor3 = T.Muted,
		TextSize = 11,
		Font = Enum.Font.GothamMedium,
		Parent = side,
	}, { corner(9), stroke(T.Edge, 0.35) })

	--== content ================================================================
	local content = make("Frame", {
		Name = "Content",
		Position = UDim2.fromOffset(wide, barH),
		Size = UDim2.new(1, -wide, 1, -barH),
		BackgroundTransparency = 1,
		Parent = card,
	})
	local title = make("TextLabel", {
		Name = "PageTitle",
		Position = UDim2.fromOffset(22, 14),
		Size = UDim2.new(1, -44, 0, 30),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = T.Text,
		TextSize = 21,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = content,
	})
	W._pageTitle = title
	local sub = make("TextLabel", {
		Name = "PageSub",
		Position = UDim2.fromOffset(22, 42),
		Size = UDim2.new(1, -44, 0, 18),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = T.Muted,
		TextSize = 11,
		Font = Enum.Font.Gotham,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = content,
	})
	local pages = make("Frame", {
		Name = "Pages",
		Position = UDim2.fromOffset(18, 66),
		Size = UDim2.new(1, -36, 1, -80),
		BackgroundTransparency = 1,
		Parent = content,
	})

	-- the icon rail: on a narrow screen the sidebar keeps the icons and drops
	-- the words, and the page takes the room back
	function W._applyRail()
		local w = W._narrow and 52 or wide
		side.Size = UDim2.new(0, w, 1, -barH)
		content.Position = UDim2.fromOffset(w, barH)
		content.Size = UDim2.new(1, -w, 1, -barH)
		keyHint.Visible = not W._narrow
		tabbar.Size = UDim2.new(1, -20, 1, W._narrow and -20 or -70)
		for _, t in ipairs(W._tabs) do
			if t._label then t._label.Visible = not W._narrow end
			if t._btn then
				t._btn.Size = UDim2.new(1, 0, 0, W._narrow and 40 or 42)
			end
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
		}, { corner(11), stroke(T.Edge, 0.2), pad(10, 10, 10, 12), list(7) })
	end

	local function row(parent, h)
		return make("Frame", {
			Size = UDim2.new(1, 0, 0, h or 46),
			BackgroundColor3 = T.Panel2,
			BorderSizePixel = 0,
			Parent = parent,
		}, { corner(9), stroke(T.Edge, 0.4) })
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
	local function mkTab(name, icon, subtitle)
		local P = newPage(name, subtitle)
		local Tab = { Instance = P.page, _body = P.page, _cols = P.cols, _page = P }

		-- Anything with a value says so, and a config is then just the list of
		-- those values. The key is the page and the title, which is stable across
		-- runs as long as the menu keeps its wording.
		local function reg(title, get, set)
			if title == nil or tostring(title) == "" then return end
			W._reg[#W._reg + 1] = { key = name .. "/" .. tostring(title), get = get, set = set }
		end

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
		local function host(h)
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
			Tab._colIdx = shortest()
			Tab._order = (Tab._order or 0) + 1
			local box = cardBox(P.cols[Tab._colIdx], Tab._order)
			Tab._card = box
			P.heights[Tab._colIdx] = (P.heights[Tab._colIdx] or 0) + 40
			make("TextLabel", {
				Size = UDim2.new(1, 0, 0, 20),
				BackgroundTransparency = 1,
				Text = tostring(so.Title or ""):upper(),
				TextColor3 = T.Muted,
				TextSize = 11,
				Font = Enum.Font.GothamBold,
				TextXAlignment = Enum.TextXAlignment.Left,
				LayoutOrder = 0,
				Parent = box,
			})
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
			local h = hasDesc and 50 or 42
			local btn = make("TextButton", {
				Size = UDim2.new(1, 0, 0, h),
				BackgroundColor3 = (bo.Style == "primary") and T.Accent or T.Panel2,
				BorderSizePixel = 0,
				Text = "",
				AutoButtonColor = false,
				Parent = host(h + 7),
			}, { corner(9), stroke(T.Edge, 0.4) })
			local isPrimary = bo.Style == "primary"
			make("TextLabel", {
				Position = UDim2.fromOffset(12, hasDesc and 8 or 0),
				Size = hasDesc and UDim2.new(1, -46, 0, 17) or UDim2.new(1, -46, 1, 0),
				BackgroundTransparency = 1,
				Text = (bo.Icon and (glyph(bo.Icon) .. "  ") or "") .. tostring(bo.Title or ""),
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
			make("TextLabel", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -14, 0.5, 0),
				Size = UDim2.fromOffset(16, 16),
				BackgroundTransparency = 1,
				Text = "\u{203A}",
				TextColor3 = isPrimary and Color3.fromRGB(255, 255, 255) or T.Muted,
				TextSize = 16,
				Font = Enum.Font.GothamBold,
				Parent = btn,
			})
			if not isPrimary then hover(btn, T.Panel2, T.Hover) end
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
			local h = hasDesc and 50 or 44
			local r = row(host(h + 7), h)
			rowTitle(r, to.Title, hasDesc and desc or nil, 76)
			local sw = make("TextButton", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -12, 0.5, 0),
				Size = UDim2.fromOffset(44, 24),
				BackgroundColor3 = state and T.Accent or T.Off,
				BorderSizePixel = 0,
				Text = "",
				AutoButtonColor = false,
				Parent = r,
			}, { corner(99) })
			local knob = make("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = state and UDim2.new(1, -12, 0.5, 0) or UDim2.new(0, 12, 0.5, 0),
				Size = UDim2.fromOffset(18, 18),
				BackgroundColor3 = Color3.fromRGB(255, 255, 255),
				BorderSizePixel = 0,
				Parent = sw,
			}, { corner(99) })
			local api = { Instance = r }
			local function paint()
				tween(sw, 0.15, { BackgroundColor3 = state and T.Accent or T.Off })
				tween(knob, 0.15, {
					Position = state and UDim2.new(1, -12, 0.5, 0) or UDim2.new(0, 12, 0.5, 0),
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
			hover(r, T.Panel2, T.Hover)
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
			local h = hasDesc and 74 or 60
			local r = row(host(h + 7), h)
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
			local r = row(host(51), 44)
			rowTitle(r, io.Title, nil, 160)
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
			local h = hasDesc and 50 or 44
			local r = row(host(h + 7), h)
			rowTitle(r, ko.Title, hasDesc and desc or nil, 110)
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
				chip.Text = listening and "press a key\u{2026}" or (key ~= "" and key or "none")
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
			local r = row(host(51), 44)
			rowTitle(r, co.Title, nil, 130)
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
			local h = hasDesc and 50 or 44
			local r = row(host(h + 7), h)
			rowTitle(r, dobj.Title, hasDesc and desc or nil, 150)
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
				Text = label() .. "   \u{25BE}",
				TextColor3 = T.Text,
				TextSize = 12,
				Font = Enum.Font.GothamMedium,
				TextTruncate = Enum.TextTruncate.AtEnd,
				AutoButtonColor = false,
				Parent = r,
			}, { corner(7), stroke(T.Edge, 0.3) })
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
							shown.Text = label() .. "   \u{25BE}"
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
				shown.Text = label() .. "   \u{25BE}"
				build()
			end
			function api:Select(vals)
				chosen = {}
				if type(vals) == "table" then
					for _, v in ipairs(vals) do chosen[tostring(v)] = true end
				elseif vals ~= nil then
					chosen[tostring(vals)] = true
				end
				shown.Text = label() .. "   \u{25BE}"
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
			Size = UDim2.new(1, 0, 0, 42),
			BackgroundColor3 = T.Panel,
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = false,
			Parent = tabbar,
		}, { corner(9) })
		local mark = make("Frame", {
			Name = "Mark",
			Position = UDim2.fromOffset(0, 9),
			Size = UDim2.fromOffset(3, 24),
			BackgroundColor3 = T.Accent,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = btn,
		}, { corner(99) })
		local ico = make("TextLabel", {
			Name = "Icon",
			Position = UDim2.fromOffset(11, 0),
			Size = UDim2.fromOffset(24, 42),
			BackgroundTransparency = 1,
			Text = glyph(to.Icon),
			TextColor3 = T.Muted,
			TextSize = 15,
			Font = Enum.Font.GothamBold,
			Parent = btn,
		})
		local lab = make("TextLabel", {
			Name = "Label",
			Position = UDim2.fromOffset(41, 0),
			Size = UDim2.new(1, -50, 1, 0),
			BackgroundTransparency = 1,
			Text = name:upper(),
			TextColor3 = T.Muted,
			TextSize = 12,
			Font = Enum.Font.GothamBold,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = btn,
		})
		Tab._btn, Tab._label, Tab._icon, Tab._mark = btn, lab, ico, mark
		Tab.Name = name
		W._tabs[#W._tabs + 1] = Tab
		W._pages[name] = P

		local function select()
			if W._cur == name then return end
			W._cur = name
			title.Text = name
			sub.Text = subtitle
			for _, t in ipairs(W._tabs) do
				local on = t.Name == name
				tween(t._btn, 0.15, { BackgroundColor3 = on and T.Hover or T.Panel })
				tween(t._icon, 0.15, { TextColor3 = on and T.Text or T.Muted })
				tween(t._label, 0.15, { TextColor3 = on and T.Text or T.Muted })
				tween(t._mark, 0.15, { BackgroundTransparency = on and 0 or 1 })
				t._page.page.Visible = on
			end
		end
		Tab.Select = select
		pcall(function()
			btn.MouseButton1Click:Connect(select)
			btn.MouseEnter:Connect(function()
				if W._cur ~= name then tween(btn, 0.12, { BackgroundColor3 = T.Panel2 }) end
			end)
			btn.MouseLeave:Connect(function()
				if W._cur ~= name then tween(btn, 0.12, { BackgroundColor3 = T.Panel }) end
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
			keyHint.Text = tostring(toggleKey):gsub("^Enum%.KeyCode%.", "") .. "  \u{2022}  hide"
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
		top.InputBegan:Connect(function(input)
			local t = input.UserInputType
			if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
				dragging = true
				from = input.Position
				at0 = card.Position
			end
		end)
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
	function W:Tag(text) pcall(function() pillText.Text = tostring(text or "") end) return self end
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

	UI.Windows[#UI.Windows + 1] = W
	return W
end

return UI
