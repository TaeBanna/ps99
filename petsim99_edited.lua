--// Auto Event + Auto Hatch Custom Egg
--// - รันแล้ว: เข้า event -> วาร์ปไป GoldenGrove_Zone ใน plot เรา -> เปิด auto farm
--//   -> หาไข่ใกล้ๆ จุดฟาร์ม -> เปิดจำนวนสูงสุดวนไปเรื่อยๆ
--// - กันวาร์ปมั่ว: ทุกการวาร์ปต้องผ่าน safeTP() ที่ยอมเฉพาะจุดใกล้โซนฟาร์มของ plot เรา
--// - FPS BOOST / ปิดภาพ 3D ช่วยให้เกมลื่น
--// - config บันทึกที่ AutoEgg/config.json

if not game:IsLoaded() then game.Loaded:Wait() end

------------------------------------------------------------------
-- ค่าที่ไม่ต้องตั้งใน GUI (แก้ตรงนี้ถ้าอยากเปลี่ยน)
------------------------------------------------------------------
local EVENT_ID = "PumpkinTycoon"        -- ชื่อ event ที่จะเข้า
local THREADS = 1                       -- ยิงพร้อมกันกี่เธรด
local HATCH_INTERVAL = 0.4              -- เปิดไข่ทุกกี่วินาที (ค่าตายตัว) ขึ้น "too quickly" บ่อย = เพิ่ม / อยากเร็ว = ลด
local PROBE_START = 100                 -- ใช้ตอนหาค่าสูงสุดไม่เจอ จะไล่ลดจากเลขนี้
local SECTION_NAME = "5 | Golden Grove" -- workspace.__THINGS.Plots[x].Sections[...]
local ZONE_NAME = "GoldenGrove_Zone"    -- Sections[SECTION_NAME].BREAK_ZONES[ZONE_NAME] = จุดฟาร์ม
local EGG_RADIUS = 40                   -- หาไข่ในระยะเท่านี้จากจุดฟาร์ม
local TP_SAFE_RADIUS = 150              -- วาร์ปได้เฉพาะจุดที่ห่างจากโซนฟาร์มของเราไม่เกินนี้
local EDGE_MARGIN = 4                   -- ยืนห่างขอบโซนฟาร์มกี่ studs (ตอนขยับเข้าใกล้ไข่)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local LocalPlayer = Players.LocalPlayer
local Library = ReplicatedStorage:WaitForChild("Library")
local HatchRemote = ReplicatedStorage:WaitForChild("Network"):WaitForChild("CustomEggs_Hatch")

local CONFIG_FOLDER = "AutoEgg"
local CONFIG_FILE = CONFIG_FOLDER .. "/config.json"

------------------------------------------------------------------
-- thread identity (require module ของเกมทำให้ identity ตก -> แตะ GUI ไม่ได้)
------------------------------------------------------------------
local setIdentity = setthreadidentity or set_thread_identity or setidentity
	or (syn and syn.set_thread_identity)
local function fixIdentity()
	if setIdentity then pcall(setIdentity, 8) end
end

local function tryRequire(inst)
	local ok, mod = pcall(require, inst)
	fixIdentity()
	return ok and mod or nil
end

local function requirePath(path)
	local node = Library
	for name in string.gmatch(path, "[^%.]+") do
		node = node and node:WaitForChild(name, 5)
	end
	return node and tryRequire(node) or nil
end

local Variables = requirePath("Variables")
local EggCmds = requirePath("Client.EggCmds")
local Save = requirePath("Client.Save")
local InstancingCmds = requirePath("Client.InstancingCmds")
local AutoFarmCmds = requirePath("Client.AutoFarmCmds")

-- module ที่เกี่ยวกับ custom egg (ชื่อมีคำว่า CustomEgg)
local CustomEggModules = {}
do
	local client = Library:FindFirstChild("Client")
	if client then
		for _, m in ipairs(client:GetChildren()) do
			if m:IsA("ModuleScript") and string.find(string.lower(m.Name), "customegg") then
				local mod = tryRequire(m)
				if type(mod) == "table" then
					table.insert(CustomEggModules, { name = m.Name, mod = mod })
				end
			end
		end
	end
end

-- รอเซฟโหลด
if Save and Save.Get then
	local t = 0
	while t < 30 do
		local ok, data = pcall(Save.Get)
		if ok and data then break end
		t += task.wait(0.5)
	end
end
fixIdentity()

------------------------------------------------------------------
-- config
------------------------------------------------------------------
local hasFS = (writefile and readfile and isfile) ~= nil

local config = {
	eggName = nil,
	skipAnim = true,
	autoJoin = true,
	autoFarm = true,
	fpsBoost = true,
	no3d = false,
	running = false,
	probedMax = nil,
}

local function loadConfig()
	if not hasFS then return end
	local ok, data = pcall(function()
		if isfile(CONFIG_FILE) then
			return HttpService:JSONDecode(readfile(CONFIG_FILE))
		end
	end)
	if ok and type(data) == "table" then
		for k, v in pairs(data) do config[k] = v end
	end
end

local function saveConfig()
	if not hasFS then return end
	pcall(function()
		if makefolder and isfolder and not isfolder(CONFIG_FOLDER) then makefolder(CONFIG_FOLDER) end
		writefile(CONFIG_FILE, HttpService:JSONEncode(config))
	end)
end

loadConfig()

------------------------------------------------------------------
-- state
------------------------------------------------------------------
local state = {
	running = false,
	amount = nil,
	source = "unknown",
	hatched = 0,
	session = 0,
	lastErr = nil,
	egg = nil,          -- { uid, name, position }
	info = nil,
	fails = 0,
	interval = HATCH_INTERVAL, -- เว้นระยะระหว่างการเปิดแต่ละครั้ง (ค่าตายตัว)
	lastOkAt = 0,
	okCount = 0,
	quickCount = 0,
	startedAt = os.clock(),
	busyPrep = false,
	-- base ของเรา
	plot = nil, plotSure = false, plotOverride = nil,
	anchor = nil,       -- กลางโซนฟาร์ม
	stand = nil,        -- จุดยืน (ใกล้ไข่ในโซน)
	eggHint = nil,      -- ตำแหน่งไข่จาก attribute ของ plot
}
local refresh = function() end

