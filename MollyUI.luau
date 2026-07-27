--!nocheck
--[[
================================================================================
  MollyUI — the MollyHub interface
================================================================================
  A drop-in replacement for the Rubis menu library: same calls (CreateWindow /
  Tab / Section / Button / Toggle / Input / Dropdown / Slider / Keybind /
  Notify), so a script written against Rubis runs here by swapping one url.

  Shape: a tall, narrow card — the shape of the screen it is used on.

  Restrained on purpose. Surfaces are one dark grey; the accent shows up about
  three times per screen — the active tab's underline, a primary action, and
  whatever is switched on — and nowhere else. An earlier version tinted every
  button by guessing from its title, which turned a page into a wall of coloured
  bars. Colour now has to be asked for: Style = "primary" or "danger".

  Choosing something opens its own panel beside the window, with its own search,
  instead of unfolding inside the page and shoving everything down.

  _G.MH_MenuScale   overall scale, also driven by the +/- in the footer
  _G.MH_OnlyTabs    set of tab titles to show; the rest are built but hidden
  _G.MH_TabMap      which tabs share a page
================================================================================
]]

local UI = {}
UI.__index = UI

local TweenService = game:GetService("TweenService")
local UserInput = game:GetService("UserInputService")
local Players = game:GetService("Players")

--==============================================================================
-- TOKENS
--==============================================================================
local C = {
	Bg      = Color3.fromRGB(11, 12, 16),   -- the card
	Surface = Color3.fromRGB(19, 21, 27),   -- rows, fields
	Raised  = Color3.fromRGB(26, 29, 37),   -- hover, tracks
	Edge    = Color3.fromRGB(33, 36, 46),   -- hairlines
	Ink     = Color3.fromRGB(240, 242, 248),
	Ink2    = Color3.fromRGB(150, 157, 175),
	Ink3    = Color3.fromRGB(96, 103, 122),
	Accent  = Color3.fromRGB(124, 106, 255),
	Danger  = Color3.fromRGB(238, 84, 96),
	On      = Color3.fromRGB(255, 255, 255),
}
local F  = Enum.Font.GothamMedium
local FB = Enum.Font.GothamBold

local R_CARD, R_ROW, R_CHIP = 18, 12, 9
local ROW_H, GAP, PAGE_PAD = 42, 5, 12

--==============================================================================
-- builders
--==============================================================================
local function new(cls, props, parent)
	local o = Instance.new(cls)
	for k, v in pairs(props or {}) do o[k] = v end
	if parent then o.Parent = parent end
	return o
end

local function round(o, r) new("UICorner", { CornerRadius = UDim.new(0, r or R_ROW) }, o) return o end

