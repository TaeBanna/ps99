task.spawn(function()
	local CONFIG = {
		Title = "Anti-AFK",
		FallbackInterval = 240,
		StopOnClose = false,
	}

	repeat task.wait() until game:IsLoaded()

	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local UserInputService = game:GetService("UserInputService")
	local TweenService = game:GetService("TweenService")
	local Stats = game:GetService("Stats")
	local VirtualUser = game:GetService("VirtualUser")
	local CoreGui = game:GetService("CoreGui")

	repeat task.wait() until Players.LocalPlayer
	local LocalPlayer = Players.LocalPlayer

	local env = (getgenv and getgenv()) or _G

	if type(env.VyAntiAfk) == "table" and env.VyAntiAfk.Destroy then
		pcall(env.VyAntiAfk.Destroy)
	end

	local state = { running = true, pulses = 0 }
	env.VyAntiAfk = state

	local connections = {}
	local function track(conn)
		connections[#connections + 1] = conn
		return conn
	end

	local lastPulse = os.clock()

	local function pulse()
		lastPulse = os.clock()
		state.pulses = state.pulses + 1
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new(0, 0))
		end)
	end

	local function nudge()
		pcall(function()
			local vim = game:GetService("VirtualInputManager")
			vim:SendKeyEvent(true, Enum.KeyCode.F13, false, game)
			task.wait(0.05)
			vim:SendKeyEvent(false, Enum.KeyCode.F13, false, game)
		end)
	end

	if getconnections then
		pcall(function()
			for _, c in ipairs(getconnections(LocalPlayer.Idled)) do
				if c.Disable then
					c:Disable()
				elseif c.Disconnect then
					c:Disconnect()
				end
			end
		end)
	end

	track(LocalPlayer.Idled:Connect(function()
		pulse()
	end))

	local function getGuiParent()
		if gethui then
			local ok, result = pcall(gethui)
			if ok and result then
				return result
			end
		end
		return CoreGui
	end

	local function create(class, props, parent)
		local inst = Instance.new(class)
		for k, v in pairs(props) do
			inst[k] = v
		end
		inst.Parent = parent
		return inst
	end

	local WHITE = Color3.fromRGB(255, 255, 255)
	local GREEN = Color3.fromRGB(90, 220, 120)

	local gui = create("ScreenGui", {
		Name = "VyAntiAfkGui",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	pcall(function()
		if syn and syn.protect_gui then
			syn.protect_gui(gui)
		end
	end)
	gui.Parent = getGuiParent()

	local main = create("Frame", {
		Name = "Main",
		BackgroundColor3 = Color3.fromRGB(30, 30, 30),
		BorderSizePixel = 0,
		Position = UDim2.new(0.085, 0, 0.13, 0),
		Size = UDim2.new(0, 225, 0, 96),
	}, gui)
	create("UICorner", { CornerRadius = UDim.new(0, 8) }, main)

	local function makeLabel(props)
		props.BackgroundTransparency = 1
		props.Font = props.Font or Enum.Font.SourceSans
		props.TextColor3 = props.TextColor3 or WHITE
		props.TextSize = props.TextSize or 14
		props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
		return create("TextLabel", props, main)
	end

	makeLabel({
		Name = "Title",
		Text = CONFIG.Title,
		Font = Enum.Font.SourceSansBold,
		Position = UDim2.new(0, 10, 0, 3),
		Size = UDim2.new(0, 170, 0, 20),
	})

	local closeBtn = create("TextButton", {
		Name = "Close",
		BackgroundTransparency = 1,
		Font = Enum.Font.SourceSansBold,
		Text = "X",
		TextColor3 = WHITE,
		TextSize = 14,
		Position = UDim2.new(1, -30, 0, 3),
		Size = UDim2.new(0, 26, 0, 20),
	}, main)

	local divider = create("Frame", {
		Name = "Divider",
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 6, 0, 25),
		Size = UDim2.new(1, -12, 0, 2),
	}, main)
	create("UICorner", { CornerRadius = UDim.new(0, 50) }, divider)

	local pingLabel = makeLabel({
		Name = "Ping",
		Text = "Ping: --",
		Position = UDim2.new(0, 10, 0, 32),
		Size = UDim2.new(0, 100, 0, 20),
	})

	local fpsLabel = makeLabel({
		Name = "Fps",
		Text = "FPS: --",
		Position = UDim2.new(0, 115, 0, 32),
		Size = UDim2.new(0, 100, 0, 20),
	})

	local statusLabel = makeLabel({
		Name = "Status",
		Text = "Anti-AFK: Active (pulses: 0)",
		TextColor3 = GREEN,
		Position = UDim2.new(0, 10, 0, 54),
		Size = UDim2.new(1, -20, 0, 18),
	})

	local timerLabel = makeLabel({
		Name = "Timer",
		Text = "Uptime: 00:00:00",
		Position = UDim2.new(0, 10, 0, 72),
		Size = UDim2.new(1, -20, 0, 18),
	})

	local dragging, dragInput, dragStart, startPos

	local function updateDrag(input)
		local delta = input.Position - dragStart
		local goal = {
			Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
			),
		}
		TweenService:Create(main, TweenInfo.new(0.04, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), goal):Play()
	end

	track(main.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = main.Position
			local c
			c = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					c:Disconnect()
				end
			end)
		end
	end))

	track(main.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			dragInput = input
		end
	end))

	track(UserInputService.InputChanged:Connect(function(input)
		if input == dragInput and dragging then
			updateDrag(input)
		end
	end))

	function state.Destroy()
		state.running = false
		for _, c in ipairs(connections) do
			pcall(function() c:Disconnect() end)
		end
		connections = {}
		pcall(function() gui:Destroy() end)
		if env.VyAntiAfk == state then
			env.VyAntiAfk = nil
		end
	end

	track(closeBtn.MouseButton1Click:Connect(function()
		if CONFIG.StopOnClose then
			state.Destroy()
		else
			pcall(function() gui:Destroy() end)
		end
	end))

	local function getPing()
		local ok, value = pcall(function()
			return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
		end)
		if ok and type(value) == "number" then
			return value
		end
		ok, value = pcall(function()
			return LocalPlayer:GetNetworkPing() * 1000
		end)
		if ok and type(value) == "number" then
			return value
		end
		return nil
	end

	local function formatTime(total)
		return string.format("%02d:%02d:%02d", math.floor(total / 3600), math.floor(total / 60) % 60, total % 60)
	end

	local frames = 0
	local lastFpsTick = os.clock()
	local startTime = os.time()

	track(RunService.RenderStepped:Connect(function()
		frames = frames + 1
	end))

	task.spawn(function()
		while state.running do
			task.wait(1)
			if not state.running then
				break
			end

			pcall(function()
				local now = os.clock()
				local fps = math.floor(frames / math.max(now - lastFpsTick, 0.001) + 0.5)
				frames = 0
				lastFpsTick = now

				if now - lastPulse >= CONFIG.FallbackInterval then
					pulse()
					nudge()
				end

				if gui.Parent then
					local ping = getPing()
					pingLabel.Text = ping and ("Ping: " .. math.floor(ping + 0.5) .. " ms") or "Ping: n/a"
					fpsLabel.Text = "FPS: " .. fps
					statusLabel.Text = "Anti-AFK: Active (pulses: " .. state.pulses .. ")"
					timerLabel.Text = "Uptime: " .. formatTime(os.time() - startTime)
				end
			end)
		end
	end)
end)

if not game:IsLoaded() then game.Loaded:Wait() end

getgenv().LimonOrb = getgenv().LimonOrb or {}
local C = getgenv().LimonOrb
C.running = C.running ~= false
C.verb = C.verb ~= false
C.breakAll = C.breakAll == true
C.breakAllDelay = math.max(0.05, tonumber(C.breakAllDelay) or 0.12)
C.breakAllParent = C.breakAllParent or "HatchWar"
C.petSpeed = C.petSpeed == true
C.superMagnet = C.superMagnet == true
C.efficientFarm = C.efficientFarm == true
C.autoJoin = C.autoJoin ~= false
C.whiteScreen = C.whiteScreen == true
C.fpsCap = math.floor(math.clamp(tonumber(C.fpsCap) or 30, 1, 240))
C.autoBoss = false
C.bossClickDelay = math.clamp(tonumber(C.bossClickDelay) or 0.1, 0, 3)
C.manorHatch = false
C.manorAmount = math.max(0, math.floor(tonumber(C.manorAmount) or 0))
C.autoKnock = C.autoKnock == true
C.autoBuyHouses = C.autoBuyHouses == true
C.doorsMethod = C.doorsMethod == "Walk" and "Walk" or "Teleport"

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")
local GuiService = game:GetService("GuiService")
local VirtualInputManager = nil
pcall(function() VirtualInputManager = game:GetService("VirtualInputManager") end)
local lp = Players.LocalPlayer

C._runId = (C._runId or 0) + 1
local MY_RUN = C._runId
if C._efConns then
    for _, c in ipairs(C._efConns) do pcall(function() c:Disconnect() end) end
end
C._efConns = {}
local function alive() return MY_RUN == C._runId end
local function log(...) if C.verb then print("[VY]", ...) end end
local doorsHoldUntil = 0 -- door teleport / walk window, pauses the Boss / Manor movers
local function doorsHolding() return os.clock() < doorsHoldUntil end
local doorsPriorityUntil = 0 -- doors ready to open: Auto Boss / Manor pause until they are done
local function doorsPriority() return os.clock() < doorsPriorityUntil end
local doorsWalkTarget = nil -- hoverboard steering target while walking to a door

C.antiAfk = C.antiAfk ~= false
if C._afkConn then pcall(function() C._afkConn:Disconnect() end) end
if C._aaConns then
    for _, c in ipairs(C._aaConns) do pcall(function() c:Disconnect() end) end
    C._aaConns = nil
end
C._afkConn = lp.Idled:Connect(function()
    if not C.antiAfk then return end
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
end)

local function getZoneRoot()
    local things = workspace:FindFirstChild("__THINGS")
    local container = things and things:FindFirstChild("__INSTANCE_CONTAINER")
    local active = container and container:FindFirstChild("Active")
    return active and active:FindFirstChild("HatchWar")
end

local function setIdentity(n)
    local f = setthreadidentity or set_thread_identity or (syn and syn.set_thread_identity)
    if f then pcall(f, n) end
end

local function fireNetwork(name)
    task.spawn(function()
        pcall(function()
            local net = RS:WaitForChild("Network", 10)
            local remote = net and net:WaitForChild(name, 10)
            if remote then remote:FireServer() end
        end)
    end)
end

local function clientModule(name, timeout)
    local lib = RS:WaitForChild("Library", timeout or 10)
    local client = lib and lib:WaitForChild("Client", timeout or 10)
    return client and client:WaitForChild(name, timeout or 10)
end

local PlayerPet = nil
pcall(function() PlayerPet = require(RS.Library.Client.PlayerPet) end)

local SPEED_HOOK_VERSION = 2