------------------------------------------------------------------
-- utils
------------------------------------------------------------------
local function isUid(s)
	return type(s) == "string" and #s == 32 and string.match(s, "^%x+$") ~= nil
end

local function posOf(v)
	if typeof(v) == "Vector3" then return v end
	if typeof(v) == "CFrame" then return v.Position end
	if typeof(v) == "Instance" then
		local ok, p = pcall(function() return v:GetPivot().Position end)
		if ok then return p end
	end
	return nil
end

local function myPos()
	local c = LocalPlayer.Character
	return c and posOf(c) or nil
end

local function anchorPos(inst)
	if not inst then return nil end
	if inst:IsA("Model") then
		local ok, cf = pcall(inst.GetPivot, inst)
		if ok then return cf.Position end
	end
	if inst:IsA("BasePart") then return inst.Position end
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then return d.Position end
	end
	return nil
end

------------------------------------------------------------------
-- หาไข่
------------------------------------------------------------------
local function readEggTable(key, v)
	if type(v) ~= "table" then return nil end
	local uid = (isUid(key) and key) or v._uid or v.uid or v.UID or v.Uid or (isUid(v._id) and v._id) or nil
	if not isUid(uid) then return nil end
	local name
	for _, f in ipairs({ "_id", "id", "eggId", "EggId", "_eggId", "name", "Name", "_name" }) do
		local n = v[f]
		if type(n) == "string" and not isUid(n) then name = n break end
	end
	if not name and type(v._dir) == "table" then
		name = v._dir.name or v._dir.Name or v._dir._id
	end
	local pos
	for _, f in ipairs({ "_position", "position", "Position", "_cframe", "cframe", "CFrame", "_pos", "_model", "model", "Model" }) do
		pos = posOf(v[f])
		if pos then break end
	end
	return { uid = uid, name = name, position = pos }
end

local function scanEggs()
	local found, seen = {}, {}
	local function add(e)
		if not e then return end
		local o = seen[e.uid]
		if not o then
			seen[e.uid] = e
			table.insert(found, e)
		else
			o.name = o.name or e.name
			o.position = o.position or e.position
		end
	end

	for _, entry in ipairs(CustomEggModules) do
		for _, fname in ipairs({ "All", "GetAll", "GetEggs", "GetAllEggs" }) do
			local f = entry.mod[fname]
			if type(f) == "function" then
				local ok, list = pcall(f)
				if ok and type(list) == "table" then
					for k, v in pairs(list) do add(readEggTable(k, v)) end
				end
			end
		end
	end
	fixIdentity()

	local things = workspace:FindFirstChild("__THINGS")
	if things then
		for _, folderName in ipairs({ "CustomEggs", "Eggs" }) do
			local folder = things:FindFirstChild(folderName)
			if folder then
				for _, m in ipairs(folder:GetChildren()) do
					local uid = isUid(m.Name) and m.Name or m:GetAttribute("UID") or m:GetAttribute("Uid") or m:GetAttribute("uid")
					if isUid(uid) then
						local name = m:GetAttribute("EggId") or m:GetAttribute("Id") or m:GetAttribute("Name")
						add({ uid = uid, name = type(name) == "string" and name or nil, position = posOf(m) })
					end
				end
			end
		end
	end
	return found
end

local function nearestTo(eggs, target, maxD)
	local best, bestD = nil, maxD or math.huge
	for _, e in ipairs(eggs) do
		if e.position then
			local d = (e.position - target).Magnitude
			if d < bestD then best, bestD = e, d end
		end
	end
	return best
end

------------------------------------------------------------------
-- หา plot ของเรา
------------------------------------------------------------------
local AREA = (string.gsub(ZONE_NAME, "_Zone$", "")) -- "GoldenGrove"

-- plot เก็บตำแหน่งไว้เป็น attribute (อ่านได้แม้แมพตรงนั้นยังไม่โหลด)
local function attrPos(plot, key)
	local v = plot:GetAttribute(key)
	if typeof(v) == "CFrame" then return v.Position end
	if typeof(v) == "Vector3" then return v end
	return nil
end

local function getPlots()
	local things = workspace:FindFirstChild("__THINGS")
	return things and things:FindFirstChild("Plots")
end

local function sectionOf(p)
	local secs = p and p:FindFirstChild("Sections")
	return secs and secs:FindFirstChild(SECTION_NAME)
end

local function isMine(plot)
	local uid, name = LocalPlayer.UserId, LocalPlayer.Name
	local function match(v)
		return v ~= nil and (v == LocalPlayer or v == uid or v == name or tostring(v) == tostring(uid))
	end
	for _, a in ipairs({ "Owner", "OwnerId", "OwnerUserId", "UserId", "Player", "OwnerName" }) do
		if match(plot:GetAttribute(a)) then return true end
	end
	return false
end

-- จุดวาร์ปเข้า tycoon ของเรา (เกมใช้ฟังก์ชันนี้วาร์ปเราไป base ตัวเองตอนเข้า event)
local function myTeleportPos()
	if not InstancingCmds then return nil end
	local ok, inst = pcall(InstancingCmds.Get)
	fixIdentity()
	if not (ok and type(inst) == "table" and inst.instanceID == EVENT_ID
		and type(inst.module) == "table" and inst.module.GetTeleport) then
		return nil
	end
	local ok2, tp = pcall(inst.module.GetTeleport, inst)
	fixIdentity()
	if not (ok2 and tp) then return nil end
	return posOf(tp)
end

