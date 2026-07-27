--!nocheck
--[[
================================================================================
  MollyUI — the MollyHub interface
================================================================================
  A drop-in replacement for the Rubis menu library. It answers the same calls
  (CreateWindow / Tab / Section / Button / Toggle / Input / Dropdown / Slider /
  Keybind / Notify), so a script written against Rubis runs on this one by
  swapping the library URL and nothing else.

  Design: one dark card. A header with a square badge, the title, a subtitle and
  a red close button; a row of pill tabs under it; content as rounded panels with
  small-caps labels. Actions are coloured by what they do rather than all being
  grey — blue starts something, green confirms, red destroys.

    local UI  = loadstring(game:HttpGet(".../MollyUI.luau"))()
    local Win = UI:CreateWindow({ Title = "MollyHub", SubTitle = "Murder Mystery 2" })
    local Tab = Win:Tab({ Title = "Spawner" })
    Tab:Section({ Title = "Spawn" })
    Tab:Button({ Title = "Spawn item", Callback = function() end })

  _G.MH_MenuScale scales the whole window. _G.MH_OnlyTabs, if set, is a set of
  tab titles to SHOW — the rest are still built, so the script behind them keeps
  working, they are just not on screen.
================================================================================
]]

local UI = {}
UI.__index = UI

local TweenService = game:GetService("TweenService")
local UserInput = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

--==============================================================================
-- THEME
--==============================================================================
local T = {
	Card      = Color3.fromRGB(14, 16, 22),
	Panel     = Color3.fromRGB(21, 25, 34),
	PanelSoft = Color3.fromRGB(28, 33, 44),
	Line      = Color3.fromRGB(38, 44, 58),
	Text      = Color3.fromRGB(236, 240, 248),
	Dim       = Color3.fromRGB(138, 148, 168),
	Faint     = Color3.fromRGB(96, 104, 122),
	Accent    = Color3.fromRGB(94, 126, 240),
	Good      = Color3.fromRGB(64, 190, 118),
	Bad       = Color3.fromRGB(232, 78, 84),
	Warm      = Color3.fromRGB(240, 168, 74),
	OnAccent  = Color3.fromRGB(255, 255, 255),
}
local FONT      = Enum.Font.GothamMedium
local FONT_BOLD = Enum.Font.GothamBold

--==============================================================================
-- little builders
--==============================================================================
local function new(cls, props, parent)
	local o = Instance.new(cls)
	for k, v in pairs(props or {}) do o[k] = v end
	if parent then o.Parent = parent end
	return o
end

local function round(inst, r)
	new("UICorner", { CornerRadius = UDim.new(0, r or 10) }, inst)
	return inst
end