local function edge(o, colr, trans)
	return new("UIStroke", { Color = colr or C.Edge, Thickness = 1,
		Transparency = trans or 0, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o)
end

local function pad(o, t, r, b, l)
	return new("UIPadding", {
		PaddingTop = UDim.new(0, t or 0), PaddingRight = UDim.new(0, r or t or 0),
		PaddingBottom = UDim.new(0, b or t or 0), PaddingLeft = UDim.new(0, l or r or t or 0),
	}, o)
end

local function col(o, gap)
	return new("UIListLayout", { Padding = UDim.new(0, gap or GAP),
		FillDirection = Enum.FillDirection.Vertical, SortOrder = Enum.SortOrder.LayoutOrder }, o)
end

local function tw(o, t, props)
	pcall(function()
		TweenService:Create(o, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
	end)
end

local function label(parent, text, size, colr, bold)
	return new("TextLabel", {
		BackgroundTransparency = 1, Font = bold and FB or F, TextSize = size,
		TextColor3 = colr, TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd, Text = tostring(text or ""),
	}, parent)
end

local function viewport()
	local v = Vector2.new(1280, 720)
	pcall(function()
		local s = workspace.CurrentCamera.ViewportSize
		if typeof(s) == "Vector2" and s.X > 10 and s.Y > 10 then v = s end
	end)
	return v
end

local function hostGui(name)
	local gui = new("ScreenGui", { Name = name or "MollyUI", ResetOnSpawn = false,
		IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 999999 })
	local ok = pcall(function()
		if gethui then gui.Parent = gethui() else gui.Parent = game:GetService("CoreGui") end
	end)
	if not ok or not gui.Parent then
		pcall(function() gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui") end)
	end
	return gui
end

local function draggable(frame, handle)
	local dragging, from, origin
	handle.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1
			or i.UserInputType == Enum.UserInputType.Touch then
			dragging, from, origin = true, i.Position, frame.Position
			i.Changed:Connect(function()
				if i.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	UserInput.InputChanged:Connect(function(i)
		if not dragging then return end
		if i.UserInputType == Enum.UserInputType.MouseMovement
			or i.UserInputType == Enum.UserInputType.Touch then
			local d = i.Position - from
			frame.Position = UDim2.new(origin.X.Scale, origin.X.Offset + d.X,
				origin.Y.Scale, origin.Y.Offset + d.Y)
		end
	end)
end

--==============================================================================
-- TOASTS
--==============================================================================
local toasts
function UI:Notify(o)
	o = o or {}
	pcall(function()
		if not toasts or not toasts.Parent then
			local g = hostGui("MollyUI_Toasts")
			toasts = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 1),
				Position = UDim2.new(1, -16, 1, -16), Size = UDim2.fromOffset(268, 420) }, g)
			local l = col(toasts, 6)
			l.VerticalAlignment = Enum.VerticalAlignment.Bottom
			l.HorizontalAlignment = Enum.HorizontalAlignment.Right
		end
		local t = new("Frame", { BackgroundColor3 = C.Surface, Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y }, toasts)
		round(t, R_ROW); edge(t, C.Edge, 0.35)
		new("Frame", { BackgroundColor3 = C.Accent, BorderSizePixel = 0,
			Size = UDim2.fromOffset(3, 18), Position = UDim2.fromOffset(12, 13) }, t)
		local body = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(23, 0),
			Size = UDim2.new(1, -33, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, t)
		pad(body, 11, 12, 11, 10)
		col(body, 3)
		label(body, o.Title or "MollyHub", 12.5, C.Ink, true).Size = UDim2.new(1, 0, 0, 15)
		local d = label(body, o.Content or "", 11.5, C.Ink2)
		d.Size = UDim2.new(1, 0, 0, 0); d.AutomaticSize = Enum.AutomaticSize.Y; d.TextWrapped = true
		t.BackgroundTransparency = 1
		tw(t, 0.14, { BackgroundTransparency = 0 })
		task.delay(tonumber(o.Duration) or 4, function()
			tw(t, 0.18, { BackgroundTransparency = 1 })
			task.wait(0.22); pcall(function() t:Destroy() end)
		end)
	end)
end

function UI:SetTheme(t)
	if type(t) == "table" and typeof(t.Accent or t.AccentColor) == "Color3" then
		C.Accent = t.Accent or t.AccentColor
	end
end

--==============================================================================
-- PICKER — choices live beside the window, not inside the page
--==============================================================================
local openPicker
local function showPicker(win, title, values, current, onPick)
	if openPicker then pcall(function() openPicker:Destroy() end) openPicker = nil end
	local card = win._card
	local p = new("Frame", { BackgroundColor3 = C.Bg, Size = UDim2.fromOffset(228, 340),
		ZIndex = 30 }, win._gui)
	openPicker = p
	round(p, R_CARD); edge(p, C.Edge, 0.1)
	new("UIScale", { Scale = tonumber(_G.MH_MenuScale) or 1 }, p)

	local function place()
		pcall(function()
			local a, s = card.AbsolutePosition, card.AbsoluteSize
			local v = viewport()
			if a.X + s.X + 238 < v.X then p.Position = UDim2.fromOffset(a.X + s.X + 10, a.Y)
			elseif a.X - 238 > 0 then p.Position = UDim2.fromOffset(a.X - 238, a.Y)
			else p.Position = UDim2.fromOffset(a.X, a.Y + s.Y + 8) end
			p.Size = UDim2.fromOffset(228, math.max(240, math.min(s.Y, 380)))
		end)
	end
	place()
	card:GetPropertyChangedSignal("AbsolutePosition"):Connect(place)

	local head = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 44),
		ZIndex = 31 }, p)
	local ttl = label(head, title or "Choose", 13, C.Ink, true)
	ttl.Position = UDim2.fromOffset(14, 0); ttl.Size = UDim2.new(1, -50, 1, 0); ttl.ZIndex = 32
	local x = new("TextButton", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(24, 24), ZIndex = 32,
		Font = FB, TextSize = 15, TextColor3 = C.Ink3, Text = "X", AutoButtonColor = false }, head)
	x.MouseEnter:Connect(function() x.TextColor3 = C.Danger end)
	x.MouseLeave:Connect(function() x.TextColor3 = C.Ink3 end)
	draggable(p, head)

	local field = new("Frame", { BackgroundColor3 = C.Surface, ZIndex = 31,
		Position = UDim2.fromOffset(12, 42), Size = UDim2.new(1, -24, 0, 30) }, p)
	round(field, R_CHIP)
	local search = new("TextBox", { BackgroundTransparency = 1, Font = F, TextSize = 12,
		TextColor3 = C.Ink, PlaceholderText = "Search", PlaceholderColor3 = C.Ink3, Text = "",
		ClearTextOnFocus = false, ZIndex = 32, TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(11, 0), Size = UDim2.new(1, -22, 1, 0) }, field)

	local count = label(p, "", 10.5, C.Ink3)
	count.Position = UDim2.fromOffset(14, 78); count.Size = UDim2.new(1, -28, 0, 12); count.ZIndex = 31

	local sc = new("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 31,
		ClipsDescendants = true,
		Position = UDim2.fromOffset(8, 94), Size = UDim2.new(1, -16, 1, -104), CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 2,
		ScrollBarImageColor3 = C.Edge }, p)
	col(sc, 4)

	local function render(filter)
		for _, c in ipairs(sc:GetChildren()) do
			if c:IsA("GuiObject") then c:Destroy() end
		end
		filter = tostring(filter or ""):lower()
		local shown, total = 0, 0
		for _, v in ipairs(values) do
			local text = tostring(v)
			if filter == "" or text:lower():find(filter, 1, true) then
				total = total + 1
				if shown < 200 then
					shown = shown + 1
					local sel = (text == tostring(current))
					local row = new("TextButton", { BackgroundColor3 = sel and C.Raised or C.Surface,
						Size = UDim2.new(1, -4, 0, 32), Font = F, TextSize = 12, ZIndex = 32,
						TextColor3 = sel and C.Ink or C.Ink2, AutoButtonColor = false,
						TextXAlignment = Enum.TextXAlignment.Left, Text = "    " .. text,
						LayoutOrder = shown }, sc)
					round(row, R_CHIP)
					if sel then
						new("Frame", { BackgroundColor3 = C.Accent, BorderSizePixel = 0, ZIndex = 33,
							Position = UDim2.fromOffset(0, 8), Size = UDim2.fromOffset(3, 16) }, row)
					end
					row.MouseEnter:Connect(function() tw(row, 0.1, { BackgroundColor3 = C.Raised }) end)
					row.MouseLeave:Connect(function()
						tw(row, 0.1, { BackgroundColor3 = sel and C.Raised or C.Surface })
					end)
					row.MouseButton1Click:Connect(function()
						pcall(function() p:Destroy() end) openPicker = nil
						if onPick then task.spawn(function() pcall(onPick, v) end) end
					end)
				end
			end
		end
		count.Text = (total == 0) and "no matches"
			or (tostring(total) .. " item" .. (total == 1 and "" or "s")
				.. (total > shown and ("  -  showing " .. shown) or ""))
	end
	render("")
	search:GetPropertyChangedSignal("Text"):Connect(function() render(search.Text) end)
	x.MouseButton1Click:Connect(function()
		pcall(function() p:Destroy() end) openPicker = nil
	end)
	return p