local function findSection()
	local plots = getPlots()
	if not plots then return nil end

	-- 0) ผู้เล่นกด "ตั้งเป็น base ของฉัน"
	local ov = state.plotOverride
	if ov and ov.Parent == plots then return sectionOf(ov), ov, "ตั้งเอง" end

	-- หาเจอแล้วรอบนี้: ใช้ตัวเดิม (plot ไม่เปลี่ยนจนกว่าจะออกจาก event)
	if state.plotSure and state.plot and state.plot.Parent == plots then
		return sectionOf(state.plot), state.plot, "จำไว้"
	end

	-- 1) จุดวาร์ปของเรา เทียบกับ PadSpot_TycoonTeleport / SpawnPosition ของแต่ละ plot
	--    ต้องตรงกัน "plot เดียว" เท่านั้น ถ้ากำกวม (2 plot ใกล้พอกัน) จะไม่เดา
	local tp = myTeleportPos()
	if tp then
		local best, bestD, second = nil, math.huge, math.huge
		for _, p in ipairs(plots:GetChildren()) do
			local d = math.huge
			local a = attrPos(p, "PadSpot_TycoonTeleport")
			if a then d = math.min(d, (a - tp).Magnitude) end
			local sp = p:FindFirstChild("SpawnPosition")
			local spPos = sp and posOf(sp)
			if spPos then d = math.min(d, (spPos - tp).Magnitude) end
			if d < bestD then
				best, second, bestD = p, bestD, d
			elseif d < second then
				second = d
			end
		end
		if best and bestD <= 80 and second > bestD * 3 then
			return sectionOf(best), best, ("จุดวาร์ปของเรา (ห่าง %d)"):format(math.floor(bestD))
		end
		warn("[AutoEgg] GetTeleport ไม่ตรง plot ไหนชัดเจน", tp, bestD, second)
	else
		warn("[AutoEgg] เรียก GetTeleport ไม่ได้ (ยังไม่อยู่ใน event?)")
	end

	-- 2) attribute เจ้าของ (เผื่อเกมเพิ่มในอนาคต)
	for _, p in ipairs(plots:GetChildren()) do
		if isMine(p) then return sectionOf(p), p, "attribute เจ้าของ" end
	end

	return nil -- ไม่เดา
end

-- plot ที่ตัวเรายืนอยู่ (ปุ่ม "ตั้งเป็น base ของฉัน")
local function plotAtMe()
	local plots = getPlots()
	local me = myPos()
	if not (plots and me) then return nil end
	local best, bestD = nil, math.huge
	for _, p in ipairs(plots:GetChildren()) do
		local pos = attrPos(p, "PadSpot_" .. AREA .. "_Zone")
		if not pos then
			local s = sectionOf(p)
			local bz = s and s:FindFirstChild("BREAK_ZONES")
			pos = anchorPos(bz and bz:FindFirstChild(ZONE_NAME)) or anchorPos(s)
		end
		local d = pos and (pos - me).Magnitude or math.huge
		if d < bestD then best, bestD = p, d end
	end
	return best, bestD
end

------------------------------------------------------------------
-- วาร์ป (ปลอดภัย)
------------------------------------------------------------------
-- ทุกการวาร์ปต้องผ่านตรงนี้: ยอมเฉพาะจุดที่ใกล้โซนฟาร์มของ plot เรา
local function safeTP(target, lookAt)
	if not (state.anchor and state.plot and state.plot.Parent) then
		warn("[AutoEgg] ยกเลิกวาร์ป: ยังไม่รู้ base ของเรา")
		return false
	end
	local dist = (target - state.anchor).Magnitude
	if dist > TP_SAFE_RADIUS then
		warn(("[AutoEgg] ยกเลิกวาร์ป: จุดหมายห่างโซนฟาร์มเรา %d studs"):format(math.floor(dist)))
		return false
	end
	local c = LocalPlayer.Character
	if not c then return false end
	local cf = lookAt and CFrame.new(target, Vector3.new(lookAt.X, target.Y, lookAt.Z)) or CFrame.new(target)
	return (pcall(function() c:PivotTo(cf) end))
end

-- ออกจาก event = เข้าใหม่อาจได้ plot ใหม่ -> ล้างค่าที่จำไว้
local function resetPlot()
	state.plot, state.plotSure, state.plotOverride = nil, false, nil
	state.anchor, state.stand, state.eggHint = nil, nil, nil
	state.egg = nil
end
if InstancingCmds and InstancingCmds.AddLeaveListener then
	pcall(InstancingCmds.AddLeaveListener, function(id)
		if id == EVENT_ID then resetPlot() end
	end)
	fixIdentity()
end

local function goToZone()
	local s, p, how = findSection()
	if not p then
		warn("[AutoEgg] หา base ของเราไม่เจอ -> ไปยืนที่ " .. ZONE_NAME .. " ของตัวเอง แล้วกด \"ตั้งเป็น base ของฉัน\"")
		state.lastErr = "หา base ไม่เจอ: ไปยืนที่ base ตัวเองแล้วกด 'ตั้งเป็น base ของฉัน'"
		return nil
	end

	local bz = s and s:FindFirstChild("BREAK_ZONES")
	local zone = bz and bz:FindFirstChild(ZONE_NAME)
	local attrZone = attrPos(p, "PadSpot_" .. AREA .. "_Zone")
	local pos = (zone and anchorPos(zone)) or attrZone or anchorPos(s)
	if not pos then return nil end

	-- กันพลาด: part จริงกับ attribute ของ plot ต้องอยู่ที่เดียวกัน
	if zone and attrZone and (anchorPos(zone) - attrZone).Magnitude > 60 then
		warn("[AutoEgg] ตำแหน่งโซนไม่ตรงกับ plot -> ใช้ค่าจาก attribute")
		pos = attrZone
	end

	state.anchor = pos
	state.stand = pos
	state.plot = p
	state.plotSure = true
	state.eggHint = attrPos(p, "PadSpot_" .. AREA .. "_Egg") or attrPos(p, AREA .. "_Egg")
	print("[AutoEgg] plot:", p.Name, "|", how, "| zone:", pos, "| egg:", state.eggHint)

	pcall(function() LocalPlayer:RequestStreamAroundAsync(pos, 5) end)
	safeTP(pos + Vector3.new(0, 3, 0))
	task.wait(1.5) -- รอแมพ/ไข่โหลด
	fixIdentity()
	return pos
end