local function stroke(inst, col, thick, trans)
	return new("UIStroke", {
		Color = col or T.Line, Thickness = thick or 1,
		Transparency = trans or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, inst)
end

local function pad(inst, all, l, r, t, b)
	return new("UIPadding", {
		PaddingLeft = UDim.new(0, l or all or 0), PaddingRight = UDim.new(0, r or all or 0),
		PaddingTop = UDim.new(0, t or all or 0), PaddingBottom = UDim.new(0, b or all or 0),
	}, inst)
end

local function list(inst, gap, dir)
	return new("UIListLayout", {
		Padding = UDim.new(0, gap or 8),
		FillDirection = dir or Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, inst)
end

local function tween(o, t, props)
	pcall(function()
		TweenService:Create(o, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
	end)
end

-- Buttons say what they do. Rubis has no variant field, so the title decides:
-- a destructive word turns it red, a committing one blue, an approving one
-- green. Everything else stays quiet grey.
local function toneFor(title)
	local s = tostring(title or ""):lower()
	if s:find("remove") or s:find("forget") or s:find("delete") or s:find("clear")
		or s:find("terminate") or s:find("cancel") or s:find("block") or s:find("decline")
		or s:find("stop") or s:find("reset") or s:find("unequip") then
		return T.Bad, T.OnAccent
	end
	if s:find("accept") or s:find("confirm") or s:find("apply") or s:find("save") then
		return T.Good, T.OnAccent
	end
	if s:find("spawn") or s:find("equip") or s:find("start") or s:find("request")
		or s:find("launch") or s:find("run") or s:find("learn") or s:find("load") then
		return T.Accent, T.OnAccent
	end
	return T.PanelSoft, T.Text
end

local function hostGui()
	local gui = new("ScreenGui", {
		Name = "MollyUI", ResetOnSpawn = false, IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999999,
	})
	local ok = pcall(function()
		if gethui then gui.Parent = gethui() else gui.Parent = game:GetService("CoreGui") end
	end)
	if not ok or not gui.Parent then
		pcall(function() gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui") end)
	end
	return gui
end

local function draggable(frame, handle)
	local dragging, startPos, startInput
	handle.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1
			or i.UserInputType == Enum.UserInputType.Touch then
			dragging, startInput, startPos = true, i.Position, frame.Position
			i.Changed:Connect(function()
				if i.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	UserInput.InputChanged:Connect(function(i)
		if not dragging then return end
		if i.UserInputType == Enum.UserInputType.MouseMovement
			or i.UserInputType == Enum.UserInputType.Touch then
			local d = i.Position - startInput
			frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
				startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
end

--==============================================================================
-- NOTIFY
--==============================================================================
local toastHolder
function UI:Notify(o)
	o = o or {}
	pcall(function()
		if not toastHolder or not toastHolder.Parent then
			local g = hostGui()
			g.Name = "MollyUI_Toasts"
			toastHolder = new("Frame", {
				BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 1),
				Position = UDim2.new(1, -18, 1, -18), Size = UDim2.fromOffset(300, 400),
			}, g)
			local l = list(toastHolder, 8)
			l.VerticalAlignment = Enum.VerticalAlignment.Bottom
			l.HorizontalAlignment = Enum.HorizontalAlignment.Right
		end
		local card = new("Frame", {
			BackgroundColor3 = T.Panel, Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 0.02,
		}, toastHolder)
		round(card, 12); stroke(card, T.Line, 1, 0.3)
		new("Frame", {
			BackgroundColor3 = T.Accent, BorderSizePixel = 0,
			Size = UDim2.new(0, 3, 1, -16), Position = UDim2.fromOffset(10, 8),
		}, round(card, 12) and card)
		local body = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -34, 0, 0),
			Position = UDim2.fromOffset(24, 0), AutomaticSize = Enum.AutomaticSize.Y }, card)
		pad(body, 10, 10, 10, 10, 10)
		list(body, 2)
		new("TextLabel", {
			BackgroundTransparency = 1, Font = FONT_BOLD, TextSize = 13, TextColor3 = T.Text,
			TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 16),
			Text = tostring(o.Title or "MollyHub"),
		}, body)
		new("TextLabel", {
			BackgroundTransparency = 1, Font = FONT, TextSize = 12, TextColor3 = T.Dim,
			TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true,
			Text = tostring(o.Content or ""),
		}, body)
		card.BackgroundTransparency = 1
		tween(card, 0.15, { BackgroundTransparency = 0.02 })
		task.delay(tonumber(o.Duration) or 4, function()
			tween(card, 0.2, { BackgroundTransparency = 1 })
			task.wait(0.25)
			pcall(function() card:Destroy() end)
		end)
	end)
end

function UI:SetTheme(t)
	if type(t) ~= "table" then return end
	if typeof(t.Accent) == "Color3" then T.Accent = t.Accent end
	if typeof(t.AccentColor) == "Color3" then T.Accent = t.AccentColor end
end

--==============================================================================
-- WIDGETS  (every one returns a handle with :Set / :Refresh where it makes sense)
--==============================================================================
local Tab = {}
Tab.__index = Tab

local function rowShell(tab, h)
	local row = new("Frame", {
		BackgroundColor3 = T.Panel, Size = UDim2.new(1, 0, 0, h or 44),
		LayoutOrder = tab:_order(),
	}, tab._body)
	round(row, 10)
	stroke(row, T.Line, 1, 0.45)
	return row
end

local function titleAndDesc(row, title, desc, rightPad)
	local holder = new("Frame", { BackgroundTransparency = 1,
		Size = UDim2.new(1, -(rightPad or 24), 1, 0), Position = UDim2.fromOffset(12, 0) }, row)
	local t = new("TextLabel", {
		BackgroundTransparency = 1, Font = FONT_BOLD, TextSize = 13, TextColor3 = T.Text,
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
		Text = tostring(title or ""),
	}, holder)
	if desc and tostring(desc) ~= "" then
		t.Position = UDim2.new(0, 0, 0, 7); t.Size = UDim2.new(1, 0, 0, 15)
		new("TextLabel", {
			BackgroundTransparency = 1, Font = FONT, TextSize = 11, TextColor3 = T.Faint,
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.new(0, 0, 0, 23), Size = UDim2.new(1, 0, 0, 14),
			Text = tostring(desc),
		}, holder)
	else
		t.Position = UDim2.new(0, 0, 0, 0); t.Size = UDim2.new(1, 0, 1, 0)
	end
	return holder
end

function Tab:_order()
	self._n = (self._n or 0) + 1
	return self._n
end

function Tab:Section(o)
	o = o or {}
	local lab = new("TextLabel", {
		BackgroundTransparency = 1, Font = FONT_BOLD, TextSize = 11,
		TextColor3 = T.Faint, TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 22), LayoutOrder = self:_order(),
		Text = string.upper(tostring(o.Title or "")),
	}, self._body)
	return { Instance = lab, Set = function(_, v) lab.Text = string.upper(tostring(v)) end }
