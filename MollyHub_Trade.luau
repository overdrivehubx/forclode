--!nocheck
--[[
================================================================================
  MollyHub — TRADE + EQUIP SPAWNER
================================================================================
  The full harness, running on the MollyUI interface instead of Rubis.

  The harness is not copied here. It is fetched and its menu library swapped for
  ours — MollyUI answers the same calls, so one line changes and the whole
  script comes across. That keeps a single engine: fixes to the trade logic land
  here without being ported.

  TradeDebugHarness.luau stays exactly as it was, so it remains a working
  fallback if this ever misbehaves.
================================================================================
]]

local BRANCH = "https://raw.githubusercontent.com/overdrivehubx/forclode/"
	.. "claude/trading-ui-offline-harness-vxuc86/"

local RUBIS = "https://api.rubis.app/v2/scrap/D9CpDTMz8Hh4v1wA/raw"

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
	return fail("could not download the harness — check your connection")
end

-- Point the harness at our interface. The url is escaped into a literal
-- pattern: "." and friends would otherwise be wildcards, and a replace that
-- quietly matched the wrong thing is worse than one that does not match.
local literal = RUBIS:gsub("(%W)", "%%%1")
local swapped, n = src:gsub(literal, (BRANCH .. "MollyUI.luau"):gsub("%%", "%%%%"), 1)
if n == 0 then
	-- Not fatal: the harness will simply load its own menu library instead.
	warn("[MollyHub] menu swap did not apply — falling back to the bundled menu")
	swapped = src
end

local fn, err = loadstring(swapped)
if not fn then return fail("the harness would not compile: " .. tostring(err)) end

local okRun, runErr = pcall(fn)
if not okRun then fail("the harness errored: " .. tostring(runErr)) end