-- ขยับเข้าไปใกล้ไข่ แต่ยังอยู่ในโซนฟาร์ม
local function moveNearEgg()
	local eggPos = (state.egg and state.egg.position) or state.eggHint
	if not (eggPos and state.anchor) then return end
	if (eggPos - state.anchor).Magnitude > 120 then
		warn("[AutoEgg] ไข่ที่เลือกไม่ได้อยู่ใน base เรา -> ไม่ขยับ")
		return
	end

	local s = sectionOf(state.plot)
	local bz = s and s:FindFirstChild("BREAK_ZONES")
	local zone = bz and bz:FindFirstChild(ZONE_NAME)

	local cf, size
	if zone and zone:IsA("BasePart") then
		cf, size = zone.CFrame, zone.Size
	elseif zone and zone:IsA("Model") then
		pcall(function() cf, size = zone:GetBoundingBox() end)
	end

	local target
	if cf and size then
		local lp = cf:PointToObjectSpace(eggPos)
		local hx = math.max(size.X / 2 - EDGE_MARGIN, 0)
		local hz = math.max(size.Z / 2 - EDGE_MARGIN, 0)
		local w = cf:PointToWorldSpace(Vector3.new(math.clamp(lp.X, -hx, hx), 0, math.clamp(lp.Z, -hz, hz)))
		target = Vector3.new(w.X, state.anchor.Y, w.Z)
	else
		target = state.anchor:Lerp(Vector3.new(eggPos.X, state.anchor.Y, eggPos.Z), 0.6)
	end

	if safeTP(target + Vector3.new(0, 3, 0), eggPos) then
		state.stand = target
		print(("[AutoEgg] ขยับไปใกล้ไข่: ห่างไข่ %d studs"):format(math.floor((eggPos - target).Magnitude)))
	end
end

------------------------------------------------------------------
-- auto farm
------------------------------------------------------------------
local function farmEnabled()
	if AutoFarmCmds and AutoFarmCmds.IsEnabled then
		local ok, r = pcall(AutoFarmCmds.IsEnabled)
		fixIdentity()
		if ok then return r == true end
	end
	return false
end

local function enableFarm()
	if farmEnabled() then return true end
	if AutoFarmCmds and AutoFarmCmds.Enable then
		pcall(AutoFarmCmds.Enable)
		fixIdentity()
	end
	task.wait(0.5)
	if not farmEnabled() then
		local r = ReplicatedStorage.Network:FindFirstChild("AutoFarm_Enable")
		if r then pcall(function() r:InvokeServer() end) end
	end
	return farmEnabled()
end

local function disableFarm()
	if AutoFarmCmds and AutoFarmCmds.Disable and farmEnabled() then
		pcall(AutoFarmCmds.Disable)
		fixIdentity()
	end
end

------------------------------------------------------------------
-- เลือกไข่
------------------------------------------------------------------
local function pickEgg(forceNearest)
	local eggs = scanEggs()
	if state.lastEggCount ~= #eggs then
		state.lastEggCount = #eggs
		print(("[AutoEgg] เจอไข่ %d ใบ"):format(#eggs))
	end
	if #eggs == 0 then return nil end

	if state.anchor then
		-- 1) ใบที่เคยเลือกไว้ (จำเป็นระยะเทียบกับโซน)
		if not forceNearest and type(config.eggOffset) == "table" then
			local target = state.anchor + Vector3.new(config.eggOffset[1], config.eggOffset[2], config.eggOffset[3])
			local e = nearestTo(eggs, target, 15)
			if e then return e end
		end
		-- 2) ไข่ประจำโซนนี้ของ plot เรา (PadSpot_<AREA>_Egg)
		if not forceNearest and state.eggHint then
			local e = nearestTo(eggs, state.eggHint, 20)
			if e then return e end
		end
		-- 3) ใบใกล้จุดฟาร์ม
		local e = nearestTo(eggs, state.anchor, EGG_RADIUS)
		if not e then
			local any = nearestTo(eggs, state.anchor)
			warn(("[AutoEgg] ไม่มีไข่ในระยะ %d studs (ใบใกล้สุดห่าง %s)"):format(
				EGG_RADIUS, any and tostring(math.floor((any.position - state.anchor).Magnitude)) or "?"))
		end
		return e
	end

	-- ไม่รู้ base: ไม่วาร์ป แค่เลือกไข่ตามที่จำไว้/ใกล้ตัว
	if not forceNearest and config.eggName then
		for _, e in ipairs(eggs) do
			if e.name == config.eggName then return e end
		end
	end
	local me = myPos()
	return (me and nearestTo(eggs, me)) or eggs[1]
end

local function setEgg(e, why)
	state.egg = e
	if e then
		config.eggName = e.name
		if state.anchor and e.position and (e.position - state.anchor).Magnitude <= TP_SAFE_RADIUS then
			local o = e.position - state.anchor
			config.eggOffset = { o.X, o.Y, o.Z }
		end
		saveConfig()
	end
	state.info = e and ("Egg: " .. (e.name or "?") .. " [" .. string.sub(e.uid, 1, 8) .. "] " .. (why or ""))
		or "Egg: ไม่เจอ - กด E เปิดไข่เอง 1 ครั้ง"
	refresh()
end

------------------------------------------------------------------
-- ดักจากกด E (hook ใส่เฉพาะตอนต้องใช้ แล้วถอดทันที)
------------------------------------------------------------------
local captureOld = nil
local function removeCaptureHook()
	if captureOld and hookmetamethod then
		pcall(hookmetamethod, game, "__namecall", captureOld)
	end
	captureOld = nil
	if getgenv then getgenv().__AutoEggCapture = nil end
end

local function onCapture(uid)
	fixIdentity()
	if not isUid(uid) then return end
	removeCaptureHook()
	local name, pos
	for _, e in ipairs(scanEggs()) do
		if e.uid == uid then name, pos = e.name, e.position break end
	end
	pos = pos or myPos()
	setEgg({ uid = uid, name = name, position = pos }, "(ดักจากกด E)")
end

local function installCaptureHook()
	if captureOld or not (hookmetamethod and getnamecallmethod and checkcaller and getgenv) then return end
	getgenv().__AutoEggCapture = onCapture
	local remote = HatchRemote
	local wrap = newcclosure or function(f) return f end
	local old
	old = hookmetamethod(game, "__namecall", wrap(function(self, ...)
		if rawequal(self, remote) and not checkcaller() and getnamecallmethod() == "InvokeServer" then
			local cb = getgenv().__AutoEggCapture
			if cb then task.spawn(cb, (...)) end
		end
		return old(self, ...)
	end))
	captureOld = old
end

------------------------------------------------------------------
-- เข้า event
------------------------------------------------------------------
local function inEvent()
	if not InstancingCmds then return false end
	local ok, r = pcall(InstancingCmds.IsInInstance, EVENT_ID)
	return ok and r == true
end