local function installPetSpeed()
    if C._speedHookVersion == SPEED_HOOK_VERSION then return true end
    if not hookfunction or not PlayerPet or type(PlayerPet.CalculateSpeedMultiplier) ~= "function" then
        return false
    end
    local orig
    local ok = pcall(function()
        orig = hookfunction(PlayerPet.CalculateSpeedMultiplier, function(...)
            if C.petSpeed then return math.huge end
            if C.efficientFarm then return 500 end
            return orig(...)
        end)
    end)
    if ok and orig ~= nil then C._speedHookVersion = SPEED_HOOK_VERSION end
    return C._speedHookVersion == SPEED_HOOK_VERSION
end

local magnetConfigBackup = setmetatable({}, { __mode = "k" })

local function applyMagnetConfig(r)
    if C.superMagnet then
        r.config = r.config or {}
        if magnetConfigBackup[r.config] == nil then
            magnetConfigBackup[r.config] = { orig = r.config.SuperMagnet }
        end
        r.config.SuperMagnet = true
    elseif type(r.config) == "table" and magnetConfigBackup[r.config] then
        r.config.SuperMagnet = magnetConfigBackup[r.config].orig
        magnetConfigBackup[r.config] = nil
    end
end

local function installMagnet()
    if C._magnetPatched then return true end
    local applied = 0

    local function patch(name, fn)
        local m = clientModule(name, 10)
        if not m then return end
        local ok, mod = pcall(require, m)
        if not ok or type(mod) ~= "table" then return end
        pcall(function() if setreadonly then setreadonly(mod, false) end end)
        if pcall(fn, mod) then applied += 1 end
    end

    patch("EnchantCmds", function(e)
        local o = e.GetPower
        e.GetPower = function(...)
            local p = ...
            if C.superMagnet and (p == "Super Magnet" or p == "Magnet") then return 999 end
            return o(...)
        end
    end)

    patch("UpgradeCmds", function(u)
        local o = u.GetPower
        u.GetPower = function(...)
            if C.superMagnet and (...) == "Magnet" then return 999 end
            return o(...)
        end
    end)

    patch("InstancingCmds", function(i)
        local g = i.Get
        if type(g) ~= "function" then error("no Get") end
        i.Get = function(...)
            local r = g(...)
            if type(r) == "table" then pcall(applyMagnetConfig, r) end
            return r
        end
    end)

    C._magnetPatched = applied > 0
    return C._magnetPatched
end

local breakJoinRemote = RS:FindFirstChild("Network") and RS.Network:FindFirstChild("Breakables_JoinPetBulk")
local breakAssign = {}