end

function Tab:Paragraph(o)
	o = o or {}
	local row = rowShell(self, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	local box = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -24, 0, 0),
		Position = UDim2.fromOffset(12, 0), AutomaticSize = Enum.AutomaticSize.Y }, row)
	pad(box, 10)
	list(box, 3)
	new("TextLabel", { BackgroundTransparency = 1, Font = FONT_BOLD, TextSize = 13,
		TextColor3 = T.Text, TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 16), Text = tostring(o.Title or "") }, box)
	local body = new("TextLabel", { BackgroundTransparency = 1, Font = FONT, TextSize = 12,
		TextColor3 = T.Dim, TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true,
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		Text = tostring(o.Desc or o.Content or "") }, box)
	return { Instance = row, Set = function(_, v) body.Text = tostring(v) end }
end

function Tab:Button(o)
	o = o or {}
	local row = rowShell(self, (o.Desc and o.Desc ~= "") and 46 or 38)
	local fill, fg = toneFor(o.Title)
	row.BackgroundColor3 = fill
	if fill == T.PanelSoft then stroke(row, T.Line, 1, 0.2) end
	local holder = titleAndDesc(row, o.Title, o.Desc, 24)
	for _, c in ipairs(holder:GetChildren()) do
		if c:IsA("TextLabel") then
			c.TextColor3 = (c.TextSize == 11) and (fill == T.PanelSoft and T.Faint
				or Color3.fromRGB(240, 240, 250)) or fg
		end
	end
	local hit = new("TextButton", { BackgroundTransparency = 1, Text = "",
		Size = UDim2.fromScale(1, 1), AutoButtonColor = false }, row)
	hit.MouseEnter:Connect(function() tween(row, 0.12, { BackgroundTransparency = 0.15 }) end)
	hit.MouseLeave:Connect(function() tween(row, 0.12, { BackgroundTransparency = 0 }) end)
	hit.MouseButton1Click:Connect(function()
		tween(row, 0.08, { BackgroundTransparency = 0.3 })
		task.delay(0.09, function() tween(row, 0.12, { BackgroundTransparency = 0 }) end)
		if o.Callback then task.spawn(function() pcall(o.Callback) end) end
	end)
	return { Instance = row }
end