local function joinEvent()
	if not InstancingCmds then
		state.lastErr = "โหลด InstancingCmds ไม่ได้"
		return false
	end
	if inEvent() then return true end

	local ready = false
	task.spawn(function()
		pcall(InstancingCmds.All)
		ready = true
	end)
	local t = 0
	while not ready and t < 15 do t += task.wait(0.25) end
	fixIdentity()

	for attempt = 1, 3 do
		state.info = ("กำลังเข้า event %s (%d/3)"):format(EVENT_ID, attempt)
		refresh()
		task.spawn(function() pcall(InstancingCmds.Enter, EVENT_ID) end)
		local w = 0
		while w < 25 and not inEvent() do w += task.wait(0.5) end
		fixIdentity()
		if inEvent() then
			task.wait(2)
			return true
		end
	end
	state.lastErr = "เข้า event ไม่ได้"
	return false
end

------------------------------------------------------------------
-- ปิด animation เปิดไข่
------------------------------------------------------------------
local noop = function() end
local patched = {}
local PATCH = {
	["Egg Opening Frontend"] = {
		PlayEggAnimation = noop,
		PlayNormalEggAnimation = noop,
	},
}

local function disableAnimation()
	if not getsenv then return 0 end
	local ps = LocalPlayer:FindFirstChild("PlayerScripts")
	if not ps then return 0 end
	local count = 0
	for _, s in ipairs(ps:GetDescendants()) do
		local targets = s:IsA("LocalScript") and PATCH[s.Name]
		if targets then
			local ok, env = pcall(getsenv, s)
			if ok and type(env) == "table" then
				for key, repl in pairs(targets) do
					local val = rawget(env, key)
					if type(val) == "function" and val ~= repl then
						table.insert(patched, { env, key, val })
						env[key] = repl
						count += 1
					end
				end
			end
		end
	end
	fixIdentity()
	return count
end

local function restoreAnimation()
	for _, p in ipairs(patched) do
		pcall(function() p[1][p[2]] = p[3] end)
	end
	table.clear(patched)
end

------------------------------------------------------------------
-- FPS BOOST
--  - ปิดเงา / post effect (Bloom, Blur, SunRays, ColorCorrection, DepthOfField)
--  - ปิด particle / trail / beam / ควัน / ไฟ (ตัวที่กินเครื่องที่สุดตอนฟาร์ม)
--  - ลด quality, ปิดหญ้าของ terrain
--  ปิด boost จะคืนค่าเกือบทั้งหมด
------------------------------------------------------------------
local FX_CLASS = { ParticleEmitter = true, Trail = true, Beam = true, Smoke = true, Fire = true, Sparkles = true }
local boost = { conn = nil, fx = setmetatable({}, { __mode = "k" }), post = {}, light = nil, quality = nil, deco = nil }

local function lighten(d)
	if FX_CLASS[d.ClassName] then
		local ok, en = pcall(function() return d.Enabled end)
		if ok and en then
			boost.fx[d] = true
			pcall(function() d.Enabled = false end)
		end
	end
end

local function applyBoost(on)
	if on then
		if not boost.light then
			boost.light = { GlobalShadows = Lighting.GlobalShadows, FogEnd = Lighting.FogEnd }
		end
		pcall(function()
			Lighting.GlobalShadows = false
			Lighting.FogEnd = 1e9
		end)
		for _, e in ipairs(Lighting:GetDescendants()) do
			if e:IsA("PostEffect") and e.Enabled then
				boost.post[e] = true
				e.Enabled = false
			end
		end
		pcall(function()
			boost.quality = boost.quality or settings().Rendering.QualityLevel
			settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
		end)
		pcall(function()
			if boost.deco == nil then boost.deco = workspace.Terrain.Decoration end
			workspace.Terrain.Decoration = false
		end)
		-- ของใหม่ที่เกิดขึ้น (เช็คด้วย ClassName ตรงๆ เร็วมาก)
		if not boost.conn then
			boost.conn = workspace.DescendantAdded:Connect(lighten)
		end
		-- ของที่มีอยู่แล้ว: ทยอยทำทีละก้อน ไม่ให้เกมค้าง
		task.spawn(function()
			local list = workspace:GetDescendants()
			for i = 1, #list do
				if not config.fpsBoost then return end
				lighten(list[i])
				if i % 4000 == 0 then task.wait() end
			end
		end)
	else
		if boost.conn then boost.conn:Disconnect() boost.conn = nil end
		for d in pairs(boost.fx) do pcall(function() d.Enabled = true end) end
		table.clear(boost.fx)
		for e in pairs(boost.post) do pcall(function() e.Enabled = true end) end
		table.clear(boost.post)
		if boost.light then
			pcall(function()
				Lighting.GlobalShadows = boost.light.GlobalShadows
				Lighting.FogEnd = boost.light.FogEnd
			end)
		end
		if boost.quality then pcall(function() settings().Rendering.QualityLevel = boost.quality end) end
		if boost.deco ~= nil then pcall(function() workspace.Terrain.Decoration = boost.deco end) end
	end
end

-- ปิดภาพ 3D ทั้งหมด (AFK) = เบาที่สุด เกมยังทำงานปกติ แค่ไม่วาดภาพ
local function apply3D(off)
	pcall(function() RunService:Set3dRenderingEnabled(not off) end)
end

------------------------------------------------------------------
-- จำนวนสูงสุด
------------------------------------------------------------------
local function getMaxHatch()
	local n, src
	if EggCmds then
		for _, fname in ipairs({ "GetMaxHatch", "GetMaxHatchCount", "GetHatchCount", "MaxHatch" }) do
			local f = EggCmds[fname]
			if type(f) == "function" then
				local ok, r = pcall(f)
				if ok and tonumber(r) and r > 0 then n, src = math.floor(r), "EggCmds." .. fname break end
			end
		end
	end
	if not n and Save and Save.Get then
		local ok, data = pcall(Save.Get)
		if ok and type(data) == "table" then
			for _, key in ipairs({ "EggHatchCount", "MaxEggHatch", "HatchCount" }) do
				local r = tonumber(data[key])
				if r and r > 0 then n, src = math.floor(r), "Save." .. key break end
			end
		end
	end
	fixIdentity()
	return n, src
end

local function resolveAmount()
	local n, src = getMaxHatch()
	if n then
		state.amount, state.source = n, src
	elseif config.probedMax then
		state.amount, state.source = config.probedMax, "max (saved)"
	else
		state.amount, state.source = PROBE_START, "probing"
	end
end

