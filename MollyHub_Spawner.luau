--!nocheck
--[[
================================================================================
  MollyHub — EQUIP SPAWNER
================================================================================
  Weapons only. Spawn an item and wear its real skin — on your body, in your
  hand, in the equipped tile and on the round hotbar. No trade tabs.

  Same engine as the full build, same interface. The trade tabs are still built,
  because the spawner leans on parts of that code, but they are not shown:
  _G.MH_OnlyTabs tells MollyUI which tabs to put on screen.
================================================================================
]]

local BRANCH = "https://raw.githubusercontent.com/overdrivehubx/forclode/"
	.. "claude/trading-ui-offline-harness-vxuc86/"

local RUBIS = "https://api.rubis.app/v2/scrap/D9CpDTMz8Hh4v1wA/raw"

-- what stays on screen
_G.MH_OnlyTabs = { Spawner = true, Settings = true, Keybinds = true }
-- the trade side must not arm itself when nobody can reach its controls
_G.MH_SpawnerOnly = true

local function fail(msg)
	warn("[MollyHub] " .. msg)
	pcall(function()
		local gui = Instance.new("ScreenGui")
		gui.Name = "MollyHubError"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true
		gui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
		local f = Instance.new("TextLabel")
		f.Size = UDim2.fromOffset(460, 120); f.Position = UDim2.new(0.5, -230, 0, 60)
		f.BackgroundColor3 = Color3.fromRGB(28, 18, 22); f.BorderSizePixel = 0
		f.TextColor3 = Color3.fromRGB(255, 170, 170); f.Font = Enum.Font.Code
		f.TextSize = 14; f.TextWrapped = true; f.Text = "  [MollyHub] " .. msg
		f.Parent = gui
		Instance.new("UICorner", f).CornerRadius = UDim.new(0, 10)
	end)
end

local okSrc, src = pcall(function()
	return game:HttpGet(BRANCH .. "TradeDebugHarness.luau")
end)
if not okSrc or type(src) ~= "string" or #src < 1024 then
	return fail("could not download the engine — check your connection")
end

local literal = RUBIS:gsub("(%W)", "%%%1")
local swapped, n = src:gsub(literal, (BRANCH .. "MollyUI.luau"):gsub("%%", "%%%%"), 1)
if n == 0 then
	warn("[MollyHub] menu swap did not apply — falling back to the bundled menu")
	swapped = src
end

local fn, err = loadstring(swapped)
if not fn then return fail("the engine would not compile: " .. tostring(err)) end

local okRun, runErr = pcall(fn)
if not okRun then fail("the engine errored: " .. tostring(runErr)) end