function Tab:Toggle(o)
	o = o or {}
	local row = rowShell(self, (o.Desc and o.Desc ~= "") and 48 or 40)
	titleAndDesc(row, o.Title, o.Desc, 68)
	local state = o.Default and true or false
	local track = new("Frame", {
		BackgroundColor3 = state and T.Accent or T.PanelSoft, AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(40, 22),
	}, row)
	round(track, 11)
	local knob = new("Frame", {
		BackgroundColor3 = T.OnAccent, Size = UDim2.fromOffset(16, 16),
		Position = state and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3),
	}, track)
	round(knob, 8)
	local function set(v, fire)
		state = v and true or false
		tween(track, 0.15, { BackgroundColor3 = state and T.Accent or T.PanelSoft })
		tween(knob, 0.15, { Position = state and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3) })
		if fire and o.Callback then task.spawn(function() pcall(o.Callback, state) end) end
	end
	local hit = new("TextButton", { BackgroundTransparency = 1, Text = "",
		Size = UDim2.fromScale(1, 1), AutoButtonColor = false }, row)
	hit.MouseButton1Click:Connect(function() set(not state, true) end)
	if state and o.Callback then task.spawn(function() pcall(o.Callback, true) end) end
	return { Instance = row, Set = function(_, v) set(v, true) end, Get = function() return state end }
end

function Tab:Input(o)
	o = o or {}
	local row = rowShell(self, 62)
	new("TextLabel", { BackgroundTransparency = 1, Font = FONT_BOLD, TextSize = 12,
		TextColor3 = T.Dim, TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(12, 8), Size = UDim2.new(1, -24, 0, 14),
		Text = tostring(o.Title or "") }, row)
	local field = new("Frame", { BackgroundColor3 = T.PanelSoft,
		Position = UDim2.fromOffset(10, 26), Size = UDim2.new(1, -20, 0, 28) }, row)
	round(field, 8)
	local box = new("TextBox", {
		BackgroundTransparency = 1, Font = FONT, TextSize = 13, TextColor3 = T.Text,
		PlaceholderText = tostring(o.Placeholder or ""), PlaceholderColor3 = T.Faint,
		Text = tostring(o.Value or ""), ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -20, 1, 0),
		Position = UDim2.fromOffset(10, 0),
	}, field)
	local function fire() if o.Callback then task.spawn(function() pcall(o.Callback, box.Text) end) end end
	box.FocusLost:Connect(fire)
	box:GetPropertyChangedSignal("Text"):Connect(fire)
	box.Focused:Connect(function() tween(field, 0.12, { BackgroundColor3 = T.Line }) end)
	box.FocusLost:Connect(function() tween(field, 0.12, { BackgroundColor3 = T.PanelSoft }) end)
	return { Instance = row, Set = function(_, v) box.Text = tostring(v) end,
		Get = function() return box.Text end }
end

function Tab:Slider(o)
	o = o or {}
	local min = tonumber(o.Min) or 0
	local max = tonumber(o.Max) or 100
	local val = math.clamp(tonumber(o.Default) or min, min, max)
	local row = rowShell(self, 58)
	local head = new("TextLabel", { BackgroundTransparency = 1, Font = FONT_BOLD, TextSize = 12,
		TextColor3 = T.Dim, TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(12, 8), Size = UDim2.new(1, -24, 0, 14),
		Text = tostring(o.Title or "") .. ": " .. tostring(val) }, row)
	local bar = new("Frame", { BackgroundColor3 = T.PanelSoft, Position = UDim2.fromOffset(12, 32),
		Size = UDim2.new(1, -24, 0, 8) }, row)
	round(bar, 4)
	local fillBar = new("Frame", { BackgroundColor3 = T.Accent, BorderSizePixel = 0,
		Size = UDim2.fromScale((val - min) / math.max(1, max - min), 1) }, bar)
	round(fillBar, 4)
	local function setFromX(x)
		local rel = math.clamp((x - bar.AbsolutePosition.X) / math.max(1, bar.AbsoluteSize.X), 0, 1)
		val = math.floor(min + rel * (max - min) + 0.5)
		fillBar.Size = UDim2.fromScale(rel, 1)
		head.Text = tostring(o.Title or "") .. ": " .. tostring(val)
		if o.Callback then task.spawn(function() pcall(o.Callback, val) end) end
	end
	local hit = new("TextButton", { BackgroundTransparency = 1, Text = "",
		Position = UDim2.fromOffset(12, 24), Size = UDim2.new(1, -24, 0, 24),
		AutoButtonColor = false }, row)
	local held = false
	hit.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1
			or i.UserInputType == Enum.UserInputType.Touch then
			held = true; setFromX(i.Position.X)
		end
	end)
	UserInput.InputChanged:Connect(function(i)
		if held and (i.UserInputType == Enum.UserInputType.MouseMovement
			or i.UserInputType == Enum.UserInputType.Touch) then setFromX(i.Position.X) end
	end)
	UserInput.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1
			or i.UserInputType == Enum.UserInputType.Touch then held = false end
	end)
	return { Instance = row, Set = function(_, v)
		val = math.clamp(tonumber(v) or min, min, max)
		fillBar.Size = UDim2.fromScale((val - min) / math.max(1, max - min), 1)
		head.Text = tostring(o.Title or "") .. ": " .. tostring(val)
	end, Get = function() return val end }