------------------------------------------------------------------
-- เปิดไข่
------------------------------------------------------------------
local function hatch(amount)
	local e = state.egg
	if not e then return false, "ยังไม่มีไข่" end
	local ok, a, b = pcall(function()
		return HatchRemote:InvokeServer(e.uid, amount)
	end)
	if not ok then return false, tostring(a) end
	if a == false then return false, tostring(b or "server rejected") end
	return true
end

------------------------------------------------------------------
-- GUI
------------------------------------------------------------------
local parentGui = (gethui and gethui()) or game:GetService("CoreGui")
local oldGui = parentGui:FindFirstChild("AutoEggGUI")
if oldGui then oldGui:Destroy() end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "AutoEggGUI"
ScreenGui.ResetOnSpawn = false
if not pcall(function() ScreenGui.Parent = parentGui end) then
	ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

local Frame = Instance.new("Frame")
Frame.Size = UDim2.fromOffset(260, 364)
Frame.Position = UDim2.new(0, 260, 0.5, -182)
Frame.BackgroundColor3 = Color3.fromRGB(25, 25, 32)
Frame.BorderSizePixel = 0
Frame.Parent = ScreenGui
Instance.new("UICorner", Frame).CornerRadius = UDim.new(0, 10)
local stroke = Instance.new("UIStroke", Frame)
stroke.Color = Color3.fromRGB(70, 70, 90)
stroke.Thickness = 1.5

local function label(text, x, y, w, h, bold)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.fromOffset(w, h or 18)
	l.Position = UDim2.fromOffset(x, y)
	l.BackgroundTransparency = 1
	l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	l.TextSize = bold and 16 or 12
	l.TextColor3 = bold and Color3.fromRGB(235, 235, 245) or Color3.fromRGB(170, 170, 185)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.TextWrapped = true
	l.Text = text
	l.Parent = Frame
	return l
end

local function button(x, y, w, h)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(w, h)
	b.Position = UDim2.fromOffset(x, y)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 13
	b.TextColor3 = Color3.new(1, 1, 1)
	b.AutoButtonColor = false
	b.Parent = Frame
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
	return b
end

local ON = Color3.fromRGB(46, 170, 90)
local OFF = Color3.fromRGB(170, 50, 50)
local GREY = Color3.fromRGB(80, 80, 95)

label("Auto Event Egg", 12, 8, 200, 22, true)

local Close = button(230, 7, 24, 24)
Close.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
Close.Text = "X"

local EggLabel = label("Egg: กำลังหา...", 12, 36, 236, 32)
local ListBtn = button(12, 70, 115, 28)
ListBtn.BackgroundColor3 = Color3.fromRGB(60, 90, 160)
ListBtn.Text = "รายการไข่"
local CapBtn = button(133, 70, 115, 28)
CapBtn.BackgroundColor3 = Color3.fromRGB(150, 100, 40)
CapBtn.Text = "ดักจากกด E"

local ListFrame = Instance.new("ScrollingFrame")
ListFrame.Size = UDim2.fromOffset(250, 364)
ListFrame.Position = UDim2.fromOffset(268, 0)
ListFrame.BackgroundColor3 = Color3.fromRGB(25, 25, 32)
ListFrame.BorderSizePixel = 0
ListFrame.ScrollBarThickness = 4
ListFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
ListFrame.CanvasSize = UDim2.new()
ListFrame.Visible = false
ListFrame.Parent = Frame
Instance.new("UICorner", ListFrame).CornerRadius = UDim.new(0, 10)
do
	local pad = Instance.new("UIPadding", ListFrame)
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6)
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 6), UDim.new(0, 10)
	local layout = Instance.new("UIListLayout", ListFrame)
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
end

local JoinBtn = button(12, 104, 115, 28)
JoinBtn.TextSize = 11
local BaseBtn = button(133, 104, 115, 28)
BaseBtn.BackgroundColor3 = Color3.fromRGB(110, 70, 160)
BaseBtn.TextSize = 11
BaseBtn.Text = "ตั้งเป็น base ของฉัน"
local FarmBtn = button(12, 138, 236, 28)
local AnimBtn = button(12, 172, 236, 28)
local BoostBtn = button(12, 206, 115, 28)
BoostBtn.TextSize = 11
local No3DBtn = button(133, 206, 115, 28)
No3DBtn.TextSize = 11
local Toggle = button(12, 240, 236, 38)
Toggle.TextSize = 15

local Status = label("", 12, 284, 236, 74)

-- เขียน property เฉพาะตอนค่าเปลี่ยน (ไม่ให้ GUI วาดใหม่ทุกครึ่งวิโดยไม่จำเป็น)
local uiCache = setmetatable({}, { __mode = "k" })
local function setProp(obj, prop, val)
	local t = uiCache[obj]
	if not t then t = {} uiCache[obj] = t end
	if t[prop] ~= val then
		t[prop] = val
		obj[prop] = val
	end
end