end

--==============================================================================
-- WIDGETS
--==============================================================================
local Tab = {}
Tab.__index = Tab

function Tab:_order() self._n = (self._n or 0) + 1 return self._n end

local function shell(tab, h)
	local row = new("Frame", { BackgroundColor3 = C.Surface, Size = UDim2.new(1, 0, 0, h or ROW_H),
		LayoutOrder = tab:_order() }, tab._body)
	round(row, R_ROW)
	return row
end

-- title on top, quiet description under it
local function caption(row, title, desc, right)
	local box = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -(right or 28), 1, 0) }, row)
	local t = label(box, title, 12.5, C.Ink, true)
	if desc and tostring(desc) ~= "" then
		t.Position = UDim2.new(0, 0, 0, 9); t.Size = UDim2.new(1, 0, 0, 15)
		local d = label(box, desc, 11, C.Ink3)
		d.Position = UDim2.new(0, 0, 0, 25); d.Size = UDim2.new(1, 0, 0, 14)
	else
		t.Size = UDim2.fromScale(1, 1)
	end
	return box
end

function Tab:Section(o)
	o = o or {}
	local wrap = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26),
		LayoutOrder = self:_order() }, self._body)
	local l = label(wrap, string.upper(tostring(o.Title or "")), 10.5, C.Ink3, true)
	l.Position = UDim2.fromOffset(4, 8); l.Size = UDim2.new(1, -8, 0, 14)
	return { Instance = wrap, Set = function(_, v) l.Text = string.upper(tostring(v)) end }
end

function Tab:Paragraph(o)
	o = o or {}
	local row = shell(self, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	local box = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, row)
	pad(box, 12, 14, 13, 14)
	col(box, 4)
	label(box, o.Title, 12.5, C.Ink, true).Size = UDim2.new(1, 0, 0, 15)
	local d = label(box, o.Desc or o.Content, 11.5, C.Ink2)
	d.Size = UDim2.new(1, 0, 0, 0); d.AutomaticSize = Enum.AutomaticSize.Y; d.TextWrapped = true
	return { Instance = row, Set = function(_, v) d.Text = tostring(v) end }
end

-- Neutral unless asked otherwise. Style = "primary" fills with the accent,
-- "danger" reddens the label and leaves the surface alone.
function Tab:Button(o)
	o = o or {}
	local hasDesc = o.Desc and tostring(o.Desc) ~= ""
	local row = shell(self, hasDesc and 52 or 40)
	local style = tostring(o.Style or ""):lower()
	if style == "primary" then row.BackgroundColor3 = C.Accent end
	local box = caption(row, o.Title, o.Desc, 34)
	for _, c in ipairs(box:GetChildren()) do
		if c:IsA("TextLabel") then
			if style == "primary" then
				c.TextColor3 = (c.TextSize == 11) and Color3.fromRGB(220, 214, 255) or C.On
			elseif style == "danger" and c.TextSize ~= 11 then
				c.TextColor3 = C.Danger
			end
		end
	end
	local chev = label(row, ">", 13, (style == "primary") and C.On or C.Ink3, true)
	chev.AnchorPoint = Vector2.new(1, 0.5); chev.Position = UDim2.new(1, -14, 0.5, 0)
	chev.Size = UDim2.fromOffset(10, 18); chev.TextXAlignment = Enum.TextXAlignment.Right
	local base = row.BackgroundColor3
	local hit = new("TextButton", { BackgroundTransparency = 1, Text = "",
		Size = UDim2.fromScale(1, 1), AutoButtonColor = false }, row)
	hit.MouseEnter:Connect(function()
		tw(row, 0.1, { BackgroundColor3 = (style == "primary") and C.Accent or C.Raised,
			BackgroundTransparency = (style == "primary") and 0.12 or 0 })
	end)
	hit.MouseLeave:Connect(function()
		tw(row, 0.1, { BackgroundColor3 = base, BackgroundTransparency = 0 })
	end)
	hit.MouseButton1Click:Connect(function()
		tw(row, 0.06, { BackgroundTransparency = 0.35 })
		task.delay(0.08, function() tw(row, 0.12, { BackgroundTransparency = 0 }) end)
		if o.Callback then task.spawn(function() pcall(o.Callback) end) end
	end)
	return { Instance = row }