end

function Tab:Keybind(o)
	o = o or {}
	local row = rowShell(self, 40)
	titleAndDesc(row, o.Title, o.Desc, 80)
	local chip = new("TextLabel", { BackgroundColor3 = T.PanelSoft, AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(58, 24),
		Font = FONT_BOLD, TextSize = 12, TextColor3 = T.Text,
		Text = tostring(o.Value or o.Default or "None") }, row)
	round(chip, 7)
	return { Instance = row, Set = function(_, v) chip.Text = tostring(v) end }
end

-- The dropdown opens a floating list, the way the reference's "Rare Weapons"
-- panel does, rather than pushing the page around.
function Tab:Dropdown(o)
	o = o or {}
	local values = o.Values or {}
	local chosen = o.Value
	local row = rowShell(self, 62)
	new("TextLabel", { BackgroundTransparency = 1, Font = FONT_BOLD, TextSize = 12,
		TextColor3 = T.Dim, TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(12, 8), Size = UDim2.new(1, -24, 0, 14),
		Text = tostring(o.Title or "") }, row)
	local btn = new("TextButton", {
		BackgroundColor3 = T.PanelSoft, Position = UDim2.fromOffset(10, 26),
		Size = UDim2.new(1, -20, 0, 28), Font = FONT, TextSize = 13, TextColor3 = T.Text,
		TextXAlignment = Enum.TextXAlignment.Left, AutoButtonColor = false,
		Text = "   " .. (tostring(chosen ~= nil and chosen ~= "" and chosen or "Select...")),
	}, row)
	round(btn, 8)
	new("TextLabel", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(14, 14),
		Font = FONT_BOLD, TextSize = 12, TextColor3 = T.Faint, Text = "v" }, btn)

	local panel, open = nil, false
	local function close()
		open = false
		if panel then pcall(function() panel:Destroy() end) panel = nil end
	end
	local function build()
		close()
		open = true
		panel = new("Frame", { BackgroundColor3 = T.Panel, ZIndex = 50,
			Position = UDim2.fromOffset(10, 56), Size = UDim2.new(1, -20, 0, 0) }, row)
		round(panel, 10); stroke(panel, T.Line, 1, 0.2)
		local sc = new("ScrollingFrame", {
			BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 51,
			Size = UDim2.new(1, -8, 0, 0), Position = UDim2.fromOffset(4, 4),
			AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(),
			ScrollBarThickness = 3, ScrollBarImageColor3 = T.Line,
		}, panel)
		list(sc, 3)
		local n = 0
		for _, v in ipairs(values) do
			n = n + 1
			local item = new("TextButton", {
				BackgroundColor3 = (tostring(v) == tostring(chosen)) and T.Accent or T.PanelSoft,
				Size = UDim2.new(1, 0, 0, 28), Font = FONT, TextSize = 12, ZIndex = 52,
				TextColor3 = (tostring(v) == tostring(chosen)) and T.OnAccent or T.Text,
				TextXAlignment = Enum.TextXAlignment.Left, AutoButtonColor = false,
				Text = "   " .. tostring(v), LayoutOrder = n,
			}, sc)
			round(item, 7)
			item.MouseButton1Click:Connect(function()
				chosen = v
				btn.Text = "   " .. tostring(v)
				close()
				if o.Callback then task.spawn(function() pcall(o.Callback, v) end) end
			end)
		end
		local h = math.clamp(n * 31 + 8, 34, 190)
		sc.Size = UDim2.new(1, -8, 0, h - 8)
		panel.Size = UDim2.new(1, -20, 0, 0)
		tween(panel, 0.14, { Size = UDim2.new(1, -20, 0, h) })
		row.Size = UDim2.new(1, 0, 0, 62 + h + 8)
	end
	btn.MouseButton1Click:Connect(function()
		if open then close(); row.Size = UDim2.new(1, 0, 0, 62) else build() end
	end)
	return {
		Instance = row,
		Refresh = function(_, vals)
			values = vals or {}
			if open then build() end
		end,
		Set = function(_, v) chosen = v; btn.Text = "   " .. tostring(v) end,
		Get = function() return chosen end,
	}