local function eventBreakableUIDs()
    local out = {}
    local things = workspace:FindFirstChild("__THINGS")
    local br = things and things:FindFirstChild("Breakables")
    if not br then return out end
    for _, m in ipairs(br:GetChildren()) do
        if m:IsA("Model") and m:GetAttribute("ParentID") == C.breakAllParent then
            local uid = m:GetAttribute("BreakableUID")
            if uid then out[#out + 1] = uid end
        end
    end
    return out
end

local function equippedPetEuids()
    local out = {}
    if not PlayerPet then return out end
    for _, p in pairs(PlayerPet.GetAll()) do
        if p and p.euid then out[#out + 1] = p.euid end
    end
    return out
end

local function breakAllTick()
    if not (C.breakAll and breakJoinRemote) then return end
    local pets = equippedPetEuids()
    if #pets == 0 then return end
    local list = eventBreakableUIDs()
    if #list == 0 then return end
    local live = {}
    for _, uid in ipairs(list) do live[uid] = true end
    local used = {}
    for e, uid in pairs(breakAssign) do
        if live[uid] then used[uid] = true else breakAssign[e] = nil end
    end
    local free = {}
    for _, uid in ipairs(list) do
        if not used[uid] then free[#free + 1] = uid end
    end
    local map = {}
    for _, e in ipairs(pets) do
        if not breakAssign[e] and #free > 0 then breakAssign[e] = table.remove(free) end
        if breakAssign[e] and live[breakAssign[e]] then map[e] = breakAssign[e] end
    end
    if next(map) then
        pcall(function() breakJoinRemote:FireServer(map) end)
    end
end

task.spawn(function()
    while alive() do
        if C.running and C.breakAll then
            pcall(breakAllTick)
            task.wait(math.max(0.05, tonumber(C.breakAllDelay) or 0.12))
        else
            task.wait(0.2)
        end
    end
end)

local efReady = false
local efNetwork, efMapCmds

local function efNearbyBreakables()
    local out = {}
    local character = lp.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    local things = workspace:FindFirstChild("__THINGS")
    local folder = things and things:FindFirstChild("Breakables")
    if not (hrp and folder) then return out end

    local zone = efMapCmds.GetCurrentZone()
    for _, b in ipairs(folder:GetChildren()) do
        local parentID = b:GetAttribute("ParentID")
        if parentID == "TimeTrial" or parentID == zone then
            local uid = b:GetAttribute("BreakableUID")
            local part = b:FindFirstChildWhichIsA("BasePart", true)
            if uid and part and (part.Position - hrp.Position).Magnitude <= 1500 then
                out[#out + 1] = uid
            end
        end
    end
    return out
end

local function efficientFarmTick()
    local pets = equippedPetEuids()
    local list = efNearbyBreakables()
    local breakableCount = #list
    if #pets == 0 or breakableCount == 0 then return end

    local map = {}
    for i, euid in ipairs(pets) do
        map[euid] = list[(i - 1) % breakableCount + 1]
    end

    if efNetwork.UnreliableFire then
        pcall(efNetwork.UnreliableFire, "Breakables_PlayerDealDamage", list[1])
    end
    pcall(efNetwork.Fire, "Breakables_JoinPetBulk", map)
end

local function efConnectLoot(folderName, eventName)
    task.spawn(function()
        local things = workspace:WaitForChild("__THINGS", 10)
        local folder = things and things:WaitForChild(folderName, 10)
        if not folder or not alive() then return end
        local conn = folder.ChildAdded:Connect(function(item)
            if not (C.running and C.efficientFarm) then return end
            pcall(function()
                efNetwork.Fire(eventName, { item.Name })
                item:Destroy()
            end)
        end)
        table.insert(C._efConns, conn)
    end)
end

local function installEfficientFarm()
    if efReady then return true end

    local t = os.clock()
    while not lp:GetAttribute("__LOADED") and os.clock() - t < 15 do task.wait() end

    local okN, N = pcall(function() return require(clientModule("Network", 10)) end)
    local okM, M = pcall(function() return require(clientModule("MapCmds", 10)) end)
    if not (okN and okM and type(N) == "table" and type(M) == "table"
        and type(N.Fire) == "function" and type(M.GetCurrentZone) == "function") then
        return false
    end

    efNetwork, efMapCmds = N, M
    efReady = true
    efConnectLoot("Lootbags", "Lootbags_Claim")
    efConnectLoot("Orbs", "Orbs: Collect")
    return true
end

task.spawn(function()
    while alive() do
        if C.running and C.efficientFarm and efReady then
            pcall(efficientFarmTick)
            task.wait(0.05)
        else
            task.wait(0.2)
        end
    end
end)

local getIdentityFn = getthreadidentity or get_thread_identity or getidentity or (syn and syn.get_thread_identity)
local BASE_IDENTITY = 7
if getIdentityFn then
    local okId, id = pcall(getIdentityFn)
    if okId and type(id) == "number" and id >= 3 then BASE_IDENTITY = id end
end
local function restoreIdentity()
    setIdentity(BASE_IDENTITY)
end

local hoverboardCmds = nil
local function getHoverboardCmds()
    if hoverboardCmds then return hoverboardCmds end
    local ok, mod = pcall(function() return require(RS.Library.Client.HoverboardCmds) end)
    if ok and type(mod) == "table" then hoverboardCmds = mod end
    return hoverboardCmds
end

local function hoverboardOn()
    if lp:GetAttribute("UsingHoverboard") == true then return true end
    local cmds = getHoverboardCmds()
    if cmds and type(cmds.IsEquipped) == "function" then
        local ok, equipped = pcall(cmds.IsEquipped)
        if ok and equipped then return true end
    end
    return false
end

local hoverboardHooked = false
local function installHoverboardSteering()
    if hoverboardHooked then
        local cls = C._hbClass
        local okC, current = pcall(function() return cls and cls.ComputeMoveDirection end)
        if okC and current ~= nil and current == C._hbHook then return true end
        hoverboardHooked = false
    end

    local class
    local playerScripts = lp:FindFirstChild("PlayerScripts")
    if playerScripts then
        for _, d in ipairs(playerScripts:GetDescendants()) do
            if d:IsA("ModuleScript") and d.Name == "HoverboardInstance" then
                local ok, mod = pcall(require, d)
                if ok and type(mod) == "table" and type(mod.ComputeMoveDirection) == "function" then
                    class = mod
                    break
                end
            end
        end
    end
    if not class then return false end

    if C._hbClass ~= class or type(C._hbOriginal) ~= "function" then
        C._hbClass = class
        C._hbOriginal = class.ComputeMoveDirection
    end
    local original = C._hbOriginal

    pcall(function() if setreadonly then setreadonly(class, false) end end)
    local hook = function(self, ...)
        if self._isLocal and doorsHolding() then
            local walkTo = doorsWalkTarget
            local hbRoot = self._humanoidRootPart
            if walkTo and hbRoot then
                local flatWalk = Vector3.new(walkTo.X - hbRoot.Position.X, 0, walkTo.Z - hbRoot.Position.Z)
                local dist = flatWalk.Magnitude
                if dist > 2 then return flatWalk.Unit * math.clamp(dist / 8, 0.35, 1) end
            end
            return Vector3.zero
        end
        return original(self, ...)
    end
    local okSet = pcall(function() class.ComputeMoveDirection = hook end)
    if not okSet then return false end

    C._hbHook = hook
    hoverboardHooked = true
    return true
end

local startBoss, stopBoss
local bossLabel
local trickActiveUntil = 0
local function trickTapping() return os.clock() < trickActiveUntil end
local trickWaitUntil, trickSeenFight = 0, false
local bossScanCircles

do
    local BOSS_ZONE = 6
    local BOSS_PATH = { "INTERACT", "Bosses", "Boss" .. BOSS_ZONE, "BossRig" }
    local BOSS_OFFSET = Vector3.new(0, 3, 0)
    local BOSS_FALLBACK = Vector3.new(7626.6, 16, 21980.4)
    local TELEPORT_EVERY = 2
    local START_EVERY = 2
    local FIGHT_IDLE = 6
    local START_GRACE = 8
    local CIRCLE_WAIT = 10
    local FIGHT_MAX = 90
    local PRESS_E_EVERY = 5

    local CIRCLE_NAME = "LiveCircle"
    local METHOD = "auto"
    local CLICK_JITTER = 0.02
    local RETRY_AFTER = 0.15
    local MAX_TRIES = 6
    local MAX_TAPS_PER_SEC = 8
    local CLICK_OFFSET_X, CLICK_OFFSET_Y = 0, 0

    local circles = {}
    local lastCircleAt = -math.huge
    local stats = { hit = 0, lost = 0, taps = 0 }
    local wins = { click = 0, signal = 0 }
    local HAS_SIGNAL = type(firesignal) == "function" or type(getconnections) == "function"
    local bossState = "idle"

    local function clickDelay()
        local d = math.clamp(tonumber(C.bossClickDelay) or 0.1, 0, 3)
        return d + math.random() * CLICK_JITTER
    end

    local function setBossState(text)
        if text ~= bossState then
            bossState = text
            log("Boss:", text)
        end
    end

    local HatchWarBoss = nil
    local function loadBossModule()
        if HatchWarBoss then return end
        pcall(function()
            local node = RS
            for _, name in ipairs({ "Library", "Util", "HatchWarBoss" }) do
                node = node and node:FindFirstChild(name)
            end
            if node then HatchWarBoss = require(node) end
        end)
    end
    loadBossModule()

    local function tapInterval()
        local rate = MAX_TAPS_PER_SEC
        if HatchWarBoss and type(HatchWarBoss.ClicksPerSecondCap) == "function" then
            local ok, cap = pcall(HatchWarBoss.ClicksPerSecondCap)
            if ok and type(cap) == "number" and cap > 0 then
                rate = math.min(rate, cap * 0.8)
            end
        end
        local delay = math.clamp(tonumber(C.bossClickDelay) or 0.1, 0, 3)
        return math.max(1 / math.max(rate, 1), delay)
    end

    local function track(obj)
        if circles[obj] or not obj:IsA("GuiButton") then return end
        local now = os.clock()
        lastCircleAt = now
        circles[obj] = {
            born = now,
            ready = now + clickDelay(),
            last = -math.huge,
            tries = 0,
        }
    end

    local function scanCircles()
        local playerGui = lp:FindFirstChild("PlayerGui")
        if not playerGui then return end
        for _, d in ipairs(playerGui:GetDescendants()) do
            if d.Name == CIRCLE_NAME then track(d) end
        end
    end
    bossScanCircles = scanCircles

    local function circlesWanted()
        return C.autoBoss or C.autoKnock or trickTapping()
    end

    local playerGui = lp:FindFirstChild("PlayerGui")
    if playerGui then
        table.insert(C._efConns, playerGui.DescendantAdded:Connect(function(d)
            if circlesWanted() and d.Name == CIRCLE_NAME then track(d) end
        end))
    end

    local function guiInset(gui)
        local screen = gui:FindFirstAncestorWhichIsA("ScreenGui")
        if screen then
            if screen.IgnoreGuiInset then return 0, 0 end
            local ok, noInset = pcall(function()
                local mode = screen.ScreenInsets
                return mode == Enum.ScreenInsets.None or mode == Enum.ScreenInsets.DeviceSafeInsets
            end)
            if ok and noInset then return 0, 0 end
        end
        local inset = GuiService:GetGuiInset()
        return inset.X, inset.Y
    end

    local function clickPoint(btn)
        local size = btn.AbsoluteSize
        if size.X <= 0 or size.Y <= 0 then return nil end
        local pos = btn.AbsolutePosition
        local ix, iy = guiInset(btn)
        local x = math.floor(pos.X + size.X * 0.5 + ix + CLICK_OFFSET_X + 0.5)
        local y = math.floor(pos.Y + size.Y * 0.5 + iy + CLICK_OFFSET_Y + 0.5)
        local cam = workspace.CurrentCamera
        if cam then
            local vp = cam.ViewportSize
            if x < 0 or y < 0 or x > vp.X or y > vp.Y then return nil end
        end
        return x, y
    end

    local function tapClick(btn)
        if not VirtualInputManager then return false end
        local x, y = clickPoint(btn)
        if not x then return false end
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 1)
        task.wait()
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 1)
        return true
    end

    local function fireSignal(signal, ...)
        if type(firesignal) == "function" then
            return (pcall(firesignal, signal, ...))
        end
        if type(getconnections) == "function" then
            local args = { ... }
            local ok, conns = pcall(getconnections, signal)
            if ok and type(conns) == "table" then
                for _, c in ipairs(conns) do
                    pcall(function() c:Fire(table.unpack(args)) end)
                end
                return true
            end
        end
        return false
    end

    local function tapSignal(btn)
        if not HAS_SIGNAL then return false end
        local p = btn.AbsolutePosition
        local input = {
            UserInputType = Enum.UserInputType.MouseButton1,
            UserInputState = Enum.UserInputState.Begin,
            KeyCode = Enum.KeyCode.Unknown,
            Position = Vector3.new(p.X, p.Y, 0),
        }
        local a = fireSignal(btn.InputBegan, input)
        local b = fireSignal(btn.Activated, input, 1)
        local c = fireSignal(btn.MouseButton1Click)
        return a or b or c
    end

    local function primaryMethod()
        if METHOD == "click" then return "click" end
        if METHOD == "signal" then return HAS_SIGNAL and "signal" or "click" end
        if HAS_SIGNAL and wins.signal >= wins.click + 2 then return "signal" end
        return "click"
    end

    local function methodFor(info)
        local first = primaryMethod()
        if info.tries % 2 == 0 then return first end
        if METHOD == "auto" and HAS_SIGNAL then
            return first == "click" and "signal" or "click"
        end
        return first
    end

    local function tappable(btn)
        if not btn.Visible then return false end
        local screen = btn:FindFirstAncestorWhichIsA("ScreenGui")
        if screen and not screen.Enabled then return false end
        local size = btn.AbsoluteSize
        return size.X > 0 and size.Y > 0
    end

    local function tapCircle(btn, info)
        local method = methodFor(info)
        info.tries += 1
        info.last = os.clock()
        stats.taps += 1

        local sent
        if method == "signal" then
            sent = tapSignal(btn)
        else
            sent = tapClick(btn)
            if not sent and METHOD == "auto" and HAS_SIGNAL then
                method = "signal"
                sent = tapSignal(btn)
            end
        end
        info.method = method
    end

    local function pressE()
        if not VirtualInputManager then return end
        pcall(function()
            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game)
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
        end)
    end

    local function bossPivot()
        local node = getZoneRoot()
        for _, name in ipairs(BOSS_PATH) do
            node = node and node:FindFirstChild(name)
        end
        if not node then return nil end
        local ok, cf = pcall(function() return node:GetPivot() end)
        if ok and typeof(cf) == "CFrame" then return cf end
        return nil
    end

    local function teleportToBoss(root)
        if not getZoneRoot() then return nil, false end

        local pivot = bossPivot()
        local destination = pivot and (pivot.Position + BOSS_OFFSET) or BOSS_FALLBACK
        local rotation = root.CFrame - root.CFrame.Position

        root.CFrame = CFrame.new(destination) * rotation
        pcall(function()
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
        return destination, pivot ~= nil
    end

    task.spawn(function()
        local lastTap = -math.huge
        while alive() do
            if not (C.running and circlesWanted()) then
                task.wait(0.2)
            else
                task.wait()
                local ok, err = pcall(function()
                    local now = os.clock()
                    local best, bestInfo
                    for btn, info in pairs(circles) do
                        if btn.Name ~= CIRCLE_NAME then
                            stats.hit += 1
                            if info.method then wins[info.method] += 1 end
                            circles[btn] = nil
                        elseif btn.Parent == nil then
                            stats.lost += 1
                            circles[btn] = nil
                        elseif info.tries < MAX_TRIES and info.ready <= now
                            and now - info.last >= RETRY_AFTER and tappable(btn) then
                            if not best or info.born < bestInfo.born then best, bestInfo = btn, info end
                        end
                    end

                    if best and not GuiService.MenuIsOpen and now - lastTap >= tapInterval() then
                        lastTap = now
                        tapCircle(best, bestInfo)
                    end
                end)
                if not ok then log("Boss tap error:", err) end
            end
        end
    end)

    local StartRemote = nil
    local function getStartRemote()
        if StartRemote and StartRemote.Parent then return StartRemote end
        local net = RS:FindFirstChild("Network")
        StartRemote = net and net:FindFirstChild("Instancing_InvokeCustomFromClient")
        return StartRemote
    end

    local starting, startedAt, graceUntil, remoteAt = false, 0, 0, nil
    local useRemote, remoteConfirmed, lastReason = true, false, nil

    local function fightActive(now)
        return (starting and now - startedAt < FIGHT_MAX)
            or now < graceUntil
            or now - lastCircleAt < FIGHT_IDLE
    end

    local function startFight()
        local now = os.clock()
        if starting and now - startedAt >= FIGHT_MAX then starting = false end
        if useRemote then
            local remote = getStartRemote()
            if remote then
                if starting then return end
                starting, startedAt = true, now
                task.spawn(function()
                    local ok, a, b = pcall(function()
                        return remote:InvokeServer("HatchWar", "HW_Boss_Start", BOSS_ZONE)
                    end)
                    starting = false
                    if ok and a then
                        graceUntil, remoteAt, lastReason = os.clock() + START_GRACE, os.clock(), nil
                        log("Boss: fight started (remote)")
                    else
                        local why = tostring(ok and b or a)
                        if why ~= lastReason then
                            lastReason = why
                            log("Boss: start refused -", why)
                        end
                    end
                end)
                return
            end
        end
        graceUntil = now + PRESS_E_EVERY
        pressE()
    end

    task.spawn(function()
        local lastTeleport, lastStart, wasOn = -math.huge, -math.huge, false

        while alive() do
            task.wait(0.1)

            if not (C.running and C.autoBoss) then
                if wasOn then
                    wasOn = false
                    setBossState("idle")
                end
                task.wait(0.3)
            else
                if not wasOn then
                    wasOn = true
                    lastTeleport, lastStart, graceUntil = -math.huge, -math.huge, 0
                    useRemote, remoteConfirmed, remoteAt, lastReason = true, false, nil, nil
                end

                local ok, err = pcall(function()
                    local char = lp.Character
                    local hum = char and char:FindFirstChildOfClass("Humanoid")
                    local root = char and char:FindFirstChild("HumanoidRootPart")
                    if not (hum and root and hum.Health > 0) then
                        task.wait(0.5)
                        return
                    end
                    if not getZoneRoot() then
                        setBossState("waiting for HatchWar")
                        task.wait(0.5)
                        return
                    end

                    local now = os.clock()

                    if doorsPriority() then
                        setBossState(fightActive(now) and "fighting (doors next)" or "paused - opening doors")
                        return
                    end

                    if now - lastTeleport >= TELEPORT_EVERY and not doorsHolding() then
                        lastTeleport = now
                        teleportToBoss(root)
                    end

                    if useRemote and remoteAt and not remoteConfirmed then
                        if lastCircleAt >= startedAt then
                            remoteConfirmed = true
                        elseif now - remoteAt > CIRCLE_WAIT and not starting then
                            useRemote = false
                            log("Boss: remote started a fight but no circles showed - starting with E instead")
                        end
                    end

                    if fightActive(now) then
                        setBossState("fighting")
                    elseif now - lastStart >= START_EVERY and not doorsHolding() then
                        lastStart = now
                        setBossState("starting fight")
                        if not GuiService.MenuIsOpen then startFight() end
                    end
                end)
                if not ok then log("Boss loop error:", err) end
            end
        end
    end)

    task.spawn(function()
        while alive() do
            if bossLabel then
                if C.autoBoss then
                    bossLabel.Text = ("Boss: %s | hit %d | lost %d | taps %d"):format(bossState, stats.hit, stats.lost, stats.taps)
                elseif (C.autoKnock or trickTapping()) and os.clock() - lastCircleAt < FIGHT_IDLE then
                    bossLabel.Text = ("Boss: tapping door fight circles | hit %d | taps %d"):format(stats.hit, stats.taps)
                else
                    bossLabel.Text = "Boss: idle"
                end
            end
            task.wait(0.5)
        end
    end)

    startBoss = function()
        loadBossModule()
        table.clear(circles)
        scanCircles()
        setBossState("starting")
    end

    stopBoss = function()
        table.clear(circles)
        if C.autoKnock or trickTapping() then scanCircles() end
    end
end

local MANOR = {
    EggId = "Manor Egg",
    EggModule = "6 | Manor Egg",
    TeleportTo = Vector3.new(7538.07666015625, 16.2394962310791, 21966.4765625),
    MaxDistance = 35,
    CloseDistance = 10,
    TeleportEvery = 2,
    Delay = 0.15,
    DisableAnimations = true,
    HideEggModel = true,
}

local manorLabel
local manorRemote, manorDir, manorCmds
local manorHatched = 0
C._manorHidden = C._manorHidden or {}
if type(C._witchHidden) == "table" then
    for model, saved in pairs(C._witchHidden) do C._manorHidden[model] = saved end
    C._witchHidden = nil
end
if C._eggAnimOrig == nil and C._witchOrigAnim ~= nil then
    C._eggAnimOrig = C._witchOrigAnim
    C._witchOrigAnim = nil
end

local function withIdentity(level, fn, ...)
    setIdentity(level)
    local results = table.pack(pcall(fn, ...))
    restoreIdentity()
    return table.unpack(results, 1, results.n)
end

local function fmtNum(n)
    n = tonumber(n)
    if not n then return "?" end
    local abs = math.abs(n)
    if abs >= 1e12 then return ("%.2fT"):format(n / 1e12) end
    if abs >= 1e9 then return ("%.2fB"):format(n / 1e9) end
    if abs >= 1e6 then return ("%.2fM"):format(n / 1e6) end
    if abs >= 1e3 then return ("%.1fK"):format(n / 1e3) end
    return tostring(math.floor(n))
end

local function manorSetStatus(text)
    if manorLabel then pcall(function() manorLabel.Text = text end) end
end

local function manorSetAnimations(disable)
    task.spawn(function()
        local ok, err = pcall(function()
            if type(getsenv) ~= "function" then error("getsenv not supported by this executor") end
            local scriptObj = lp:WaitForChild("PlayerScripts", 10)
                :WaitForChild("Scripts", 10)
                :WaitForChild("Game", 10)
                :WaitForChild("Egg Opening Frontend", 10)
            local senv = getsenv(scriptObj)
            if type(senv.PlayEggAnimation) ~= "function" then
                error("PlayEggAnimation not found in script environment")
            end
            if disable then
                if C._eggAnimOrig == nil then C._eggAnimOrig = senv.PlayEggAnimation end
                senv.PlayEggAnimation = function() return end
            elseif C._eggAnimOrig ~= nil then
                senv.PlayEggAnimation = C._eggAnimOrig
                C._eggAnimOrig = nil
            end
        end)
        if ok then
            log("Manor: egg + pet hatch animations " .. (disable and "disabled" or "restored"))
        else
            log("Manor: could not change animations:", err)
        end
    end)
end

local function manorEggCmds()
    if manorCmds then return manorCmds end
    local ok, mod = withIdentity(2, function()
        local m = clientModule("CustomEggsCmds", 10)
        return m and require(m)
    end)
    if ok and type(mod) == "table" and type(mod.All) == "function" then manorCmds = mod end
    return manorCmds
end

local function manorEggDir(egg)
    if egg and type(egg._dir) == "table" then return egg._dir end
    if manorDir then return manorDir end
    local ok, dir = withIdentity(2, function() return require(RS.Library.Directory).Eggs[MANOR.EggId] end)
    if ok and type(dir) == "table" then manorDir = dir end
    return manorDir
end

local function manorFindEgg()
    local cmds = manorEggCmds()
    if not cmds then return nil, "module" end
    local okAll, all = pcall(cmds.All)
    if not (okAll and type(all) == "table") then return nil, "module" end

    local char = lp.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local here = root and root.Position or MANOR.TeleportTo
    local best, bestDist, locked, hidden = nil, nil, 0, 0
    for _, egg in pairs(all) do
        if type(egg) == "table" and egg._id == MANOR.EggId and not egg._destroyed then
            if egg._renderable == false then
                hidden += 1
            elseif egg._hatchable == false then
                locked += 1
            else
                local pos = typeof(egg._position) == "Vector3" and egg._position or nil
                if not pos and typeof(egg._model) == "Instance" and egg._model.Parent then
                    pos = egg._model:GetPivot().Position
                end
                local dist = pos and (pos - here).Magnitude or math.huge
                if not best or dist < bestDist then best, bestDist = egg, dist end
            end
        end
    end
    if best then return best, bestDist end
    return nil, (locked > 0 and "locked") or (hidden > 0 and "hidden") or "missing"
end

local function manorPrice(egg)
    local dir = manorEggDir(egg)
    if dir then
        local ignoreCharged = not (egg and egg._allowChargedAndGolden == true)
        local ok, price = withIdentity(2, function()
            return require(RS.Library.Balancing.CalcEggPricePlayer)(dir, nil, ignoreCharged)
        end)
        if ok and type(price) == "number" and price > 0 then return price end
        ok, price = withIdentity(2, function() return require(RS.Library.Balancing.CalcEggPrice)(dir) end)
        if ok and type(price) == "number" and price > 0 then return price end
        if type(dir.overrideCost) == "number" and dir.overrideCost > 0 then return dir.overrideCost end
    end
    return 4802000
end

local function manorCoins(egg)
    local dir = manorEggDir(egg)
    local currency = dir and dir.currency or "HatchWarCoins"
    local ok, n = withIdentity(2, function() return require(RS.Library.Client.CurrencyCmds).Get(currency) end)
    if ok and type(n) == "number" then return n end
    return nil
end

local function manorMaxHatch(egg)
    if egg and type(egg._maxEggCount) == "number" and egg._maxEggCount > 0 then
        return math.floor(egg._maxEggCount)
    end
    local dir = manorEggDir(egg)
    local ok, n = withIdentity(2, function() return require(RS.Library.Client.EggCmds).GetMaxHatch(dir) end)
    if ok and type(n) == "number" and n > 0 then return math.floor(n) end
    return nil
end

local function manorAmount(egg)
    local max = manorMaxHatch(egg)
    local price = manorPrice(egg)
    local coins = manorCoins(egg)
    local amount = max or 1
    if coins then amount = math.min(amount, math.floor(coins / price)) end
    if C.manorAmount > 0 then amount = math.min(amount, C.manorAmount) end
    return math.max(0, math.floor(amount)), max, price, coins
end

local function manorHideEgg(model)
    if typeof(model) ~= "Instance" or C._manorHidden[model] then return end
    local saved = { items = {} }
    C._manorHidden[model] = saved
    local function hide(d)
        local prop, off
        if d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture") then
            prop, off = "Transparency", 1
        elseif d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") or d:IsA("Light")
            or d:IsA("BillboardGui") or d:IsA("SurfaceGui") then
            prop, off = "Enabled", false
        end
        if prop then
            local okG, cur = pcall(function() return d[prop] end)
            if okG then
                saved.items[#saved.items + 1] = { d, prop, cur }
                pcall(function() d[prop] = off end)
            end
        end
    end
    for _, d in ipairs(model:GetDescendants()) do hide(d) end
    saved.conn = model.DescendantAdded:Connect(function(d)
        if C._manorHidden[model] == saved then task.defer(hide, d) end
    end)
end

local function manorRestoreEggs()
    for model, saved in pairs(C._manorHidden) do
        if saved.conn then pcall(function() saved.conn:Disconnect() end) end
        for _, s in ipairs(saved.items or saved) do
            pcall(function() s[1][s[2]] = s[3] end)
        end
        C._manorHidden[model] = nil
    end
end

local function manorGetRemote()
    if manorRemote and manorRemote.Parent then return manorRemote end
    local net = RS:FindFirstChild("Network")
    manorRemote = net and net:FindFirstChild("CustomEggs_Hatch") or nil
    return manorRemote
end

local function manorHatch(egg, amount)
    local remote = manorGetRemote()
    if not remote then return false, "hatch remote not found" end
    local ok, a, b = pcall(function()
        if remote:IsA("RemoteFunction") then return remote:InvokeServer(egg._uid, amount) end
        remote:FireServer(egg._uid, amount)
        return true
    end)
    if not ok then return false, tostring(a) end
    if not a then return false, type(b) == "string" and b or "refused" end
    return true
end

local function manorTeleport()
    local char = lp.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not (root and hum and hum.Health > 0) then return false end
    local rotation = root.CFrame - root.CFrame.Position
    root.CFrame = CFrame.new(MANOR.TeleportTo) * rotation
    pcall(function()
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)
    return true
end

local function manorTeleportClose(eggPos)
    local char = lp.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return false end
    local flat = Vector3.new(MANOR.TeleportTo.X - eggPos.X, 0, MANOR.TeleportTo.Z - eggPos.Z)
    local dir = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(0, 0, 1)
    local target = Vector3.new(eggPos.X, MANOR.TeleportTo.Y, eggPos.Z) + dir * MANOR.CloseDistance
    local rotation = root.CFrame - root.CFrame.Position
    root.CFrame = CFrame.new(target) * rotation
    pcall(function()
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)
    return true
end

local function manorDebounce()
    local ok, d = withIdentity(2, function() return require(RS.Library.Client.EggCmds).ComputeDebounce() end)
    if ok and type(d) == "number" and d > 0 and d < 10 then return d + 0.05 end
    return 1.7
end

local startManor, stopManor

startManor = function()
    C._manorRun = (C._manorRun or 0) + 1
    local myRun = C._manorRun
    manorHatched = 0
    if MANOR.DisableAnimations then manorSetAnimations(true) end
    manorSetStatus("Manor: starting...")

    task.spawn(function()
        local lastErr, lastTeleport, needTeleport, warnedMax = nil, -math.huge, true, false
        local debounce = manorDebounce()
        while alive() and C.manorHatch and C._manorRun == myRun do
            local waitFor = MANOR.Delay
            local ok, err = pcall(function()
                if not getZoneRoot() then
                    manorSetStatus("Manor: waiting for HatchWar...")
                    waitFor = 1
                    return
                end

                if doorsPriority() then
                    manorSetStatus(("Manor: paused - opening doors | hatched %d"):format(manorHatched))
                    needTeleport = true
                    waitFor = 0.5
                    return
                end

                if needTeleport and doorsHolding() then
                    manorSetStatus(("Manor: paused - opening doors | hatched %d"):format(manorHatched))
                    waitFor = 0.25
                    return
                end

                if needTeleport then
                    manorSetStatus("Manor: teleporting to the egg...")
                    if manorTeleport() then
                        needTeleport = false
                        lastTeleport = os.clock()
                    end
                    waitFor = 0.5
                    return
                end

                local egg, info = manorFindEgg()
                if not egg then
                    if info == "module" then
                        manorSetStatus("Manor: waiting for the egg module...")
                    elseif info == "locked" then
                        manorSetStatus("Manor: egg not hatchable yet (zone 6 locked?)")
                    elseif info == "hidden" then
                        manorSetStatus("Manor: egg not loaded yet - waiting...")
                    else
                        manorSetStatus("Manor: egg not found - waiting...")
                    end
                    waitFor = 1
                    return
                end

                local char = lp.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                if not root then
                    waitFor = 0.5
                    return
                end
                local eggPos = typeof(egg._position) == "Vector3" and egg._position or MANOR.TeleportTo
                if (eggPos - root.Position).Magnitude > MANOR.MaxDistance then
                    if os.clock() - lastTeleport >= MANOR.TeleportEvery and not doorsHolding() then
                        lastTeleport = os.clock()
                        manorSetStatus("Manor: teleporting to the egg...")
                        manorTeleport()
                    end
                    waitFor = 0.25
                    return
                end

                if MANOR.HideEggModel then manorHideEgg(egg._model) end

                local amount, max, price, coins = manorAmount(egg)
                if max == nil and not warnedMax then
                    warnedMax = true
                    log("Manor: max hatch amount unknown (GetMaxHatch failed) - hatching x1 until it loads")
                end
                if amount < 1 then
                    manorSetStatus(("Manor: not enough coins (%s, need %s per egg)"):format(fmtNum(coins or 0), fmtNum(price)))
                    waitFor = 1
                    return
                end

                local okH, why = manorHatch(egg, amount)
                if C._manorRun ~= myRun then return end
                if okH then
                    lastErr = nil
                    manorHatched += amount
                    manorSetStatus(("Manor: x%d | hatched %d | max %s | %s coins"):format(amount, manorHatched, tostring(max or "?"), fmtNum(coins)))
                    waitFor = math.max(MANOR.Delay, debounce)
                else
                    local msg = tostring(why):lower()
                    if msg:find("too quickly", 1, true) or msg:find("too fast", 1, true) then
                        manorSetStatus(("Manor: hatch cooldown... | hatched %d"):format(manorHatched))
                        waitFor = 0.3
                        return
                    end
                    manorSetStatus("Manor: hatch failed - " .. tostring(why))
                    if why ~= lastErr then
                        lastErr = why
                        log("Manor: hatch failed -", why)
                    end
                    if msg:find("close", 1, true) or msg:find("near", 1, true)
                        or msg:find("far", 1, true) or msg:find("distance", 1, true) then
                        manorSetStatus("Manor: moving closer to the egg...")
                        manorTeleportClose(eggPos)
                    end
                    waitFor = 1
                end
            end)
            if not ok then
                log("Manor error:", err)
                waitFor = 1
            end
            task.wait(waitFor)
        end
    end)
end

stopManor = function()
    C._manorRun = (C._manorRun or 0) + 1
    manorRestoreEggs()
    manorSetAnimations(false)
    manorSetStatus("Manor: idle")
end

local DOORS = {
    ZoneName = "6 | Count's Manor",
    Houses = 8,
    Tick = 1,
    RetryAfter = 5,
    BuyRetryAfter = 10,
    StandBack = 4,
    SettleTime = 0.4,
    ArriveRadius = 3,
    WalkTimeout = 45,
}

local doorsLabel
local doorsUtilMod, doorsInstancing
local doorsStats = { active = false, knocks = 0, prizes = 0, last = "", buy = "" }

local function doorsSetStatus(text)
    if doorsLabel then pcall(function() doorsLabel.Text = text end) end
end

local function doorsInstance()
    if not doorsInstancing then
        local okM, mod = withIdentity(2, function()
            local m = clientModule("InstancingCmds", 10)
            return m and require(m)
        end)
        if okM and type(mod) == "table" and type(mod.Get) == "function" then doorsInstancing = mod end
    end
    if not doorsInstancing then return nil end
    local ok, inst = withIdentity(2, doorsInstancing.Get)
    if ok and type(inst) == "table" then return inst end
    return nil
end

local function doorsSaved(key)
    local inst = doorsInstance()
    if not (inst and type(inst.GetSavedValue) == "function") then return nil end
    local ok, value = withIdentity(2, function() return inst:GetSavedValue(key) end)
    if ok then return value end
    return nil
end

local function doorsUtil()
    if doorsUtilMod then return doorsUtilMod end
    local ok, mod = withIdentity(2, function() return require(RS.Library.Util.HatchWarDoors) end)
    if ok and type(mod) == "table" then doorsUtilMod = mod end
    return doorsUtilMod
end

local function doorsHousesFolder()
    local root = getZoneRoot()
    local zone = root and root:FindFirstChild(DOORS.ZoneName)
    return zone and zone:FindFirstChild("Houses")
end

local function doorsUnlockedCount()
    local houses = doorsSaved("Houses")
    if type(houses) == "number" and houses == houses then
        local util = doorsUtil()
        if util and type(util.Unlocked) == "function" then
            local ok, n = pcall(util.Unlocked, houses)
            if ok and type(n) == "number" then return n end
        end
        return math.clamp(math.floor(houses), 1, DOORS.Houses)
    end
    if doorsInstance() then return 1 end
    local folder = doorsHousesFolder()
    if folder then
        local n, sawLock = 0, false
        for i = 1, DOORS.Houses do
            local house = folder:FindFirstChild("House" .. i)
            if not house then break end
            if house:GetAttribute("HW_HouseLocked") == true then
                sawLock = true
                break
            end
            n = i
        end
        if sawLock and n > 0 then return n end
    end
    return 1
end

local function doorsCooldownEnd(doorsTable, houseNumber)
    local util = doorsUtil()
    if util and type(util.CooldownEnd) == "function" then
        local ok, t = pcall(util.CooldownEnd, doorsTable, houseNumber)
        if ok and type(t) == "number" then return t end
    end
    if type(doorsTable) == "table" then
        local t = tonumber(doorsTable[tostring(houseNumber)]) or tonumber(doorsTable[houseNumber])
        if t then return t end
    end
    return 0
end

local function doorsUnlockCost(houseNumber)
    local util = doorsUtil()
    if util and type(util.UnlockCost) == "function" then
        local ok, cost = pcall(util.UnlockCost, houseNumber)
        if ok and type(cost) == "number" then return cost end
    end
    return nil
end

local function doorsLollipops()
    local ok, count = withIdentity(2, function()
        local save = require(RS.Library.Client.Save).Get()
        local misc = save and save.Inventory and save.Inventory.Misc
        if type(misc) ~= "table" then return nil end
        local total = 0
        for _, item in pairs(misc) do
            if type(item) == "table" and item.id == "Hatch War Lollipop" then
                total += tonumber(item._am) or 1
            end
        end
        return total
    end)
    if ok and type(count) == "number" then return count end
    return nil
end

local function doorsFighting()
    local char = lp.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if hrp and hrp:FindFirstChild("HW_BossHoldPosition") then return true end -- still locked in the fight arena
    local ok, fighting = withIdentity(2, function()
        local m = clientModule("HatchWarCmds", 10)
        local boss = m and require(m).Feature("Boss")
        return boss and boss.IsFighting() == true
    end)
    return ok and fighting == true
end

local function doorsRemote()
    local net = RS:FindFirstChild("Network")
    return net and net:FindFirstChild("Instancing_InvokeCustomFromClient")
end

local function doorsInvoke(action, houseNumber)
    local remote = doorsRemote()
    if not remote then return false, "remote not found" end
    local ok, a, b = pcall(function()
        return remote:InvokeServer("HatchWar", "HW_Doors_" .. action, houseNumber)
    end)
    if not ok then return false, tostring(a) end
    if a == true then return true, b end
    if type(a) == "table" then return true, a end
    if type(b) == "string" then return false, b end
    if type(a) == "string" then return false, a end
    return false, "refused"
end

local function doorsPart(houseNumber)
    local root = getZoneRoot()
    local interact = root and root:FindFirstChild("INTERACT")
    local folder = interact and interact:FindFirstChild("Doors")
    local part = folder and folder:FindFirstChild(tostring(houseNumber))
    if part and part:IsA("BasePart") then return part end
    return nil
end

local function doorsSpot(houseNumber)
    local part = doorsPart(houseNumber)
    if not part then return nil end
    local front = (part.CFrame * CFrame.new(0, 0, -DOORS.StandBack)).Position
    local back = (part.CFrame * CFrame.new(0, 0, DOORS.StandBack)).Position
    local folder = doorsHousesFolder()
    local house = folder and folder:FindFirstChild("House" .. houseNumber)
    if house and house:IsA("PVInstance") then
        local hp = house:GetPivot().Position
        local df = Vector3.new(front.X - hp.X, 0, front.Z - hp.Z).Magnitude
        local db = Vector3.new(back.X - hp.X, 0, back.Z - hp.Z).Magnitude
        if db > df then front = back end
    end
    return Vector3.new(front.X, part.Position.Y, front.Z)
end

local function doorsTeleport(houseNumber)
    local spot = doorsSpot(houseNumber)
    local char = lp.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not (spot and root and hum and hum.Health > 0) then return false end
    doorsHoldUntil = os.clock() + DOORS.SettleTime + 1
    local rotation = root.CFrame - root.CFrame.Position
    root.CFrame = CFrame.new(spot) * rotation
    pcall(function()
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)
    return true
end

local function doorsWalkTo(spot, keepGoing)
    local char = lp.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not (spot and hum and root and hum.Health > 0) then return false, "character not ready" end

    local function flatTo(p)
        local r = root.Position
        return Vector3.new(p.X - r.X, 0, p.Z - r.Z).Magnitude
    end
    if flatTo(spot) <= DOORS.ArriveRadius then
        doorsHoldUntil = os.clock() + DOORS.SettleTime + 1
        return true
    end

    doorsHoldUntil = os.clock() + 1.5
    doorsPriorityUntil = math.max(doorsPriorityUntil, os.clock() + DOORS.Tick + 2.5)
    if hoverboardOn() then
        local okHook, hooked = pcall(installHoverboardSteering)
        if not (okHook and hooked) then
            -- the board ignores MoveTo without the steering hook, so get off it and walk
            fireNetwork("Hoverboard_RequestUnequip")
            local t = os.clock()
            while hoverboardOn() and os.clock() - t < 3 do
                doorsHoldUntil = os.clock() + 1.5
                task.wait(0.1)
            end
        end
    end

    local waypoints
    local okP, path = pcall(function()
        local p = game:GetService("PathfindingService"):CreatePath({
            AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 8,
        })
        p:ComputeAsync(root.Position, spot)
        return p
    end)
    if okP and path and path.Status == Enum.PathStatus.Success then
        local okW, wps = pcall(function() return path:GetWaypoints() end)
        if okW and type(wps) == "table" and #wps > 0 then waypoints = wps end
    end
    if not waypoints then
        waypoints = { { Position = spot, Action = Enum.PathWaypointAction.Walk } }
    end

    local deadline = os.clock() + DOORS.WalkTimeout
    local stuck, okWalk, why = 0, true, nil
    for index = (#waypoints > 1 and 2 or 1), #waypoints do
        local wp = waypoints[index]
        local target = wp.Position
        local reach = index == #waypoints and DOORS.ArriveRadius or 4
        local best, progressAt = math.huge, os.clock()
        if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
        while true do
            if not keepGoing() then okWalk, why = false, "stopped"; break end
            if not (hum.Parent and root.Parent and hum.Health > 0) then okWalk, why = false, "character died"; break end
            if os.clock() > deadline then okWalk, why = false, "walk timed out"; break end
            if doorsFighting() then okWalk, why = false, "a fight started"; break end
            doorsHoldUntil = os.clock() + 1.5
            doorsPriorityUntil = math.max(doorsPriorityUntil, os.clock() + DOORS.Tick + 2.5)
            doorsWalkTarget = target
            hum:MoveTo(target)
            task.wait(0.1)
            local d = flatTo(target)
            if d <= reach then break end
            if d < best - 0.5 then
                best, progressAt = d, os.clock()
                stuck = 0
            elseif os.clock() - progressAt > 1.5 then
                hum.Jump = true
                progressAt = os.clock()
                stuck += 1
                if stuck >= 4 then okWalk, why = false, "stuck on the way"; break end
            end
        end
        if not okWalk then break end
    end

    doorsWalkTarget = nil
    pcall(function() hum:MoveTo(root.Position) end)
    if okWalk and flatTo(spot) > DOORS.ArriveRadius + 2 then okWalk, why = false, "did not reach the door" end
    if okWalk then doorsHoldUntil = os.clock() + DOORS.SettleTime + 1 end
    return okWalk, why
end

local function doorsGoTo(houseNumber, keepGoing)
    if C.doorsMethod == "Walk" then
        local spot = doorsSpot(houseNumber)
        if not spot then return false, "door not found" end
        return doorsWalkTo(spot, keepGoing)
    end
    if doorsTeleport(houseNumber) then return true end
    return false, "door or character not ready"
end

local hubReady = false

task.spawn(function()
    local nextTry, knockFails, buyRetryAt, buyFails = {}, {}, 0, 0
    local knockGlobalFails, knockGlobalRetryAt = 0, 0
    local lastBuyErr, lastKnockErr = nil, nil
    local lastBought, lastBoughtAt = 0, 0
    local function keepKnocking() return alive() and C.running and C.autoKnock end
    local function keepBuying() return alive() and C.running and C.autoBuyHouses end
    local function backoff(base, fails, cap) return math.min(base * 2 ^ math.max(fails - 1, 0), cap) end
    while alive() and not hubReady do task.wait(0.1) end
    while alive() do
        if not (C.running and (C.autoKnock or C.autoBuyHouses)) then
            if trickTapping() and doorsFighting() then
                doorsPriorityUntil = os.clock() + DOORS.Tick + 2.5 -- never pull the player out of a running Trick fight
            else
                doorsPriorityUntil = 0
                trickActiveUntil, trickSeenFight = 0, false
            end
            if doorsStats.active then
                doorsStats.active = false
                doorsSetStatus("Doors: idle")
            end
            task.wait(0.5)
        else
            doorsStats.active = true
            local ok, err = pcall(function()
                if not getZoneRoot() then
                    doorsPriorityUntil = 0
                    doorsSetStatus("Doors: waiting for HatchWar...")
                    return
                end

                local unlocked = doorsUnlockedCount()
                local clock = os.clock()
                local fighting = doorsFighting()
                local verb = C.doorsMethod == "Walk" and "walking" or "teleporting"

                if trickTapping() then
                    if fighting then
                        trickSeenFight = true
                    elseif trickSeenFight or clock > trickWaitUntil then
                        trickActiveUntil, trickSeenFight = 0, false
                    end
                end

                local buyTarget = nil
                if C.autoBuyHouses then
                    local waitingForSave = lastBought > unlocked and clock - lastBoughtAt < 15
                    if unlocked >= DOORS.Houses then
                        doorsStats.buy = "all houses owned"
                    elseif waitingForSave then
                        doorsStats.buy = ("waiting for house %d to register..."):format(lastBought)
                    elseif clock >= buyRetryAt then
                        local target = unlocked + 1
                        local cost = doorsUnlockCost(target)
                        local lollipops = doorsLollipops()
                        if cost and cost >= math.huge then
                            buyRetryAt = clock + DOORS.BuyRetryAfter
                            doorsStats.buy = ("house %d: not available yet"):format(target)
                        elseif cost and lollipops == nil then
                            buyRetryAt = clock + DOORS.BuyRetryAfter
                            doorsStats.buy = ("house %d: lollipop count unavailable"):format(target)
                        elseif cost and lollipops < cost then
                            buyRetryAt = clock + DOORS.BuyRetryAfter
                            doorsStats.buy = ("house %d: need %s lollipops (have %s)"):format(target, fmtNum(cost), fmtNum(lollipops))
                        else
                            buyTarget = target
                        end
                    end
                end

                local knockReady, soonest = {}, nil
                local knocksPaused = C.autoKnock and clock < knockGlobalRetryAt
                if C.autoKnock and not knocksPaused then
                    local doorsTable = doorsSaved("Doors")
                    local now = workspace:GetServerTimeNow()
                    for i = 1, unlocked do
                        local remaining = doorsCooldownEnd(doorsTable, i) - now
                        if remaining <= 0 then
                            if (nextTry[i] or 0) <= clock then knockReady[#knockReady + 1] = i end
                        elseif not soonest or remaining < soonest then
                            soonest = remaining
                        end
                    end
                end

                local pending = buyTarget ~= nil or #knockReady > 0
                if pending or trickTapping() then
                    doorsPriorityUntil = os.clock() + DOORS.Tick + 2.5
                else
                    doorsPriorityUntil = 0
                end

                local trickStarting = trickTapping() and not trickSeenFight and clock <= trickWaitUntil
                local knockNote = ""
                if knocksPaused then
                    knockNote = (" | knocks paused %ds (refused)"):format(math.ceil(knockGlobalRetryAt - clock))
                end
                if fighting or trickStarting then
                    if pending or trickTapping() then knockNote = " | waiting for the fight to end" end
                elseif buyTarget then
                    doorsSetStatus(("Doors: %s to locked house %d..."):format(verb, buyTarget))
                    local moved, why = doorsGoTo(buyTarget, keepBuying)
                    if not moved then
                        buyFails += 1
                        buyRetryAt = os.clock() + backoff(DOORS.RetryAfter, buyFails, 120)
                        doorsStats.buy = ("house %d: %s"):format(buyTarget, tostring(why or "could not reach the door"))
                    else
                        task.wait(DOORS.SettleTime)
                        if doorsFighting() then
                            buyRetryAt = os.clock() + 1
                        elseif not keepBuying() then
                            buyRetryAt = os.clock() + 1
                        else
                            local okU, why2 = doorsInvoke("Unlock", buyTarget)
                            if okU then
                                buyFails = 0
                                lastBought, lastBoughtAt = buyTarget, os.clock()
                                buyRetryAt = os.clock() + 2
                                doorsStats.buy = ("bought house %d"):format(buyTarget)
                                lastBuyErr = nil
                                log("Doors: unlocked house", buyTarget)
                            else
                                buyFails += 1
                                buyRetryAt = os.clock() + backoff(DOORS.BuyRetryAfter, buyFails, 300)
                                doorsStats.buy = ("house %d: %s"):format(buyTarget, tostring(why2))
                                if why2 ~= lastBuyErr then
                                    lastBuyErr = why2
                                    log("Doors: could not buy house", buyTarget, "-", why2)
                                end
                            end
                        end
                    end
                elseif #knockReady > 0 then
                    local ready = knockReady[1]
                    local char = lp.Character
                    local root = char and char:FindFirstChild("HumanoidRootPart")
                    if root then
                        local bestD = math.huge
                        for _, i in ipairs(knockReady) do
                            local spot = doorsSpot(i)
                            if spot then
                                local d = (spot - root.Position).Magnitude
                                if d < bestD then ready, bestD = i, d end
                            end
                        end
                    end

                    doorsSetStatus(("Doors: %s to house %d..."):format(verb, ready))
                    local moved, why = doorsGoTo(ready, keepKnocking)
                    if not moved then
                        knockFails[ready] = (knockFails[ready] or 0) + 1
                        nextTry[ready] = os.clock() + backoff(DOORS.RetryAfter, knockFails[ready], 120)
                        doorsStats.last = ("house %d: %s"):format(ready, tostring(why or "could not reach the door"))
                    else
                        task.wait(DOORS.SettleTime)
                        if doorsFighting() then
                            nextTry[ready] = os.clock() + 1
                            knockNote = " | waiting for the fight to end"
                        elseif not keepKnocking() then
                            nextTry[ready] = os.clock() + 1
                        else
                            local okK, result = doorsInvoke("Knock", ready)
                            if okK then
                                knockFails[ready] = 0
                                knockGlobalFails = 0
                                doorsStats.knocks += 1
                                local prizes = type(result) == "table" and type(result.Rolls) == "table" and #result.Rolls or 0
                                doorsStats.prizes += prizes
                                local trick = type(result) == "table" and result.Result == "Trick"
                                local extra = trick and " + TRICK fight!" or ""
                                if trick then
                                    trickActiveUntil = os.clock() + 120
                                    trickWaitUntil = os.clock() + 10
                                    trickSeenFight = false
                                    doorsPriorityUntil = os.clock() + DOORS.Tick + 2.5
                                    if bossScanCircles then pcall(bossScanCircles) end
                                end
                                doorsStats.last = ("house %d: +%d prizes%s"):format(ready, prizes, extra)
                                nextTry[ready] = os.clock() + 3
                                lastKnockErr = nil
                                log("Doors: knocked house", ready, "-", prizes, "prizes" .. extra)
                            else
                                knockFails[ready] = (knockFails[ready] or 0) + 1
                                nextTry[ready] = os.clock() + backoff(DOORS.RetryAfter, knockFails[ready], 120)
                                knockGlobalFails += 1
                                if knockGlobalFails >= 3 then
                                    knockGlobalRetryAt = os.clock() + backoff(15, knockGlobalFails - 2, 300)
                                end
                                doorsStats.last = ("house %d: %s"):format(ready, tostring(result))
                                if result ~= lastKnockErr then
                                    lastKnockErr = result
                                    log("Doors: knock on house", ready, "refused -", result)
                                end
                            end
                        end
                    end
                elseif soonest then
                    knockNote = (" | next knock in %ds"):format(math.ceil(soonest))
                end

                local parts = { ("Doors: %d/%d houses"):format(unlocked, DOORS.Houses) }
                if C.autoKnock then
                    parts[#parts + 1] = ("knocks %d (%d prizes)"):format(doorsStats.knocks, doorsStats.prizes)
                    if doorsStats.last ~= "" then parts[#parts + 1] = doorsStats.last end
                end
                if C.autoBuyHouses and doorsStats.buy ~= "" then parts[#parts + 1] = "buy: " .. doorsStats.buy end
                if pending or trickTapping() then
                    -- keep Boss / Manor paused until the next tick re-checks what is still ready
                    doorsPriorityUntil = math.max(doorsPriorityUntil, os.clock() + DOORS.Tick + 2.5)
                end
                if doorsPriority() and (C.autoBoss or C.manorHatch) then parts[#parts + 1] = "Boss/Manor paused" end
                doorsSetStatus(table.concat(parts, " | ") .. knockNote)
            end)
            if not ok then log("Doors error:", err) end
            task.wait(DOORS.Tick)
        end
    end
end)

local function inst(cls, props, parent)
    local o = Instance.new(cls)
    for k, v in pairs(props or {}) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end
local function corner(r, p) return inst("UICorner", { CornerRadius = UDim.new(0, r or 6) }, p) end
local function stroke(t, c, p) return inst("UIStroke", { Thickness = t or 1, Color = c or Color3.fromRGB(55, 55, 55), ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, p) end

local BG = Color3.fromRGB(0, 0, 0)
local EL = Color3.fromRGB(18, 18, 18)
local TXT = Color3.fromRGB(235, 235, 235)
local MID = Color3.fromRGB(150, 150, 150)
local OFF = Color3.fromRGB(80, 80, 80)
local LINE = Color3.fromRGB(55, 55, 55)
local ACC = Color3.fromRGB(255, 255, 255)

local gp
do local ok, h = pcall(function() return gethui and gethui() end); gp = (ok and h) or lp:WaitForChild("PlayerGui") end
local old = gp:FindFirstChild("VY"); if old then old:Destroy() end
local oldReopen = gp:FindFirstChild("VY_Reopen"); if oldReopen then oldReopen:Destroy() end

local sg = inst("ScreenGui", { Name = "VY", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 100 }, gp)
local main = inst("Frame", { Size = UDim2.new(0, 360, 0, 350), Position = UDim2.new(0.5, -180, 0.5, -175), BackgroundColor3 = BG, BackgroundTransparency = 0.25, BorderSizePixel = 0, Visible = false }, sg)
corner(12, main); stroke(1, LINE, main)
local bar = inst("Frame", { Size = UDim2.new(1, 0, 0, 44), BackgroundColor3 = EL, BackgroundTransparency = 0.4, BorderSizePixel = 0 }, main); corner(12, bar)
inst("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, 0), Font = Enum.Font.GothamBlack, TextSize = 18, TextColor3 = TXT, TextXAlignment = Enum.TextXAlignment.Center, Text = "VY Hub" }, bar)
local xb = inst("TextButton", { Size = UDim2.new(0, 24, 0, 24), Position = UDim2.new(1, -34, 0, 10), BackgroundColor3 = EL, BackgroundTransparency = 0.3, Text = "X", TextColor3 = MID, Font = Enum.Font.GothamBold, TextSize = 14, BorderSizePixel = 0 }, bar); corner(6, xb)

local list = inst("ScrollingFrame", {
    Size = UDim2.new(1, -20, 1, -56), Position = UDim2.new(0, 10, 0, 50),
    BackgroundTransparency = 1, BorderSizePixel = 0,
    ScrollBarThickness = 3, ScrollBarImageColor3 = LINE,
    CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, main)
inst("UIListLayout", { Padding = UDim.new(0, 7), SortOrder = Enum.SortOrder.LayoutOrder }, list)

local sync = {}
local order = 0
local function nextOrder() order += 1; return order end

local function toggle(title, get, set)
    local f = inst("Frame", { LayoutOrder = nextOrder(), Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = EL, BackgroundTransparency = 0.35, BorderSizePixel = 0 }, list); corner(10, f); stroke(1, LINE, f)
    inst("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(0.78, -8, 1, 0), Position = UDim2.new(0, 12, 0, 0), Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = TXT, TextXAlignment = Enum.TextXAlignment.Left, Text = title }, f)
    local sw = inst("Frame", { Size = UDim2.new(0, 44, 0, 22), Position = UDim2.new(1, -56, 0.5, -11), BackgroundColor3 = Color3.fromRGB(30, 30, 30), BackgroundTransparency = 0.2, BorderSizePixel = 0 }, f); corner(11, sw); stroke(1, LINE, sw)
    local ind = inst("Frame", { Size = UDim2.new(0, 16, 0, 16), Position = UDim2.new(0, 3, 0.5, -8), BackgroundColor3 = OFF, BorderSizePixel = 0 }, sw); corner(8, ind)
    local btn = inst("TextButton", { Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "" }, f)
    local function rf()
        local on = get()
        pcall(function()
            ind.Position = on and UDim2.new(0, 25, 0.5, -8) or UDim2.new(0, 3, 0.5, -8)
            ind.BackgroundColor3 = on and ACC or OFF
        end)
    end
    btn.MouseButton1Click:Connect(function() set(not get()); rf() end)
    table.insert(sync, rf); rf()
end
local function numRow(title, get, set)
    local f = inst("Frame", { LayoutOrder = nextOrder(), Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = EL, BackgroundTransparency = 0.35, BorderSizePixel = 0 }, list); corner(10, f); stroke(1, LINE, f)
    inst("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(0.5, -8, 1, 0), Position = UDim2.new(0, 12, 0, 0), Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = TXT, TextXAlignment = Enum.TextXAlignment.Left, Text = title }, f)
    local tb = inst("TextBox", { Size = UDim2.new(0.42, -10, 0, 26), Position = UDim2.new(0.54, 0, 0.5, -13), BackgroundColor3 = Color3.fromRGB(30, 30, 30), BackgroundTransparency = 0.3, Text = tostring(get()), TextColor3 = TXT, Font = Enum.Font.Gotham, TextSize = 13, BorderSizePixel = 0, ClearTextOnFocus = false }, f); corner(8, tb); stroke(1, LINE, tb)
    tb.FocusLost:Connect(function()
        local v = tonumber(tb.Text)
        if v then set(v) end
        tb.Text = tostring(get())
    end)
    table.insert(sync, function() if not tb:IsFocused() then tb.Text = tostring(get()) end end)
end
local function choiceRow(title, options, get, set)
    local f = inst("Frame", { LayoutOrder = nextOrder(), Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = EL, BackgroundTransparency = 0.35, BorderSizePixel = 0 }, list); corner(10, f); stroke(1, LINE, f)
    inst("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(0.5, -8, 1, 0), Position = UDim2.new(0, 12, 0, 0), Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = TXT, TextXAlignment = Enum.TextXAlignment.Left, Text = title }, f)
    local b = inst("TextButton", { Size = UDim2.new(0.42, -10, 0, 26), Position = UDim2.new(0.54, 0, 0.5, -13), BackgroundColor3 = Color3.fromRGB(30, 30, 30), BackgroundTransparency = 0.3, Text = tostring(get()), TextColor3 = TXT, Font = Enum.Font.GothamBold, TextSize = 13, BorderSizePixel = 0, AutoButtonColor = false }, f); corner(8, b); stroke(1, LINE, b)
    local function rf() pcall(function() b.Text = tostring(get()) end) end
    b.MouseButton1Click:Connect(function()
        local idx = table.find(options, get()) or 0
        set(options[idx % #options + 1])
        rf()
    end)
    table.insert(sync, rf)
end

local setWhiteScreen, setFpsCap
do
    local StarterGui = game:GetService("StarterGui")
    local oldWs = gp:FindFirstChild("VY_White"); if oldWs then oldWs:Destroy() end
    pcall(function() RunService:Set3dRenderingEnabled(true) end)
    local wsGui

    local function gameSettings()
        return UserSettings():GetService("UserGameSettings")
    end

    setWhiteScreen = function(on)
        on = on == true
        if on then
            if not wsGui or not wsGui.Parent then
                wsGui = inst("ScreenGui", { Name = "VY_White", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 50, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, gp)
                inst("Frame", { Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Active = false, Selectable = false }, wsGui)
            end
            if not C._wsSaved then
                local saved = {}
                pcall(function() saved.quality = settings().Rendering.QualityLevel end)
                pcall(function() saved.volume = gameSettings().MasterVolume end)
                pcall(function() saved.topbar = StarterGui:GetCore("TopbarEnabled") end)
                if type(getfpscap) == "function" then pcall(function() saved.fps = getfpscap() end) end
                C._wsSaved = saved
            end
            pcall(function() RunService:Set3dRenderingEnabled(false) end)
            pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
            pcall(function() gameSettings().MasterVolume = 0 end)
            pcall(function() StarterGui:SetCore("TopbarEnabled", false) end)
            if type(setfpscap) == "function" then pcall(setfpscap, C.fpsCap) end
        else
            if wsGui then pcall(function() wsGui:Destroy() end); wsGui = nil end
            local stray = gp:FindFirstChild("VY_White"); if stray then pcall(function() stray:Destroy() end) end
            pcall(function() RunService:Set3dRenderingEnabled(true) end)
            local saved = C._wsSaved
            if saved then
                if saved.quality ~= nil then pcall(function() settings().Rendering.QualityLevel = saved.quality end) end
                if saved.volume ~= nil then pcall(function() gameSettings().MasterVolume = saved.volume end) end
                if saved.topbar ~= nil then pcall(function() StarterGui:SetCore("TopbarEnabled", saved.topbar) end) end
                if type(setfpscap) == "function" then pcall(setfpscap, saved.fps or 0) end
                C._wsSaved = nil
            end
        end
        C.whiteScreen = on
    end

    setFpsCap = function(v)
        v = tonumber(v)
        if not v then return end
        C.fpsCap = math.floor(math.clamp(v, 1, 240))
        if C.whiteScreen and type(setfpscap) == "function" then pcall(setfpscap, C.fpsCap) end
    end

    table.insert(C._efConns, UIS.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.KeyCode == Enum.KeyCode.L then setWhiteScreen(not C.whiteScreen) end
    end))

    if C.whiteScreen then setWhiteScreen(true) end
end

toggle("Auto Boss 6 (teleport)", function() return C.autoBoss end, function(v)
    if v and C.manorHatch then
        C.manorHatch = false
        stopManor()
    end
    C.autoBoss = v
    if v then startBoss() else stopBoss() end
end)
numRow("Click Delay (s)", function() return C.bossClickDelay end, function(v)
    C.bossClickDelay = math.clamp(tonumber(v) or C.bossClickDelay, 0, 3)
end)
bossLabel = inst("TextLabel", {
    LayoutOrder = nextOrder(), Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1,
    Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = MID, TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd, Text = "Boss: idle",
}, list)

toggle("Break ALL event zones (no TP)", function() return C.breakAll end, function(v) C.breakAll = v end)
numRow("Delay (s)", function() return C.breakAllDelay end, function(v) C.breakAllDelay = math.max(0.05, tonumber(v) or C.breakAllDelay) end)

toggle("Auto Hatch Manor Egg (TP)", function() return C.manorHatch end, function(v)
    if v and C.autoBoss then
        C.autoBoss = false
        stopBoss()
    end
    C.manorHatch = v
    if v then startManor() else stopManor() end
end)
numRow("Hatch Amount (0=max)", function() return C.manorAmount end, function(v)
    v = math.max(0, math.floor(v))
    local egg = getZoneRoot() and manorFindEgg() or nil
    local max = manorMaxHatch(egg)
    if max and v > max then
        v = max
        manorSetStatus(("Manor: capped to your max hatch (%d)"):format(max))
    end
    C.manorAmount = v
end)
manorLabel = inst("TextLabel", {
    LayoutOrder = nextOrder(), Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1,
    Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = MID, TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd, Text = "Manor: idle",
}, list)

toggle("Auto Knock Doors (unlocked)", function() return C.autoKnock end, function(v)
    C.autoKnock = v
    if v and bossScanCircles then pcall(bossScanCircles) end
end)
toggle("Auto Buy Houses (in order)", function() return C.autoBuyHouses end, function(v) C.autoBuyHouses = v end)
choiceRow("Door Move Method", { "Teleport", "Walk" }, function() return C.doorsMethod end, function(v)
    C.doorsMethod = v == "Walk" and "Walk" or "Teleport"
end)
doorsLabel = inst("TextLabel", {
    LayoutOrder = nextOrder(), Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1,
    Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = MID, TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd, Text = "Doors: idle",
}, list)

toggle("Auto Efficient Farm", function() return C.efficientFarm end, function(v)
    if v then
        if not installEfficientFarm() then
            log("Auto Efficient Farm unavailable (couldn't load Network/MapCmds)")
            v = false
        elseif not installPetSpeed() then
            log("Auto Efficient Farm: pet speed hook unavailable, farming without the speed boost")
        end
    end
    C.efficientFarm = v
end)
toggle("Infinite Pet Speed", function() return C.petSpeed end, function(v)
    if v and not installPetSpeed() then
        log("Infinite Pet Speed unavailable (hookfunction or PlayerPet missing)")
        v = false
    end
    C.petSpeed = v
end)
toggle("Super Magnet", function() return C.superMagnet end, function(v)
    if v and not installMagnet() then
        log("Super Magnet unavailable (couldn't patch the client modules)")
        v = false
    end
    C.superMagnet = v
end)

toggle("Anti AFK", function() return C.antiAfk end, function(v) C.antiAfk = v end)
toggle("White Screen (CPU saver)", function() return C.whiteScreen end, function(v) setWhiteScreen(v) end)
numRow("FPS Cap (1-240)", function() return C.fpsCap end, setFpsCap)

do
    local HttpService = game:GetService("HttpService")
    local CFG_FILE = "VYHub_Config.json"

    local function readConfig()
        if type(isfile) ~= "function" or type(readfile) ~= "function" then return nil end
        local okE, exists = pcall(isfile, CFG_FILE)
        if not okE or not exists then return nil end
        local ok, data = pcall(function() return HttpService:JSONDecode(readfile(CFG_FILE)) end)
        if ok and type(data) == "table" then return data end
        return nil
    end

    local function saveConfig()
        if type(writefile) ~= "function" then return false end
        return (pcall(function()
            writefile(CFG_FILE, HttpService:JSONEncode({
                autoBoss = C.autoBoss == true,
                breakAll = C.breakAll == true,
                breakAllDelay = C.breakAllDelay,
                efficientFarm = C.efficientFarm == true,
                petSpeed = C.petSpeed == true,
                superMagnet = C.superMagnet == true,
                antiAfk = C.antiAfk ~= false,
                manorHatch = C.manorHatch == true,
                manorAmount = C.manorAmount,
                autoKnock = C.autoKnock == true,
                autoBuyHouses = C.autoBuyHouses == true,
                doorsMethod = C.doorsMethod,
                bossClickDelay = C.bossClickDelay,
                whiteScreen = C.whiteScreen == true,
                fpsCap = C.fpsCap,
            }))
        end))
    end

    local saveRow = inst("Frame", { LayoutOrder = nextOrder(), Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = EL, BackgroundTransparency = 0.35, BorderSizePixel = 0 }, list); corner(10, saveRow); stroke(1, LINE, saveRow)
    local saveBtn = inst("TextButton", { Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = TXT, Text = "Save Config" }, saveRow)
    saveBtn.MouseButton1Click:Connect(function()
        saveBtn.Text = saveConfig() and "Config Saved" or "Save Failed"
        task.delay(1.5, function() pcall(function() saveBtn.Text = "Save Config" end) end)
    end)

    local cfg = readConfig()
    local resumeManor = cfg ~= nil and cfg.manorHatch == true and cfg.autoBoss ~= true
    if not resumeManor then
        manorRestoreEggs()
        if C._eggAnimOrig ~= nil then manorSetAnimations(false) end
    end
    if cfg then
        if type(cfg.breakAll) == "boolean" then C.breakAll = cfg.breakAll end
        if tonumber(cfg.breakAllDelay) then C.breakAllDelay = math.max(0.05, tonumber(cfg.breakAllDelay)) end
        if type(cfg.efficientFarm) == "boolean" then C.efficientFarm = cfg.efficientFarm end
        if type(cfg.petSpeed) == "boolean" then C.petSpeed = cfg.petSpeed end
        if type(cfg.superMagnet) == "boolean" then C.superMagnet = cfg.superMagnet end
        if type(cfg.antiAfk) == "boolean" then C.antiAfk = cfg.antiAfk end
        if tonumber(cfg.fpsCap) then setFpsCap(cfg.fpsCap) end
        if type(cfg.whiteScreen) == "boolean" and cfg.whiteScreen ~= C.whiteScreen then setWhiteScreen(cfg.whiteScreen) end
        local manorAmt = tonumber(cfg.manorAmount)
        if manorAmt and manorAmt >= 0 then C.manorAmount = math.floor(manorAmt) end
        if tonumber(cfg.bossClickDelay) then C.bossClickDelay = math.clamp(tonumber(cfg.bossClickDelay), 0, 3) end
        if type(cfg.autoKnock) == "boolean" then C.autoKnock = cfg.autoKnock end
        if type(cfg.autoBuyHouses) == "boolean" then C.autoBuyHouses = cfg.autoBuyHouses end
        if cfg.doorsMethod == "Walk" or cfg.doorsMethod == "Teleport" then C.doorsMethod = cfg.doorsMethod end
        if cfg.autoBoss == true then
            C.autoBoss = true
            startBoss()
        elseif cfg.manorHatch == true then
            C.manorHatch = true
            startManor()
        end
        for _, rf in ipairs(sync) do pcall(rf) end
    end
end

hubReady = true

if C.petSpeed and not installPetSpeed() then C.petSpeed = false end
if C.efficientFarm then
    task.spawn(function()
        if not installEfficientFarm() then C.efficientFarm = false; return end
        installPetSpeed()
    end)
end
if C.superMagnet and not installMagnet() then C.superMagnet = false end

local reopen = inst("ScreenGui", { Name = "VY_Reopen", ResetOnSpawn = false, DisplayOrder = 99 }, gp)
local rb = inst("TextButton", { Size = UDim2.new(0, 58, 0, 40), Position = UDim2.new(0, 20, 0.5, -20), BackgroundColor3 = BG, BackgroundTransparency = 0.25, Text = "VY", TextColor3 = TXT, Font = Enum.Font.GothamBlack, TextSize = 16, BorderSizePixel = 0, Visible = true }, reopen); corner(10, rb); stroke(1, LINE, rb)
do
    local rbd, rbs, rbp, rbm = false, nil, nil, false
    rb.InputBegan:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then rbd = true; rbm = false; rbs = i.Position; rbp = rb.Position end end)
    UIS.InputChanged:Connect(function(i) if rbd and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then local d = i.Position - rbs; if d.Magnitude > 4 then rbm = true end; rb.Position = UDim2.new(rbp.X.Scale, rbp.X.Offset + d.X, rbp.Y.Scale, rbp.Y.Offset + d.Y) end end)
    UIS.InputEnded:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then rbd = false end end)
    rb.MouseButton1Click:Connect(function() if rbm then return end; main.Visible = true; rb.Visible = false end)
end
xb.MouseButton1Click:Connect(function() main.Visible = false; rb.Visible = true end)
do
    local drag, ds, sp
    bar.InputBegan:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then drag = true; ds = i.Position; sp = main.Position end end)
    UIS.InputChanged:Connect(function(i) if drag and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then local d = i.Position - ds; main.Position = UDim2.new(sp.X.Scale, sp.X.Offset + d.X, sp.Y.Scale, sp.Y.Offset + d.Y) end end)
    UIS.InputEnded:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then drag = false end end)
end

task.spawn(function()
    while alive() do
        for _, rf in ipairs(sync) do pcall(rf) end
        task.wait(0.5)
    end
end)

task.spawn(function()
    if not C.autoJoin then return end
    task.wait(2)

    local mod = clientModule("InstancingCmds", 30)
    if not mod then log("Auto-join: InstancingCmds not found"); return end
    local ok, I = pcall(require, mod)
    if not ok or type(I) ~= "table" or type(I.Enter) ~= "function" then
        log("Auto-join: InstancingCmds unavailable")
        return
    end

    for attempt = 1, 3 do
        if not alive() then return end
        if getZoneRoot() then log("Already inside HatchWar"); return end

        log("Joining HatchWar (attempt " .. attempt .. ")")
        setIdentity(2)
        local okE, err = pcall(I.Enter, "HatchWar")
        setIdentity(7)
        if not okE then log("Auto-join error:", err) end

        local t = os.clock()
        while alive() and os.clock() - t < 15 do
            if getZoneRoot() then log("Joined HatchWar"); return end
            task.wait(0.5)
        end
    end
    log("Auto-join: couldn't confirm HatchWar entry")
end)

log("VY loaded.")
return true