end

function Tab:Toggle(o)
	o = o or {}
	local hasDesc = o.Desc and tostring(o.Desc) ~= ""
	local row = shell(self, hasDesc and 52 or 44)
	caption(row, o.Title, o.Desc, 74)
	local on = o.Default and true or false
	local track = new("Frame", { BackgroundColor3 = on and C.Accent or C.Raised,
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(38, 22) }, row)
	round(track, 11)
	local knob = new("Frame", { BackgroundColor3 = C.On, Size = UDim2.fromOffset(16, 16),
		Position = on and UDim2.fromOffset(19, 3) or UDim2.fromOffset(3, 3) }, track)
	round(knob, 8)
	local function set(v, fire)
		on = v and true or false
		tw(track, 0.14, { BackgroundColor3 = on and C.Accent or C.Raised })
		tw(knob, 0.14, { Position = on and UDim2.fromOffset(19, 3) or UDim2.fromOffset(3, 3) })
		if fire and o.Callback then task.spawn(function() pcall(o.Callback, on) end) end
	end
	new("TextButton", { BackgroundTransparency = 1, Text = "", Size = UDim2.fromScale(1, 1),
		AutoButtonColor = false }, row).MouseButton1Click:Connect(function() set(not on, true) end)
	if on and o.Callback then task.spawn(function() pcall(o.Callback, true) end) end
	return { Instance = row, Set = function(_, v) set(v, true) end, Get = function() return on end }
end

function Tab:Input(o)
	o = o or {}
	local row = shell(self, 66)
	local l = label(row, o.Title, 11, C.Ink3, true)
	l.Position = UDim2.fromOffset(14, 10); l.Size = UDim2.new(1, -28, 0, 13)
	local field = new("Frame", { BackgroundColor3 = C.Raised, Position = UDim2.fromOffset(12, 28),
		Size = UDim2.new(1, -24, 0, 30) }, row)
	round(field, R_CHIP)
	local box = new("TextBox", { BackgroundTransparency = 1, Font = F, TextSize = 12.5,
		TextColor3 = C.Ink, PlaceholderText = tostring(o.Placeholder or ""),
		PlaceholderColor3 = C.Ink3, Text = tostring(o.Value or ""), ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(11, 0),
		Size = UDim2.new(1, -22, 1, 0) }, field)
	local ring = edge(field, C.Accent, 1)
	local function fire() if o.Callback then task.spawn(function() pcall(o.Callback, box.Text) end) end end
	box.Focused:Connect(function() tw(ring, 0.12, { Transparency = 0.35 }) end)
	box.FocusLost:Connect(function() tw(ring, 0.12, { Transparency = 1 }) fire() end)
	box:GetPropertyChangedSignal("Text"):Connect(fire)
	return { Instance = row, Set = function(_, v) box.Text = tostring(v) end,
		Get = function() return box.Text end }
end

function Tab:Slider(o)
	o = o or {}
	local lo, hi = tonumber(o.Min) or 0, tonumber(o.Max) or 100
	local val = math.clamp(tonumber(o.Default) or lo, lo, hi)
	local row = shell(self, 60)
	local l = label(row, o.Title, 11, C.Ink3, true)
	l.Position = UDim2.fromOffset(14, 10); l.Size = UDim2.new(1, -70, 0, 13)
	local read = label(row, tostring(val), 12, C.Ink, true)
	read.AnchorPoint = Vector2.new(1, 0); read.Position = UDim2.new(1, -14, 0, 9)
	read.Size = UDim2.fromOffset(50, 14); read.TextXAlignment = Enum.TextXAlignment.Right
	local bar = new("Frame", { BackgroundColor3 = C.Raised, Position = UDim2.fromOffset(14, 36),
		Size = UDim2.new(1, -28, 0, 6) }, row)
	round(bar, 3)
	local fill = new("Frame", { BackgroundColor3 = C.Accent, BorderSizePixel = 0,
		Size = UDim2.fromScale((val - lo) / math.max(1, hi - lo), 1) }, bar)
	round(fill, 3)
	local function setX(x)
		local rel = math.clamp((x - bar.AbsolutePosition.X) / math.max(1, bar.AbsoluteSize.X), 0, 1)
		val = math.floor(lo + rel * (hi - lo) + 0.5)
		fill.Size = UDim2.fromScale(rel, 1); read.Text = tostring(val)
		if o.Callback then task.spawn(function() pcall(o.Callback, val) end) end
	end
	local hit = new("TextButton", { BackgroundTransparency = 1, Text = "", AutoButtonColor = false,
		Position = UDim2.fromOffset(14, 28), Size = UDim2.new(1, -28, 0, 24) }, row)
	local held = false
	hit.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1
			or i.UserInputType == Enum.UserInputType.Touch then held = true setX(i.Position.X) end
	end)
	UserInput.InputChanged:Connect(function(i)
		if held and (i.UserInputType == Enum.UserInputType.MouseMovement
			or i.UserInputType == Enum.UserInputType.Touch) then setX(i.Position.X) end
	end)
	UserInput.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1
			or i.UserInputType == Enum.UserInputType.Touch then held = false end
	end)
	return { Instance = row, Get = function() return val end, Set = function(_, v)
		val = math.clamp(tonumber(v) or lo, lo, hi)
		fill.Size = UDim2.fromScale((val - lo) / math.max(1, hi - lo), 1)
		read.Text = tostring(val)
	end }