refresh = function()
	fixIdentity()
	if not Frame.Visible then return end -- ซ่อน GUI อยู่ = ไม่ต้องอัปเดต
	pcall(function()
		setProp(EggLabel, "Text", state.info or "Egg: กำลังหา...")
		setProp(JoinBtn, "Text", config.autoJoin and "AUTO JOIN: ON" or "AUTO JOIN: OFF")
		setProp(JoinBtn, "BackgroundColor3", config.autoJoin and ON or GREY)
		local farmOn = config.autoFarm and farmEnabled()
		setProp(FarmBtn, "Text", ("AUTO FARM: %s%s"):format(config.autoFarm and "ON" or "OFF",
			config.autoFarm and (farmOn and " (ทำงาน)" or " (ยังไม่ทำงาน)") or ""))
		setProp(FarmBtn, "BackgroundColor3", config.autoFarm and ON or GREY)
		setProp(AnimBtn, "Text", config.skipAnim and ("SKIP ANIMATION: ON (" .. #patched .. ")") or "SKIP ANIMATION: OFF")
		setProp(AnimBtn, "BackgroundColor3", config.skipAnim and ON or GREY)
		setProp(BoostBtn, "Text", config.fpsBoost and "FPS BOOST: ON" or "FPS BOOST: OFF")
		setProp(BoostBtn, "BackgroundColor3", config.fpsBoost and ON or GREY)
		setProp(No3DBtn, "Text", config.no3d and "ปิดภาพ 3D: ON" or "ปิดภาพ 3D: OFF")
		setProp(No3DBtn, "BackgroundColor3", config.no3d and ON or GREY)
		setProp(Toggle, "Text", state.running and "AUTO HATCH: ON" or "AUTO HATCH: OFF")
		setProp(Toggle, "BackgroundColor3", state.running and ON or OFF)
		local mins = math.max((os.clock() - state.startedAt) / 60, 1 / 60)
		setProp(Status, "Text", string.format("x%s (%s) | ทุก %.2fs\nhatched: %d | %d ใบ/นาที | ช้าไป %d\nplot: %s | event: %s%s",
			tostring(state.amount or "?"), state.source, state.interval,
			state.hatched, math.floor(state.hatched / mins), state.quickCount,
			state.plot and state.plot.Name or "?", inEvent() and "yes" or "no",
			state.lastErr and ("\n" .. state.lastErr) or ""))
	end)
end

------------------------------------------------------------------
-- เตรียมพร้อม: เข้า event -> วาร์ปไปโซน -> เปิดฟาร์ม -> หาไข่ -> ขยับใกล้ไข่
------------------------------------------------------------------
local function prepare()
	if state.busyPrep then
		while state.busyPrep do task.wait(0.2) end
		return state.egg ~= nil
	end
	state.busyPrep = true
	state.lastPrep = os.clock()
	if config.autoJoin and not inEvent() then
		joinEvent()
	end
	if not inEvent() then
		-- ไม่อยู่ใน event = ไม่มี plot ของเรา -> ห้ามวาร์ป
		state.busyPrep = false
		return false
	end

	state.info = "กำลังไป " .. ZONE_NAME
	refresh()
	goToZone()

	if config.autoFarm and state.anchor then
		state.info = "กำลังเปิด auto farm"
		refresh()
		enableFarm()
	end

	local e
	for _ = 1, 10 do
		e = pickEgg(false)
		if e then break end
		task.wait(1)
	end
	fixIdentity()
	if e then
		setEgg(e, config.eggOffset and "(จากที่จำไว้)" or "(ใกล้สุด)")
		moveNearEgg()
		if config.autoFarm and state.anchor then task.wait(0.5) enableFarm() end
	elseif not state.egg then
		setEgg(nil)
		installCaptureHook()
	end
	state.busyPrep = false
	return state.egg ~= nil
end

------------------------------------------------------------------
-- loop
------------------------------------------------------------------
local function worker(session)
	while state.running and state.session == session and ScreenGui.Parent do
		if not state.egg then
			task.wait(1)
		else
			-- จังหวะเปิด: นับจาก "เวลาที่เปิดติดครั้งล่าสุด" ไม่ใช่นับต่อจากตอนได้คำตอบ
			-- (แบบเก่าเอา ping + ดีเลย์มาบวกกัน ทำให้ช้ากว่า cooldown จริงของเซิร์ฟมาก)
			local due = state.lastOkAt + state.interval
			local now = os.clock()
			if due > now then task.wait(due - now) end

			local sentAt = os.clock()
			local ok, err = hatch(state.amount)
			if ok then
				state.lastOkAt = sentAt
				state.hatched += state.amount
				state.lastErr = nil
				state.fails = 0
				state.okCount += 1
				if config.skipAnim and Variables then
					pcall(function() Variables.OpeningEgg = 0 end)
				end
			else
				if string.find(string.lower(tostring(err)), "quickly") then
					-- เร็วเกิน: ไม่ปรับความเร็ว (ค่าตายตัว) แค่รออีก 1 รอบแล้วค่อยเปิดใหม่
					state.lastOkAt = os.clock()
					state.quickCount += 1
				else
					state.lastErr = "error: " .. tostring(err)
					state.fails += 1
					if state.fails >= 5 then
						state.fails = 0
						prepare()
					end
					task.wait(0.5)
				end
			end
			task.wait() -- กันลูปหมุนในเฟรมเดียว
		end
	end
end

local function start()
	state.session += 1
	local session = state.session
	state.interval = HATCH_INTERVAL -- ค่าตายตัว ไม่ปรับเอง
	state.lastOkAt, state.okCount, state.quickCount = 0, 0, 0
	state.hatched, state.startedAt = 0, os.clock()
	prepare()
	resolveAmount()
	refresh()

	while state.running and state.session == session and state.source == "probing" do
		if not state.egg then task.wait(1) continue end
		local ok = hatch(state.amount)
		if ok then
			state.hatched += state.amount
			state.source = "max (probed)"
			config.probedMax = state.amount
			saveConfig()
		elseif state.amount > 1 then
			state.amount -= 1
			state.lastErr = "ลองลดเป็น x" .. state.amount
			task.wait(0.15)
		else
			state.lastErr = "เปิดไม่ได้เลย เช็คเงิน/ระยะไข่"
			state.amount = PROBE_START
			task.wait(2)
		end
		refresh()
	end

	for _ = 1, THREADS do
		task.spawn(worker, session)
	end
end

local function setRunning(on)
	state.running = on
	config.running = on
	saveConfig()
	if on then task.spawn(start) else state.session += 1 end
	refresh()
end

------------------------------------------------------------------
-- ปุ่ม
------------------------------------------------------------------
Toggle.MouseButton1Click:Connect(function()
	setRunning(not state.running)
end)

local function buildList()
	local eggs = scanEggs()
	fixIdentity()
	for _, c in ipairs(ListFrame:GetChildren()) do
		if c:IsA("GuiObject") then c:Destroy() end
	end
	-- รู้ base แล้ว: โชว์เฉพาะไข่ใน base เรา (กันเลือกไข่บ้านคนอื่น)
	if state.anchor then
		local mine = {}
		for _, e in ipairs(eggs) do
			if e.position and (e.position - state.anchor).Magnitude <= TP_SAFE_RADIUS then
				table.insert(mine, e)
			end
		end
		eggs = mine
	end
	local me = myPos()
	local function dist(e)
		return (me and e.position) and (e.position - me).Magnitude or math.huge
	end
	table.sort(eggs, function(a, b) return dist(a) < dist(b) end)

	for i, e in ipairs(eggs) do
		local d = dist(e)
		local b = Instance.new("TextButton")
		b.LayoutOrder = i
		b.Size = UDim2.new(1, 0, 0, 30)
		b.AutoButtonColor = true
		b.BackgroundColor3 = (state.egg and state.egg.uid == e.uid) and ON or Color3.fromRGB(45, 45, 60)
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Font = Enum.Font.Gotham
		b.TextSize = 12
		b.TextXAlignment = Enum.TextXAlignment.Left
		b.Text = string.format("  %d. %s  |  %s  |  %s", i, e.name or "?",
			d < math.huge and (math.floor(d) .. "m") or "?m", string.sub(e.uid, 1, 6))
		b.Parent = ListFrame
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
		b.MouseButton1Click:Connect(function()
			setEgg(e, "(เลือกจากรายการ)")
			task.spawn(moveNearEgg)
			ListFrame.Visible = false
		end)
	end

	if #eggs == 0 then
		local l = Instance.new("TextLabel")
		l.Size = UDim2.new(1, 0, 0, 40)
		l.BackgroundTransparency = 1
		l.TextWrapped = true
		l.Font = Enum.Font.Gotham
		l.TextSize = 12
		l.TextColor3 = Color3.fromRGB(200, 200, 210)
		l.Text = "ไม่เจอไข่ใน base เรา ใช้ปุ่ม \"ดักจากกด E\" แทน"
		l.Parent = ListFrame
	end
	ListFrame.Visible = true
end

ListBtn.MouseButton1Click:Connect(function()
	if ListFrame.Visible then ListFrame.Visible = false else task.spawn(buildList) end
end)

CapBtn.MouseButton1Click:Connect(function()
	installCaptureHook()
	state.info = "ไปกด E ที่ไข่ที่ต้องการ 1 ครั้ง..."
	refresh()
end)

JoinBtn.MouseButton1Click:Connect(function()
	config.autoJoin = not config.autoJoin
	saveConfig()
	refresh()
	if config.autoJoin then task.spawn(prepare) end
end)

BaseBtn.MouseButton1Click:Connect(function()
	if not inEvent() then
		state.lastErr = "ต้องอยู่ใน event ก่อน"
		refresh()
		return
	end
	local p, d = plotAtMe()
	if p and d < TP_SAFE_RADIUS then
		state.plotOverride = p
		state.plotSure = false
		state.lastErr = nil
		print("[AutoEgg] ตั้ง base ของฉัน = plot", p.Name, ("(ห่าง %d studs)"):format(math.floor(d)))
		state.info = "base ของฉัน = plot " .. p.Name
		refresh()
		task.spawn(prepare)
	else
		state.lastErr = "ยืนไกล base เกินไป เดินเข้าไปใน " .. ZONE_NAME .. " ก่อน"
		refresh()
	end
end)

FarmBtn.MouseButton1Click:Connect(function()
	config.autoFarm = not config.autoFarm
	saveConfig()
	task.spawn(function()
		if config.autoFarm then enableFarm() else disableFarm() end
		refresh()
	end)
	refresh()
end)

AnimBtn.MouseButton1Click:Connect(function()
	config.skipAnim = not config.skipAnim
	saveConfig()
	restoreAnimation()
	if config.skipAnim then disableAnimation() end
	refresh()
end)

BoostBtn.MouseButton1Click:Connect(function()
	config.fpsBoost = not config.fpsBoost
	saveConfig()
	applyBoost(config.fpsBoost)
	refresh()
end)

No3DBtn.MouseButton1Click:Connect(function()
	config.no3d = not config.no3d
	saveConfig()
	apply3D(config.no3d)
	refresh()
end)

Close.MouseButton1Click:Connect(function()
	state.running = false
	state.session += 1
	restoreAnimation()
	removeCaptureHook()
	apply3D(false)          -- ปิด GUI แล้วต้องเห็นภาพเกมเสมอ
	applyBoost(false)
	ScreenGui:Destroy()
end)

-- ลากหน้าต่าง
do
	local dragging, dragStart, startPos
	Frame.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, input.Position, Frame.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			Frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
end

-- RightShift = ซ่อน/แสดง
UserInputService.InputBegan:Connect(function(input, gpe)
	if not gpe and input.KeyCode == Enum.KeyCode.RightShift then
		Frame.Visible = not Frame.Visible
		if Frame.Visible then refresh() end
	end
end)

------------------------------------------------------------------
-- ลูปพื้นหลัง (รวมเป็นลูปเดียว)
--  - อัปเดต GUI ทุก 0.5 วิ
--  - ทุก 5 วิ: ถ้าหลุด event -> เข้าใหม่ / ถ้า auto farm หลุด -> กลับจุดยืนแล้วเปิดใหม่
------------------------------------------------------------------
task.spawn(function()
	local tick5, outSince = 0, nil
	while ScreenGui.Parent do
		refresh()
		task.wait(0.5)
		tick5 += 0.5
		if tick5 >= 5 then
			tick5 = 0
			if not state.busyPrep then
				local inside = inEvent()
				if not inside then
					outSince = outSince or os.clock()
					-- หลุด event เกิน 10 วิ และเปิด auto join ไว้ -> เข้าใหม่
					if config.autoJoin and (state.running or config.autoFarm) and os.clock() - outSince > 10 then
						outSince = nil
						task.spawn(prepare)
					end
				else
					outSince = nil
					if not state.plot then
						-- กลับเข้ามาแล้วแต่ยังไม่รู้ base (ลองใหม่ทุก 30 วิ ไม่ให้วนถี่)
						if os.clock() - (state.lastPrep or 0) > 30 then task.spawn(prepare) end
					elseif config.autoFarm and not farmEnabled() then
						local me = myPos()
						local spot = state.stand or state.anchor
						if me and spot and (me - spot).Magnitude > 30 then
							safeTP(spot + Vector3.new(0, 3, 0))
							task.wait(1)
						end
						enableFarm()
					end
				end
			end
		end
	end
end)

------------------------------------------------------------------
-- เริ่มต้น
------------------------------------------------------------------
refresh()
if config.fpsBoost then applyBoost(true) end
if config.no3d then apply3D(true) end
task.spawn(function()
	if config.skipAnim then
		for _ = 1, 10 do
			if disableAnimation() > 0 then break end
			task.wait(1)
		end
		if Variables then pcall(function() Variables.OpeningEgg = 0 end) end
	end
	refresh()
	if config.running then
		setRunning(true)
	elseif config.autoJoin then
		prepare()
	end
end)