end

--==============================================================================
-- WINDOW
--==============================================================================
local Window = {}
Window.__index = Window

-- Seven tabs is a filing cabinet, not a menu. Related ones share a page, and the
-- script behind them does not have to know: asking for a tab that maps onto a
-- page which already exists hands back that same page, so its widgets simply
-- append under their own section heading. _G.MH_TabMap overrides the grouping.
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
	local existing = self._byTitle[title]
	if existing then
		-- second script area landing on an existing page: keep them apart
		new("Frame", {
			BackgroundColor3 = T.Line, BorderSizePixel = 0, BackgroundTransparency = 0.4,
			Size = UDim2.new(1, 0, 0, 1), LayoutOrder = existing:_order(),
		}, existing._body)
		return existing
	end
	local shown = true
	if type(_G.MH_OnlyTabs) == "table" and not _G.MH_OnlyTabs[title] then shown = false end

	local page = new("ScrollingFrame", {
		BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false,
		Size = UDim2.fromScale(1, 1), CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 3,
		ScrollBarImageColor3 = T.Line, ScrollingDirection = Enum.ScrollingDirection.Y,
	}, self._pages)
	pad(page, 0, 2, 8, 2, 12)
	list(page, 8)

	local btn
	if shown then
		btn = new("TextButton", {
			BackgroundColor3 = T.PanelSoft, BackgroundTransparency = 1,
			Size = UDim2.fromOffset(0, 30), AutomaticSize = Enum.AutomaticSize.X,
			Font = FONT_BOLD, TextSize = 13, TextColor3 = T.Dim, Text = title,
			AutoButtonColor = false, LayoutOrder = TAB_ORDER[title] or (#self._tabs + 10),
		}, self._tabbar)
		round(btn, 9)
		pad(btn, 0, 14, 14, 0, 0)
	end

	local tab = setmetatable({ _body = page, _btn = btn, _win = self, Title = title }, Tab)
	self._tabs[#self._tabs + 1] = tab
	self._byTitle[title] = tab

	local function activate()
		for _, t in ipairs(self._tabs) do
			t._body.Visible = (t == tab)
			if t._btn then
				tween(t._btn, 0.12, { BackgroundTransparency = (t == tab) and 0 or 1 })
				t._btn.TextColor3 = (t == tab) and T.Card or T.Dim
				t._btn.BackgroundColor3 = (t == tab) and T.Text or T.PanelSoft
			end
		end
	end
	if btn then btn.MouseButton1Click:Connect(activate) end
	if not self._active and shown then self._active = tab; activate() end
	return tab
end

function Window:Destroy() pcall(function() self._gui:Destroy() end) end
function Window:Toggle(v)
	self._card.Visible = (v == nil) and (not self._card.Visible) or v and true or false
end

function UI:CreateWindow(o)
	o = o or {}
	local gui = hostGui()
	local scale = tonumber(_G.MH_MenuScale) or 1

	local card = new("Frame", {
		BackgroundColor3 = T.Card, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(410, 470),
	}, gui)
	round(card, 16)
	stroke(card, T.Line, 1, 0.25)
	local uiscale = new("UIScale", { Scale = scale }, card)

	-- Fit the phone rather than assume a desktop. A fixed 430x500 card is most of
	-- a phone screen, and on a narrow one it ran off the edge entirely.
	local function fit()
		-- Trust nothing about the camera: a bad ViewportSize used to arithmetic
		-- would throw inside CreateWindow, and the caller would just see no window.
		local vx, vy = 1280, 720
		pcall(function()
			local v = workspace.CurrentCamera.ViewportSize
			if typeof(v) == "Vector2" and v.X > 10 and v.Y > 10 then vx, vy = v.X, v.Y end
		end)
		pcall(function()
			card.Size = UDim2.fromOffset(math.min(410, math.floor(vx * 0.92)),
				math.min(470, math.floor(vy * 0.78)))
			-- a narrow screen needs the contents smaller too, not just the card
			uiscale.Scale = scale * ((vx < 480) and 0.9 or 1)
		end)
	end
	fit()
	pcall(function()
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	end)

	-- header: badge, title, subtitle, close
	local head = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 62) }, card)
	local badge = new("Frame", { BackgroundColor3 = T.PanelSoft,
		Position = UDim2.fromOffset(14, 12), Size = UDim2.fromOffset(38, 38) }, head)
	round(badge, 11)
	new("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
		Font = FONT_BOLD, TextSize = 12, TextColor3 = T.Text,
		Text = tostring(o.Badge or "MH") }, badge)
	new("TextLabel", { BackgroundTransparency = 1, Font = FONT_BOLD, TextSize = 17,
		TextColor3 = T.Text, TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(62, 13), Size = UDim2.new(1, -120, 0, 20),
		Text = string.upper(tostring(o.Title or "MollyHub")) }, head)
	new("TextLabel", { BackgroundTransparency = 1, Font = FONT, TextSize = 11,
		TextColor3 = T.Faint, TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(62, 33), Size = UDim2.new(1, -120, 0, 16),
		Text = tostring(o.SubTitle or o.Author or "") }, head)
	local close = new("TextButton", { BackgroundColor3 = T.Bad, AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 14), Size = UDim2.fromOffset(34, 30),
		Font = FONT_BOLD, TextSize = 14, TextColor3 = T.OnAccent, Text = "X",
		AutoButtonColor = false }, head)
	round(close, 9)

	-- tab bar
	local tabwrap = new("Frame", { BackgroundColor3 = T.Panel,
		Position = UDim2.fromOffset(12, 62), Size = UDim2.new(1, -24, 0, 40) }, card)
	round(tabwrap, 12)
	local tabbar = new("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0,
		Position = UDim2.fromOffset(5, 5), Size = UDim2.new(1, -10, 1, -10),
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollBarThickness = 0, ScrollingDirection = Enum.ScrollingDirection.X }, tabwrap)
	local tl = list(tabbar, 5, Enum.FillDirection.Horizontal)
	tl.VerticalAlignment = Enum.VerticalAlignment.Center

	local pages = new("Frame", { BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 110), Size = UDim2.new(1, -24, 1, -122) }, card)

	draggable(card, head)

	local win = setmetatable({
		_gui = gui, _card = card, _tabbar = tabbar, _pages = pages,
		_tabs = {}, _byTitle = {},
	}, Window)

	-- closing hides the card and leaves a small pill to bring it back
	local pill = new("TextButton", {
		BackgroundColor3 = T.Accent, AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.fromOffset(18, 18), Size = UDim2.fromOffset(104, 32),
		Font = FONT_BOLD, TextSize = 13, TextColor3 = T.OnAccent, Visible = false,
		Text = tostring(o.Title or "MollyHub"), AutoButtonColor = false,
	}, gui)
	round(pill, 10)
	draggable(pill, pill)
	close.MouseButton1Click:Connect(function() card.Visible = false; pill.Visible = true end)
	pill.MouseButton1Click:Connect(function() card.Visible = true; pill.Visible = false end)

	return win
end

-- Rubis is called either way round in the wild.
UI.Window = UI.CreateWindow
UI.Notification = UI.Notify

return UI