end

function Tab:Keybind(o)
	o = o or {}
	local row = shell(self, 44)
	caption(row, o.Title, o.Desc, 82)
	local chip = new("TextLabel", { BackgroundColor3 = C.Raised, AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0), Size = UDim2.fromOffset(58, 24), Font = FB,
		TextSize = 11.5, TextColor3 = C.Ink2, Text = tostring(o.Value or o.Default or "None") }, row)
	round(chip, 8)
	return { Instance = row, Set = function(_, v) chip.Text = tostring(v) end }
end

function Tab:Dropdown(o)
	o = o or {}
	local values, chosen = o.Values or {}, o.Value
	local row = shell(self, 66)
	local l = label(row, o.Title, 11, C.Ink3, true)
	l.Position = UDim2.fromOffset(14, 10); l.Size = UDim2.new(1, -28, 0, 13)
	local btn = new("TextButton", { BackgroundColor3 = C.Raised, Position = UDim2.fromOffset(12, 28),
		Size = UDim2.new(1, -24, 0, 30), Font = F, TextSize = 12.5, TextColor3 = C.Ink,
		TextXAlignment = Enum.TextXAlignment.Left, AutoButtonColor = false,
		Text = "   " .. tostring((chosen ~= nil and chosen ~= "") and chosen or "Choose...") }, row)
	round(btn, R_CHIP)
	local car = label(btn, ">", 12, C.Ink3, true)
	car.AnchorPoint = Vector2.new(1, 0.5); car.Position = UDim2.new(1, -11, 0.5, 0)
	car.Size = UDim2.fromOffset(10, 16); car.TextXAlignment = Enum.TextXAlignment.Right
	btn.MouseButton1Click:Connect(function()
		showPicker(self._win, o.Title, values, chosen, function(v)
			chosen = v; btn.Text = "   " .. tostring(v)
			if o.Callback then pcall(o.Callback, v) end
		end)
	end)
	return { Instance = row, Refresh = function(_, v) values = v or {} end,
		Set = function(_, v) chosen = v; btn.Text = "   " .. tostring(v) end,
		Get = function() return chosen end }
end

-- An item icon: MM2 stores these as thumbnail urls, and an ImageLabel wants an
-- asset id. Never take the first number — "...width=250...assetId=N" would give
-- the width. GLOBAL to the library so every component draws icons the same way.
local function iconOf(src)
	local t = tostring(src or "")
	if t == "" then return "" end
	local id = t:match("[Aa]sset[Ii][Dd]=(%d+)") or t:match("[?&]id=(%d+)")
		or t:match("rbxassetid://(%d+)") or t:match("rbxthumb.-id=(%d+)")
	if not id then
		local best = ""
		for run in t:gmatch("%d+") do if #run > #best then best = run end end
		id = (best ~= "") and best or nil
	end
	if not id then return "" end
	-- An MM2 item id is a MODEL, and rbxassetid:// on a model draws nothing —
	-- which is why the icons came out blank. A Thumbs url means "render this
	-- asset", and rbxthumb is how you ask the engine for that render.
	if t:find("Thumb", 1, true) or t:find("Asset.ashx", 1, true) or t == id then
		return "rbxthumb://type=Asset&id=" .. id .. "&w=150&h=150"
	end
	return "rbxassetid://" .. id
end
UI.Icon = iconOf

-- A search field with a quiet prefix, the way the reference has it.
function Tab:Search(o)
	o = o or {}
	local row = shell(self, 44)
	row.BackgroundColor3 = C.Raised
	local tag = label(row, string.upper(tostring(o.Prefix or "find")), 10, C.Ink3, true)
	tag.Position = UDim2.fromOffset(14, 0); tag.Size = UDim2.fromOffset(34, 44)
	local box = new("TextBox", { BackgroundTransparency = 1, Font = F, TextSize = 12.5,
		TextColor3 = C.Ink, PlaceholderText = tostring(o.Placeholder or "Search"),
		PlaceholderColor3 = C.Ink3, Text = "", ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(52, 0),
		Size = UDim2.new(1, -66, 1, 0) }, row)
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if o.Callback then task.spawn(function() pcall(o.Callback, box.Text) end) end
	end)
	return { Instance = row, Get = function() return box.Text end,
		Set = function(_, v) box.Text = tostring(v) end }
end

-- Filter chips. One is on at a time; the on one is the only coloured thing here.
function Tab:Chips(o)
	o = o or {}
	local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32),
		LayoutOrder = self:_order() }, self._body)
	local sc = new("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0,
		ClipsDescendants = true, Size = UDim2.fromScale(1, 1), CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X, ScrollBarThickness = 0,
		ScrollingDirection = Enum.ScrollingDirection.X }, row)
	new("UIListLayout", { Padding = UDim.new(0, 6), FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Center }, sc)
	local chips, current = {}, o.Value or (o.Values and o.Values[1])
	local function paint()
		for name, b in pairs(chips) do
			local on = (name == current)
			tw(b, 0.12, { BackgroundColor3 = on and C.Accent or C.Surface })
			b.TextColor3 = on and C.On or C.Ink2
		end
	end
	for i, name in ipairs(o.Values or {}) do
		local b = new("TextButton", { BackgroundColor3 = C.Surface, Size = UDim2.fromOffset(0, 26),
			AutomaticSize = Enum.AutomaticSize.X, Font = FB, TextSize = 11.5, TextColor3 = C.Ink2,
			Text = tostring(name), AutoButtonColor = false, LayoutOrder = i }, sc)
		pad(b, 0, 12, 0, 12)
		round(b, 8)
		chips[tostring(name)] = b
		b.MouseButton1Click:Connect(function()
			current = tostring(name); paint()
			if o.Callback then task.spawn(function() pcall(o.Callback, current) end) end
		end)
	end
	paint()
	return { Instance = row, Get = function() return current end,
		Set = function(_, v) current = tostring(v) paint() end }
end

-- The selected item, shown large: picture, a rarity chip, the name, and the
-- quiet detail line under it.
function Tab:Hero(o)
	o = o or {}
	local row = shell(self, 104)
	local pic = new("ImageLabel", { BackgroundColor3 = C.Raised, Position = UDim2.fromOffset(12, 12),
		Size = UDim2.fromOffset(80, 80), Image = "", ScaleType = Enum.ScaleType.Fit }, row)
	round(pic, R_CHIP)
	local chip = new("TextLabel", { BackgroundColor3 = C.Accent, Position = UDim2.fromOffset(104, 14),
		Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, Font = FB,
		TextSize = 10.5, TextColor3 = C.On, Text = "" }, row)
	pad(chip, 0, 10, 0, 10)
	round(chip, 7)
	local name = label(row, "", 15, C.Ink, true)
	name.Position = UDim2.fromOffset(104, 42); name.Size = UDim2.new(1, -118, 0, 20)
	local meta = label(row, "", 10.5, C.Ink3)
	meta.Position = UDim2.fromOffset(104, 66); meta.Size = UDim2.new(1, -118, 0, 14)
	local sub = label(row, "", 10.5, C.Ink3)
	sub.Position = UDim2.fromOffset(104, 80); sub.Size = UDim2.new(1, -118, 0, 14)
	return {
		Instance = row,
		Set = function(_, it)
			it = it or {}
			pic.Image = iconOf(it.image)
			chip.Text = string.upper(tostring(it.tag or ""))
			chip.Visible = (chip.Text ~= "")
			name.Text = tostring(it.name or "nothing selected")
			meta.Text = tostring(it.meta or "")
			sub.Text = tostring(it.sub or "")
		end,
	}
end

-- A scrolling list of items: icon, name, quiet subtitle, badges on the right.
function Tab:List(o)
	o = o or {}
	local row = new("Frame", { BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, tonumber(o.Height) or 210), LayoutOrder = self:_order() }, self._body)
	local head = label(row, "", 10.5, C.Ink3)
	head.Position = UDim2.fromOffset(4, 0); head.Size = UDim2.new(1, -8, 0, 14)
	local sc = new("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0,
		ClipsDescendants = true,
		Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 1, -18), CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 2,
		ScrollBarImageColor3 = C.Edge }, row)
	col(sc, 5)
	local onPick, selected
	local function draw(items, note)
		for _, c in ipairs(sc:GetChildren()) do
			if c:IsA("GuiObject") then c:Destroy() end
		end
		head.Text = tostring(note or "")
		for i, it in ipairs(items or {}) do
			local card = new("TextButton", { BackgroundColor3 = C.Surface, Text = "",
				Size = UDim2.new(1, -4, 0, 46), AutoButtonColor = false, LayoutOrder = i }, sc)
			round(card, R_ROW)
			local on = (selected ~= nil and tostring(selected) == tostring(it.key))
			new("Frame", { BackgroundColor3 = on and C.Accent or C.Edge, BorderSizePixel = 0,
				Position = UDim2.fromOffset(0, 11), Size = UDim2.fromOffset(3, 24) }, card)
			local pic = new("ImageLabel", { BackgroundColor3 = C.Raised, BackgroundTransparency = 0.4,
				Position = UDim2.fromOffset(12, 7), Size = UDim2.fromOffset(32, 32),
				Image = iconOf(it.image), ScaleType = Enum.ScaleType.Fit }, card)
			round(pic, 8)
			local badgeW = 0
			for _, b in ipairs(it.badges or {}) do
				local chip = new("TextLabel", { BackgroundColor3 = C.Raised,
					AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10 - badgeW, 0.5, 0),
					Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X, Font = FB,
					TextSize = 9.5, TextColor3 = C.Ink2, Text = string.upper(tostring(b)) }, card)
				pad(chip, 0, 8, 0, 8)
				round(chip, 6)
				badgeW = badgeW + 46
			end
			local nm = label(card, it.name, 12, C.Ink, true)
			nm.Position = UDim2.fromOffset(52, 8); nm.Size = UDim2.new(1, -62 - badgeW, 0, 15)
			local sb = label(card, it.sub, 10.5, C.Ink3)
			sb.Position = UDim2.fromOffset(52, 25); sb.Size = UDim2.new(1, -62 - badgeW, 0, 13)
			card.MouseEnter:Connect(function() tw(card, 0.1, { BackgroundColor3 = C.Raised }) end)
			card.MouseLeave:Connect(function() tw(card, 0.1, { BackgroundColor3 = C.Surface }) end)
			card.MouseButton1Click:Connect(function()
				selected = it.key
                if onPick then task.spawn(function() pcall(onPick, it) end) end
			end)
		end
	end
	return { Instance = row, Set = function(_, items, note) draw(items, note) end,
		OnPick = function(_, fn) onPick = fn end,
		Select = function(_, k) selected = k end }
end

--==============================================================================
-- WINDOW
--==============================================================================
local Window = {}
Window.__index = Window

local TAB_MAP = {
	["Trade"] = "Trade", ["2 Player"] = "Trade",
	["Spawner"] = "Spawner",
	["Settings"] = "Settings", ["Music"] = "Settings",
	["Keybinds"] = "Settings", ["Configs"] = "Settings",
}
local TAB_ORDER = { Spawner = 1, Trade = 2, Settings = 3 }

function Window:Tab(o)
	o = o or {}
	local asked = tostring(o.Title or "Tab")
	local map = (type(_G.MH_TabMap) == "table") and _G.MH_TabMap or TAB_MAP
	local title = map[asked] or asked
	local have = self._byTitle[title]
	if have then
		new("Frame", { BackgroundColor3 = C.Edge, BorderSizePixel = 0, BackgroundTransparency = 0.5,
			Size = UDim2.new(1, 0, 0, 1), LayoutOrder = have:_order() }, have._body)
		return have
	end
	local shown = true
	if type(_G.MH_OnlyTabs) == "table" and not _G.MH_OnlyTabs[title] then shown = false end

	local page = new("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0,
		Visible = false, ClipsDescendants = true, Size = UDim2.fromScale(1, 1), CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 2,
		ScrollBarImageColor3 = C.Edge, ScrollingDirection = Enum.ScrollingDirection.Y }, self._pages)
	pad(page, 2, 8, 16, 0)
	col(page, GAP)

	local btn, mark
	if shown then
		btn = new("TextButton", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 34),
			AutomaticSize = Enum.AutomaticSize.X, Font = FB, TextSize = 12.5, TextColor3 = C.Ink3,
			Text = title, AutoButtonColor = false,
			LayoutOrder = TAB_ORDER[title] or (#self._tabs + 10) }, self._tabbar)
		pad(btn, 0, 11, 0, 11)
		mark = new("Frame", { BackgroundColor3 = C.Accent, BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, 0),
			Size = UDim2.new(0, 0, 0, 2), Visible = false }, btn)
		round(mark, 1)
	end

	local tab = setmetatable({ _body = page, _btn = btn, _mark = mark, _win = self, Title = title }, Tab)
	self._tabs[#self._tabs + 1] = tab
	self._byTitle[title] = tab

	local function activate()
		for _, t in ipairs(self._tabs) do
			local on = (t == tab)
			t._body.Visible = on
			if t._btn then
				t._btn.TextColor3 = on and C.Ink or C.Ink3
				if t._mark then
					t._mark.Visible = on
					if on then
						t._mark.Size = UDim2.new(0, 0, 0, 2)
						tw(t._mark, 0.16, { Size = UDim2.new(1, -22, 0, 2) })
					end
				end
			end
		end
	end
	if btn then btn.MouseButton1Click:Connect(activate) end
	if not self._active and shown then self._active = tab activate() end
	return tab
end

function Window:Destroy() pcall(function() self._gui:Destroy() end) end
function Window:Toggle(v)
	self._card.Visible = (v == nil) and (not self._card.Visible) or (v and true or false)
end

function UI:CreateWindow(o)
	o = o or {}
	local gui = hostGui()
	local scale = tonumber(_G.MH_MenuScale) or 1

	-- tall and narrow: a launcher is short, a working menu is long
	-- A phone running Roblox is usually on its side, so sizing the height from
	-- the screen height made the card short and wide — the opposite of the ask.
	-- On a landscape screen take a slice of the width and nearly all the height.
	local wantW = o.Compact and 300 or 336
	local wantH = o.Compact and 230 or 820

	local card = new("Frame", { BackgroundColor3 = C.Bg, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(wantW, wantH),
		ClipsDescendants = true,
		-- headless: build everything, show nothing. Lets a front-end drive the
		-- engine's menu without a second window sitting on screen.
		Visible = not (_G.MH_Headless and not o.Front) }, gui)
	round(card, R_CARD); edge(card, C.Edge, 0.1)
	local uiscale = new("UIScale", { Scale = scale }, card)

	local readout
	local function fit()
		pcall(function()
			local v = viewport()
			local wide = v.X > v.Y
			card.Size = UDim2.fromOffset(
				math.min(wantW, math.floor(v.X * (wide and 0.42 or 0.94))),
				math.min(wantH, math.floor(v.Y * (wide and 0.94 or 0.86))))
			uiscale.Scale = scale * ((v.X < 480) and 0.92 or 1)
			if readout then readout.Text = tostring(math.floor(scale * 100 + 0.5)) .. "%" end
		end)
	end

	-- header
	local head = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 54) }, card)
	local badge = new("Frame", { BackgroundColor3 = C.Accent, Position = UDim2.fromOffset(14, 11),
		Size = UDim2.fromOffset(32, 32) }, head)
	round(badge, 10)
	local bl = label(badge, o.Badge or "MH", 11.5, C.On, true)
	bl.Size = UDim2.fromScale(1, 1); bl.TextXAlignment = Enum.TextXAlignment.Center
	local ttl = label(head, string.upper(tostring(o.Title or "MollyHub")), 14.5, C.Ink, true)
	ttl.Position = UDim2.fromOffset(56, 11); ttl.Size = UDim2.new(1, -100, 0, 17)
	local sub = label(head, o.SubTitle or o.Author or "", 10.5, C.Ink3)
	sub.Position = UDim2.fromOffset(56, 29); sub.Size = UDim2.new(1, -100, 0, 13)
	local close = new("TextButton", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0, 27), Size = UDim2.fromOffset(26, 26), Font = FB,
		TextSize = 16, TextColor3 = C.Ink3, Text = "X", AutoButtonColor = false }, head)
	close.MouseEnter:Connect(function() close.TextColor3 = C.Danger end)
	close.MouseLeave:Connect(function() close.TextColor3 = C.Ink3 end)

	-- tabs: text with an underline, not filled pills — legible in a narrow card
	local tabbar = new("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0,
		ClipsDescendants = true,
		Position = UDim2.fromOffset(10, 54), Size = UDim2.new(1, -20, 0, 32), CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X, ScrollBarThickness = 0,
		ScrollingDirection = Enum.ScrollingDirection.X }, card)
	new("UIListLayout", { Padding = UDim.new(0, 2), FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Center }, tabbar)
	new("Frame", { BackgroundColor3 = C.Edge, BorderSizePixel = 0, BackgroundTransparency = 0.4,
		Position = UDim2.fromOffset(10, 86), Size = UDim2.new(1, -20, 0, 1) }, card)

	-- Clip, or scrolled rows draw straight over the header, the tabs and the
	-- footer — which reads as the rest of the interface vanishing.
	local pages = new("Frame", { BackgroundTransparency = 1, ClipsDescendants = true,
		Position = UDim2.fromOffset(PAGE_PAD, 94),
		Size = UDim2.new(1, -PAGE_PAD * 2, 1, -122) }, card)

	-- footer: the scale control, kept out of the header's way
	local foot = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 28) }, card)
	local brand = label(foot, "MollyHub", 10.5, C.Ink3)
	brand.Position = UDim2.fromOffset(16, 0); brand.Size = UDim2.new(0, 120, 1, 0)
	readout = label(foot, "100%", 10.5, C.Ink2, true)
	readout.AnchorPoint = Vector2.new(1, 0.5); readout.Position = UDim2.new(1, -46, 0.5, 0)
	readout.Size = UDim2.fromOffset(38, 14); readout.TextXAlignment = Enum.TextXAlignment.Center
	local function stepper(x, glyph, delta)
		local b = new("TextButton", { BackgroundColor3 = C.Surface, AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, x, 0.5, 0), Size = UDim2.fromOffset(22, 22), Font = FB,
			TextSize = 13, TextColor3 = C.Ink2, Text = glyph, AutoButtonColor = false }, foot)
		round(b, 7)
		b.MouseButton1Click:Connect(function()
			scale = math.clamp(scale + delta, 0.6, 1.5)
			_G.MH_MenuScale = scale
			fit()
		end)
	end
	stepper(-84, "-", -0.05)
	stepper(-14, "+", 0.05)

	fit()
	pcall(function()
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	end)
	draggable(card, head)

	local win = setmetatable({ _gui = gui, _card = card, _tabbar = tabbar, _pages = pages,
		_tabs = {}, _byTitle = {} }, Window)

	local pill = new("TextButton", { BackgroundColor3 = C.Accent, Position = UDim2.fromOffset(18, 18),
		Size = UDim2.fromOffset(96, 30), Font = FB, TextSize = 12, TextColor3 = C.On,
		Visible = false, Text = tostring(o.Title or "MollyHub"), AutoButtonColor = false }, gui)
	round(pill, 10)
	draggable(pill, pill)
	close.MouseButton1Click:Connect(function()
		card.Visible = false pill.Visible = true
		if openPicker then pcall(function() openPicker:Destroy() end) openPicker = nil end
	end)
	pill.MouseButton1Click:Connect(function() card.Visible = true pill.Visible = false end)

	return win
end

UI.Window = UI.CreateWindow
UI.Notification = UI.Notify

return UI
