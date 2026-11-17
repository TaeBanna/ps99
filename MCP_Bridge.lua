--// Claude Bridge: ให้ Claude (ผ่าน MCP) รันโค้ด / อ่าน console / ดูค่าต่างๆ ในเกมได้เอง
--//
--// วิธีใช้:
--//   1. บน PC เปิด Claude Code (ที่ติดตั้ง mcp-bridge แล้ว) แล้วพิมพ์ "ขอรหัสเชื่อมต่อ roblox"
--//   2. รันใน executor:
--//      loadstring(game:HttpGet("https://raw.githubusercontent.com/TaeBanna/ps99/main/MCP_Bridge.lua"))()
--//   3. พิมพ์รหัส 6 หลักในหน้าต่าง Claude Bridge -> เสร็จ
--//   ครั้งต่อไปต่อเองอัตโนมัติ ไม่ต้องใส่รหัส (มือถือต้องอยู่ Wi-Fi เดียวกับ PC)
--//
--// หยุด: getgenv().MCPBridgeStop()

if not game:IsLoaded() then game.Loaded:Wait() end

local SCRIPT_URL = "https://raw.githubusercontent.com/TaeBanna/ps99/main/MCP_Bridge.lua"
local PORT = 8765
local SAVE_FILE = "ClaudeBridge.json"
-- วง Wi-Fi ที่จะสแกนหา PC (เรียงตามที่เจอบ่อย) ใส่เพิ่มได้ด้วย getgenv().MCP_SUBNETS = {"192.168.50"}
local DEFAULT_SUBNETS = {
	"192.168.1", "192.168.0", "192.168.137", "192.168.2", "192.168.100", "192.168.3",
	"192.168.4", "192.168.5", "192.168.8", "192.168.10", "192.168.11", "192.168.88",
	"192.168.31", "192.168.43", "192.168.68", "192.168.178", "10.0.0", "10.0.1", "10.1.1",
	"172.16.0", "172.20.10",
}

local genv = (getgenv and getgenv()) or shared

local httpRequest = (syn and syn.request) or request or http_request
	or (http and http.request) or (fluxus and fluxus.request)
if not httpRequest then
	warn("[Claude] executor นี้ไม่มีฟังก์ชัน request/http_request — ใช้ bridge ไม่ได้")
	return
end

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer

-- รันซ้ำ = หยุดตัวเก่าก่อน
if genv.MCPBridgeStop then pcall(genv.MCPBridgeStop) end
local alive = true
local connections = {}
local gui -- ScreenGui (สร้างด้านล่าง)
genv.MCPBridgeStop = function()
	alive = false
	for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
	if gui then pcall(function() gui:Destroy() end) end
	genv.MCPBridgeStop = nil
end

local setIdentity = setthreadidentity or set_thread_identity or setidentity
	or (syn and syn.set_thread_identity)
local function fixIdentity()
	if setIdentity then pcall(setIdentity, 8) end
end

local clientId = LocalPlayer and LocalPlayer.Name or ("client-" .. HttpService:GenerateGUID(false):sub(1, 8))

local function info()
	local executor = "unknown"
	if identifyexecutor then
		local ok, name, ver = pcall(identifyexecutor)
		if ok and name then executor = tostring(name) .. (ver and (" " .. tostring(ver)) or "") end
	end
	return {
		player = LocalPlayer and LocalPlayer.Name,
		userId = LocalPlayer and LocalPlayer.UserId,
		placeId = game.PlaceId,
		jobId = game.JobId,
		executor = executor,
		device = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and "mobile" or "pc",
	}
end

------------------------------------------------------------------
-- บันทึก / โหลด การจับคู่
------------------------------------------------------------------
local function loadSaved()
	if not (readfile and isfile) then return genv.__ClaudeBridgeSaved end
	local ok, data = pcall(function()
		if not isfile(SAVE_FILE) then return nil end
		return HttpService:JSONDecode(readfile(SAVE_FILE))
	end)
	return ok and data or nil
end

local function saveSaved(data)
	genv.__ClaudeBridgeSaved = data
	if not writefile then return end
	pcall(function()
		if data then
			writefile(SAVE_FILE, HttpService:JSONEncode(data))
		elseif delfile and isfile and isfile(SAVE_FILE) then
			delfile(SAVE_FILE)
		end
	end)
end

------------------------------------------------------------------
-- HTTP
------------------------------------------------------------------
local function encode(tbl)
	local ok, s = pcall(HttpService.JSONEncode, HttpService, tbl)
	if ok then return s end
	local function clean(v) -- string บางตัวมี byte แปลกๆ -> ล้างทิ้งแล้วลองใหม่
		if type(v) == "string" then return (v:gsub("[\128-\255]", "?")) end
		if type(v) == "table" then
			local t = {}
			for k, x in pairs(v) do t[k] = clean(x) end
			return t
		end
		return v
	end
	return HttpService:JSONEncode(clean(tbl))
end

-- คืน: data, statusCode (0 = ต่อไม่ได้), errorText
local function rawPost(url, path, tbl)
	local ok, res = pcall(httpRequest, {
		Url = url .. path,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = encode(tbl),
	})
	if not ok or type(res) ~= "table" then return nil, 0, tostring(res) end
	local code = tonumber(res.StatusCode or res.Status) or 0
	local dok, data = pcall(HttpService.JSONDecode, HttpService, res.Body or "")
	data = dok and type(data) == "table" and data or {}
	if code ~= 200 then return nil, code, data.error or ("HTTP " .. code) end
	return data, 200
end

local function isBridge(url)
	local ok, res = pcall(httpRequest, { Url = url .. "/", Method = "GET" })
	if not ok or type(res) ~= "table" then return nil end
	local dok, data = pcall(HttpService.JSONDecode, HttpService, res.Body or "")
	if dok and type(data) == "table" and data.name == "roblox-mcp-bridge" then return data end
	return nil
end

------------------------------------------------------------------
-- หา PC ในวง Wi-Fi
------------------------------------------------------------------
local function hostOf(url)
	return url and url:match("^https?://([^:/]+)")
end

-- เช็กหลาย url พร้อมกัน คืน url แรกๆ ที่เป็น bridge (รอไม่เกิน timeout)
local function probeMany(urls, timeout)
	local found, finished = {}, 0
	for _, url in ipairs(urls) do
		task.spawn(function()
			if isBridge(url) then found[#found + 1] = url end
			finished = finished + 1
		end)
	end
	local t0 = tick()
	while alive and #found == 0 and finished < #urls and tick() - t0 < timeout do task.wait(0.1) end
	return found
end

-- onProgress(text) ใช้แสดงสถานะใน GUI
local function discover(manualHost, savedUrl, onProgress)
	local quick = {}
	local function addQuick(host)
		if not host or host == "" then return end
		local url = host:find("://") and host or ("http://" .. host .. (host:find(":") and "" or (":" .. PORT)))
		for _, u in ipairs(quick) do if u == url then return end end
		quick[#quick + 1] = url
	end
	addQuick(manualHost)
	addQuick(hostOf(savedUrl))
	addQuick("127.0.0.1") -- เล่นบน PC เครื่องเดียวกัน
	if genv.MCP_BRIDGE_URL then addQuick(genv.MCP_BRIDGE_URL) end

	onProgress("กำลังหา PC...")
	local found = probeMany(quick, 4)
	if #found > 0 then return found end
	if manualHost and manualHost ~= "" then return {} end -- ใส่ IP มาเองแล้วไม่เจอ ไม่ต้องสแกน

	local subnets, seen = {}, {}
	local function addSubnet(s)
		if s and not seen[s] then seen[s] = true subnets[#subnets + 1] = s end
	end
	local savedHost = hostOf(savedUrl)
	addSubnet(savedHost and savedHost:match("^(%d+%.%d+%.%d+)%.%d+$"))
	for _, s in ipairs(genv.MCP_SUBNETS or {}) do addSubnet(s) end
	for _, s in ipairs(DEFAULT_SUBNETS) do addSubnet(s) end

	for i, subnet in ipairs(subnets) do
		if not alive then break end
		onProgress(string.format("กำลังสแกน %s.x  (%d/%d)", subnet, i, #subnets))
		local urls = {}
		for h = 1, 254 do urls[#urls + 1] = string.format("http://%s.%d:%d", subnet, h, PORT) end
		found = probeMany(urls, 4)
		if #found > 0 then return found end
	end
	return {}
end

------------------------------------------------------------------
-- แปลงค่าเป็นข้อความอ่านง่าย
------------------------------------------------------------------
local function fmt(v, depth, seen, maxDepth)
	depth = depth or 0
	maxDepth = maxDepth or 3
	local t = typeof(v)
	if t == "string" then
		return depth == 0 and v or string.format("%q", v)
	elseif t == "Instance" then
		local ok, full = pcall(v.GetFullName, v)
		return (ok and full or tostring(v)) .. " [" .. v.ClassName .. "]"
	elseif t == "table" then
		seen = seen or {}
		if seen[v] then return "<cycle>" end
		if depth >= maxDepth then return "{...}" end
		seen[v] = true
		local parts, n = {}, 0
		for k, x in pairs(v) do
			n = n + 1
			if n > 80 then parts[#parts + 1] = string.rep("  ", depth + 1) .. "..." break end
			local key = type(k) == "string" and k or ("[" .. fmt(k, depth + 1, seen, maxDepth) .. "]")
			parts[#parts + 1] = string.rep("  ", depth + 1) .. key .. " = " .. fmt(x, depth + 1, seen, maxDepth)
		end
		seen[v] = nil
		if #parts == 0 then return "{}" end
		return "{\n" .. table.concat(parts, ",\n") .. "\n" .. string.rep("  ", depth) .. "}"
	elseif t == "EnumItem" or t == "Vector3" or t == "Vector2" or t == "CFrame" or t == "Color3" or t == "UDim2" or t == "UDim" then
		return t .. "(" .. tostring(v) .. ")"
	end
	return tostring(v)
end

local function joinArgs(...)
	local n = select("#", ...)
	local parts = table.create(n)
	for i = 1, n do
		local v = select(i, ...)
		parts[i] = type(v) == "string" and v or fmt(v)
	end
	return table.concat(parts, " ")
end

------------------------------------------------------------------
-- console log
------------------------------------------------------------------
local logBuffer = {}
local TYPE_NAMES = {
	[Enum.MessageType.MessageOutput] = "output",
	[Enum.MessageType.MessageInfo] = "info",
	[Enum.MessageType.MessageWarning] = "warning",
	[Enum.MessageType.MessageError] = "error",
}

local function pushLog(msg, mtype, t)
	if #logBuffer >= 2000 then table.remove(logBuffer, 1) end
	logBuffer[#logBuffer + 1] = { msg = msg, type = TYPE_NAMES[mtype] or "output", t = t or os.time() }
end

pcall(function() -- log เก่าก่อนรัน bridge
	for _, entry in ipairs(LogService:GetLogHistory()) do
		pushLog(entry.message, entry.messageType, entry.timestamp)
	end
end)
table.insert(connections, LogService.MessageOut:Connect(pushLog))

------------------------------------------------------------------
-- หาของในเกมจาก path
------------------------------------------------------------------
local function resolvePath(p)
	p = tostring(p or "game")
	local sep = p:find("/", 1, true) and "[^/]+" or "[^%.]+"
	local parts = {}
	for s in string.gmatch(p, sep) do parts[#parts + 1] = s end
	local node, i = game, 1
	if parts[1] == "game" then i = 2 end
	if parts[i] == "workspace" then parts[i] = "Workspace" end
	if parts[i] then
		local ok, svc = pcall(game.GetService, game, parts[i])
		if ok and svc then node, i = svc, i + 1 end
	end
	for j = i, #parts do
		local child
		if node == Players and parts[j] == "LocalPlayer" then
			child = LocalPlayer
		elseif node == LocalPlayer and parts[j] == "Character" then
			child = LocalPlayer.Character
		else
			child = node:FindFirstChild(parts[j])
		end
		if not child then return nil, "ไม่เจอ '" .. parts[j] .. "' ใน " .. node:GetFullName() end
		node = child
	end
	return node
end

------------------------------------------------------------------
-- คำสั่งจาก Claude
------------------------------------------------------------------
local baseEnv = getfenv(0)
local persistent = genv.__MCPGlobals or {}
genv.__MCPGlobals = persistent

local function makeEnv(output)
	local env = setmetatable({}, {
		__index = function(_, k)
			local v = persistent[k]
			if v ~= nil then return v end
			v = genv[k]
			if v ~= nil then return v end
			return baseEnv[k]
		end,
		__newindex = persistent, -- global ที่ตั้งในโค้ด อยู่ต่อข้ามการรันครั้งต่อไป
	})
	rawset(env, "print", function(...)
		output[#output + 1] = joinArgs(...)
		print(...)
	end)
	rawset(env, "warn", function(...)
		output[#output + 1] = "[warn] " .. joinArgs(...)
		warn(...)
	end)
	rawset(env, "inspect", function(v, d) return fmt(v, 0, nil, d or 4) end)
	return env
end

local handlers = {}

function handlers.exec(cmd)
	local output = {}
	local fn, cerr = loadstring(cmd.code or "", "=" .. tostring(cmd.chunkName or "mcp"))
	if not fn then return { ok = false, error = "compile error: " .. tostring(cerr), output = output } end
	setfenv(fn, makeEnv(output))

	local done, result = false, nil
	local started = tick()
	task.spawn(function()
		local packed = table.pack(xpcall(fn, function(e)
			return tostring(e) .. "\n" .. debug.traceback(nil, 2)
		end))
		fixIdentity()
		if packed[1] then
			local returns = {}
			for i = 2, packed.n do returns[#returns + 1] = fmt(packed[i]) end
			result = { ok = true, returns = returns }
		else
			result = { ok = false, error = tostring(packed[2]) }
		end
		done = true
	end)

	local timeout = tonumber(cmd.timeout) or 15
	while not done and tick() - started < timeout do task.wait(0.05) end
	if not done then
		return { ok = true, stillRunning = true, elapsed = math.floor((tick() - started) * 10) / 10, output = table.clone(output) }
	end
	result.output = table.clone(output)
	return result
end

local function describe(inst)
	local s = inst.Name .. " [" .. inst.ClassName .. "]"
	if inst:IsA("ValueBase") then
		local ok, v = pcall(function() return inst.Value end)
		if ok then s = s .. " = " .. fmt(v, 1) end
	end
	local ok, attrs = pcall(inst.GetAttributes, inst)
	if ok and next(attrs) then
		local a = {}
		for k, v in pairs(attrs) do a[#a + 1] = k .. "=" .. fmt(v, 1) end
		table.sort(a)
		s = s .. "  {" .. table.concat(a, ", ") .. "}"
	end
	return s
end

function handlers.tree(cmd)
	local root, err = resolvePath(cmd.path)
	if not root then return { ok = false, error = err } end
	local maxDepth = tonumber(cmd.depth) or 2
	local maxChildren = tonumber(cmd.maxChildren) or 50
	local filter = cmd.filter and string.lower(cmd.filter)
	local lines, MAX_LINES = {}, 3000

	local function walk(inst, depth)
		if #lines >= MAX_LINES then return end
		if not filter or depth == 0 or string.find(string.lower(inst.Name), filter, 1, true) then
			lines[#lines + 1] = string.rep("  ", depth) .. describe(inst)
		end
		if depth >= maxDepth then return end
		local ok, children = pcall(inst.GetChildren, inst)
		if not ok then return end
		for idx, child in ipairs(children) do
			if idx > maxChildren then
				lines[#lines + 1] = string.rep("  ", depth + 1) .. "... (+" .. (#children - maxChildren) .. " ตัว)"
				break
			end
			walk(child, depth + 1)
		end
	end

	walk(root, 0)
	if #lines >= MAX_LINES then lines[#lines + 1] = "... (ตัดที่ " .. MAX_LINES .. " บรรทัด ลด depth หรือใช้ filter)" end
	return { ok = true, tree = root:GetFullName() .. "\n" .. table.concat(lines, "\n") }
end

local PROPS = {
	"Archivable", "Position", "Orientation", "CFrame", "Size", "Transparency", "Color", "BrickColor", "Material",
	"Anchored", "CanCollide", "CanTouch", "Massless", "Locked", "AssemblyLinearVelocity", "PrimaryPart",
	"Value", "Text", "TextColor3", "Visible", "Enabled", "Disabled", "Image", "BackgroundColor3", "BackgroundTransparency",
	"AbsolutePosition", "AbsoluteSize", "ZIndex", "LayoutOrder", "Active",
	"Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "HipHeight", "MoveDirection", "RigType", "Sit",
	"DisplayName", "UserId", "Team", "AccountAge", "MembershipType",
	"SoundId", "Playing", "Volume", "TimePosition", "AnimationId", "MeshId", "TextureID",
	"Adornee", "MaxActivationDistance", "ActionText", "ObjectText", "HoldDuration", "KeyboardKeyCode",
	"RunContext", "Brightness", "Range", "Shape",
}

function handlers.inspect(cmd)
	local inst, err = resolvePath(cmd.path)
	if not inst then return { ok = false, error = err } end
	local out = { inst:GetFullName() .. " [" .. inst.ClassName .. "]" }

	out[#out + 1] = "\n-- Properties"
	for _, prop in ipairs(PROPS) do
		local ok, v = pcall(function() return inst[prop] end)
		-- inst[x] คืนลูกที่ชื่อ x ได้ถ้าไม่มี property นั้น -> ข้าม
		if ok and v ~= nil and not (typeof(v) == "Instance" and v.Parent == inst and v.Name == prop) then
			out[#out + 1] = "  " .. prop .. " = " .. fmt(v, 1)
		end
	end
	if inst:IsA("Model") then
		local ok, pivot = pcall(inst.GetPivot, inst)
		if ok then out[#out + 1] = "  (GetPivot) = " .. fmt(pivot, 1) end
	end

	local ok, attrs = pcall(inst.GetAttributes, inst)
	if ok and next(attrs) then
		out[#out + 1] = "\n-- Attributes"
		for k, v in pairs(attrs) do out[#out + 1] = "  " .. k .. " = " .. fmt(v, 1) end
	end

	local tok, tags = pcall(CollectionService.GetTags, CollectionService, inst)
	if tok and #tags > 0 then out[#out + 1] = "\n-- Tags\n  " .. table.concat(tags, ", ") end

	local children = inst:GetChildren()
	out[#out + 1] = "\n-- Children (" .. #children .. ")"
	for i, c in ipairs(children) do
		if i > 40 then out[#out + 1] = "  ... (+" .. (#children - 40) .. ")" break end
		out[#out + 1] = "  " .. describe(c)
	end

	if cmd.require then
		if not inst:IsA("ModuleScript") then
			out[#out + 1] = "\n-- require: ไม่ใช่ ModuleScript"
		else
			local rok, mod = pcall(require, inst)
			fixIdentity()
			out[#out + 1] = "\n-- require() " .. (rok and "=" or "error:")
			out[#out + 1] = rok and fmt(mod, 0, nil, 4) or tostring(mod)
		end
	end
	return { ok = true, text = table.concat(out, "\n") }
end

------------------------------------------------------------------
-- การเชื่อมต่อ
------------------------------------------------------------------
local conn = { url = nil, token = nil, state = "idle", pc = nil } -- state: idle | searching | connected | lost
local setStatus -- จาก GUI

local function post(path, tbl)
	tbl.clientId = clientId
	tbl.token = conn.token
	return rawPost(conn.url, path, tbl)
end

local function runCommand(cmd)
	local handler = handlers[cmd.type]
	local ok, res = pcall(function()
		if not handler then return { ok = false, error = "ไม่รู้จักคำสั่ง: " .. tostring(cmd.type) } end
		return handler(cmd)
	end)
	if not ok then res = { ok = false, error = "bridge error: " .. tostring(res) } end
	res.id = cmd.id
	for _ = 1, 3 do -- ส่งผลกลับ ลองซ้ำถ้าพลาด
		local _, code = post("/result", res)
		if code == 200 then break end
		task.wait(1)
	end
end

local function forget(reason)
	conn.token, conn.url, conn.pc = nil, nil, nil
	conn.state = "idle"
	saveSaved(nil)
	if setStatus then setStatus("idle", reason or "ยังไม่ได้เชื่อมต่อ") end
end

local connectGen = 0
local function startSession(url, token, pc)
	connectGen = connectGen + 1
	local gen = connectGen
	conn.url, conn.token, conn.pc, conn.state = url, token, pc, "connected"
	saveSaved({ url = url, token = token, pc = pc })
	setStatus("connected", "เชื่อมต่อกับ " .. tostring(pc or hostOf(url)) .. " แล้ว")
	print("[Claude] เชื่อมต่อกับ Claude แล้ว (" .. url .. ")")

	-- ส่ง log
	task.spawn(function()
		while alive and gen == connectGen do
			if conn.state == "connected" and #logBuffer > 0 then
				local batch = logBuffer
				logBuffer = {}
				local _, code = post("/logs", { logs = batch })
				if code ~= 200 then
					for i = #batch, 1, -1 do table.insert(logBuffer, 1, batch[i]) end
					while #logBuffer > 2000 do table.remove(logBuffer, 1) end
					task.wait(2)
				end
			end
			task.wait(0.5)
		end
	end)

	-- รับคำสั่ง
	task.spawn(function()
		local fails = 0
		while alive and gen == connectGen do
			local data, code, err = post("/poll", { info = info() })
			if not alive or gen ~= connectGen then break end
			if code == 200 then
				if conn.state ~= "connected" then
					conn.state = "connected"
					setStatus("connected", "เชื่อมต่อกับ " .. tostring(conn.pc or hostOf(conn.url)) .. " แล้ว")
				end
				fails = 0
				for _, cmd in ipairs(data.commands or {}) do task.spawn(runCommand, cmd) end
			elseif code == 401 then
				connectGen = connectGen + 1
				forget("การจับคู่ถูกยกเลิก ใส่รหัสใหม่")
				break
			else
				fails = fails + 1
				conn.state = "lost"
				setStatus("lost", "หลุดจาก PC กำลังต่อใหม่... (" .. tostring(err) .. ")")
				if fails >= 4 then
					-- IP ของ PC อาจเปลี่ยน -> สแกนหาใหม่ด้วย token เดิม
					local found = discover(nil, conn.url, function(t) setStatus("lost", t) end)
					for _, u in ipairs(found) do
						local _, c2 = rawPost(u, "/logs", { clientId = clientId, token = conn.token, logs = {} })
						if c2 == 200 then conn.url = u saveSaved({ url = u, token = conn.token, pc = conn.pc }) break end
					end
					fails = 0
				end
				task.wait(math.min(1 + fails, 5))
			end
		end
	end)
end

-- จับคู่ด้วยรหัส
local busy = false
local function pairWithCode(code, manualHost)
	if busy then return end
	busy = true
	code = tostring(code or ""):gsub("%D", "")
	if #code ~= 6 then
		setStatus("idle", "รหัสต้องเป็นตัวเลข 6 หลัก")
		busy = false
		return
	end
	setStatus("searching", "กำลังหา PC...")
	local saved = loadSaved()
	local found = discover(manualHost, saved and saved.url, function(t) setStatus("searching", t) end)
	if #found == 0 then
		setStatus("idle", "หา PC ไม่เจอ — เช็กว่าเปิด Claude อยู่ และอยู่ Wi-Fi เดียวกัน (หรือใส่ IP ของ PC)")
		busy = false
		return
	end
	local lastErr
	for _, url in ipairs(found) do
		setStatus("searching", "เจอ PC แล้ว กำลังจับคู่...")
		local data, status, err = rawPost(url, "/pair", { code = code, info = info() })
		if status == 200 and data.token then
			busy = false
			startSession(url, data.token, data.pc)
			return
		end
		lastErr = err
	end
	setStatus("idle", tostring(lastErr or "จับคู่ไม่สำเร็จ"))
	busy = false
end

-- ต่อเองด้วย token ที่เคยจับคู่ไว้
local function autoConnect()
	local saved = loadSaved()
	if not (saved and saved.token) then
		setStatus("idle", "ใส่รหัส 6 หลักจาก Claude")
		return
	end
	conn.token = saved.token
	setStatus("searching", "กำลังต่อกับ PC เดิม...")
	while alive and conn.state ~= "connected" and conn.token == saved.token do
		if saved.url then
			local _, code = rawPost(saved.url, "/logs", { clientId = clientId, token = saved.token, logs = {} })
			if code == 200 then return startSession(saved.url, saved.token, saved.pc) end
			if code == 401 then return forget("การจับคู่เดิมใช้ไม่ได้แล้ว ใส่รหัสใหม่") end
		end
		local found = discover(nil, saved.url, function(t) setStatus("searching", t) end)
		for _, u in ipairs(found) do
			local _, code = rawPost(u, "/logs", { clientId = clientId, token = saved.token, logs = {} })
			if code == 200 then return startSession(u, saved.token, saved.pc) end
		end
		setStatus("searching", "ยังหา PC ไม่เจอ (เปิด Claude ไว้ไหม?) จะลองใหม่เรื่อยๆ — หรือใส่รหัสใหม่")
		for _ = 1, 10 do
			if not alive or busy or conn.state == "connected" then return end
			task.wait(1)
		end
	end
end

------------------------------------------------------------------
-- GUI
------------------------------------------------------------------
local COLORS = {
	bg = Color3.fromRGB(24, 24, 28), panel = Color3.fromRGB(36, 36, 42), text = Color3.fromRGB(235, 235, 240),
	sub = Color3.fromRGB(160, 160, 170), accent = Color3.fromRGB(217, 119, 87),
	idle = Color3.fromRGB(150, 150, 160), searching = Color3.fromRGB(240, 190, 60),
	connected = Color3.fromRGB(80, 200, 120), lost = Color3.fromRGB(230, 80, 80),
}

local function make(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	o.Parent = parent
	return o
end
local function corner(o, r) make("UICorner", { CornerRadius = UDim.new(0, r or 8) }, o) end

local parentGui = (gethui and gethui()) or game:GetService("CoreGui")
local oldGui = parentGui:FindFirstChild("ClaudeBridgeGUI")
if oldGui then oldGui:Destroy() end

gui = make("ScreenGui", { Name = "ClaudeBridgeGUI", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999 })
if not pcall(function() gui.Parent = parentGui end) then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

-- ปุ่มเล็ก (ตอนย่อ)
local pill = make("TextButton", {
	Size = UDim2.fromOffset(110, 34), Position = UDim2.new(0, 12, 0, 60), BackgroundColor3 = COLORS.bg,
	Text = "", AutoButtonColor = true, Visible = false,
}, gui)
corner(pill, 17)
local pillDot = make("Frame", { Size = UDim2.fromOffset(10, 10), Position = UDim2.new(0, 12, 0.5, -5), BackgroundColor3 = COLORS.idle }, pill)
corner(pillDot, 5)
make("TextLabel", {
	Size = UDim2.new(1, -30, 1, 0), Position = UDim2.fromOffset(28, 0), BackgroundTransparency = 1,
	Text = "Claude", TextColor3 = COLORS.text, Font = Enum.Font.GothamBold, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left,
}, pill)

-- หน้าต่างหลัก
local frame = make("Frame", {
	Size = UDim2.fromOffset(300, 214), Position = UDim2.new(0.5, -150, 0, 70), BackgroundColor3 = COLORS.bg, Active = true,
}, gui)
corner(frame, 12)
make("UIStroke", { Color = COLORS.accent, Thickness = 1.5, Transparency = 0.3 }, frame)

local title = make("TextLabel", {
	Size = UDim2.new(1, -50, 0, 36), Position = UDim2.fromOffset(14, 2), BackgroundTransparency = 1,
	Text = "Claude Bridge", TextColor3 = COLORS.text, Font = Enum.Font.GothamBold, TextSize = 17, TextXAlignment = Enum.TextXAlignment.Left,
}, frame)
local minBtn = make("TextButton", {
	Size = UDim2.fromOffset(30, 30), Position = UDim2.new(1, -38, 0, 5), BackgroundColor3 = COLORS.panel,
	Text = "–", TextColor3 = COLORS.text, Font = Enum.Font.GothamBold, TextSize = 18,
}, frame)
corner(minBtn, 8)

local statusDot = make("Frame", { Size = UDim2.fromOffset(10, 10), Position = UDim2.fromOffset(14, 47), BackgroundColor3 = COLORS.idle }, frame)
corner(statusDot, 5)
local statusLabel = make("TextLabel", {
	Size = UDim2.new(1, -46, 0, 34), Position = UDim2.fromOffset(32, 38), BackgroundTransparency = 1, TextWrapped = true,
	Text = "", TextColor3 = COLORS.sub, Font = Enum.Font.Gotham, TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center,
}, frame)

-- ส่วนใส่รหัส
local pairBox = make("Frame", { Size = UDim2.new(1, -28, 0, 130), Position = UDim2.fromOffset(14, 76), BackgroundTransparency = 1 }, frame)
local codeBox = make("TextBox", {
	Size = UDim2.new(1, 0, 0, 46), BackgroundColor3 = COLORS.panel, Text = "", PlaceholderText = "รหัส 6 หลัก",
	TextColor3 = COLORS.text, PlaceholderColor3 = COLORS.sub, Font = Enum.Font.GothamBold, TextSize = 26, ClearTextOnFocus = false,
}, pairBox)
corner(codeBox, 8)
local ipBox = make("TextBox", {
	Size = UDim2.new(1, 0, 0, 30), Position = UDim2.fromOffset(0, 52), BackgroundColor3 = COLORS.panel, Text = "",
	PlaceholderText = "IP ของ PC (ไม่ต้องใส่ก็ได้)", TextColor3 = COLORS.text, PlaceholderColor3 = COLORS.sub,
	Font = Enum.Font.Gotham, TextSize = 13, ClearTextOnFocus = false,
}, pairBox)
corner(ipBox, 8)
local connectBtn = make("TextButton", {
	Size = UDim2.new(1, 0, 0, 38), Position = UDim2.fromOffset(0, 88), BackgroundColor3 = COLORS.accent,
	Text = "เชื่อมต่อ", TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 16,
}, pairBox)
corner(connectBtn, 8)

-- ส่วนตอนเชื่อมต่อแล้ว
local connectedBox = make("Frame", { Size = UDim2.new(1, -28, 0, 130), Position = UDim2.fromOffset(14, 76), BackgroundTransparency = 1, Visible = false }, frame)
make("TextLabel", {
	Size = UDim2.new(1, 0, 0, 80), BackgroundTransparency = 1, TextWrapped = true,
	Text = "Claude ควบคุมเกมนี้ได้แล้ว\nสั่งงานใน Claude Code บน PC ได้เลย\n(ย้ายเซิร์ฟ/รีจอยแล้วจะต่อเองอัตโนมัติ)",
	TextColor3 = COLORS.text, Font = Enum.Font.Gotham, TextSize = 14,
}, connectedBox)
local unpairBtn = make("TextButton", {
	Size = UDim2.new(1, 0, 0, 38), Position = UDim2.fromOffset(0, 88), BackgroundColor3 = COLORS.panel,
	Text = "ยกเลิกการเชื่อมต่อ", TextColor3 = COLORS.lost, Font = Enum.Font.GothamBold, TextSize = 15,
}, connectedBox)
corner(unpairBtn, 8)

setStatus = function(state, msg)
	pcall(function()
		statusDot.BackgroundColor3 = COLORS[state] or COLORS.idle
		pillDot.BackgroundColor3 = COLORS[state] or COLORS.idle
		statusLabel.Text = msg or ""
		local isConnected = state == "connected"
		connectedBox.Visible = isConnected
		pairBox.Visible = not isConnected
		connectBtn.Text = state == "searching" and "กำลังเชื่อมต่อ..." or "เชื่อมต่อ"
	end)
end

local function setMinimized(min)
	frame.Visible = not min
	pill.Visible = min
end

table.insert(connections, minBtn.MouseButton1Click:Connect(function() setMinimized(true) end))
table.insert(connections, pill.MouseButton1Click:Connect(function() setMinimized(false) end))
table.insert(connections, codeBox:GetPropertyChangedSignal("Text"):Connect(function()
	local digits = codeBox.Text:gsub("%D", ""):sub(1, 6)
	if digits ~= codeBox.Text then codeBox.Text = digits end
end))
table.insert(connections, connectBtn.MouseButton1Click:Connect(function()
	if busy then return end
	connectGen = connectGen + 1 -- หยุดการต่ออัตโนมัติ/session เก่า
	conn.state = "idle"
	task.spawn(pairWithCode, codeBox.Text, ipBox.Text)
end))
table.insert(connections, unpairBtn.MouseButton1Click:Connect(function()
	connectGen = connectGen + 1
	forget("ยกเลิกแล้ว ใส่รหัสใหม่เพื่อเชื่อมต่อ")
	codeBox.Text = ""
end))

-- ลากย้ายได้ (นิ้ว/เมาส์)
local function draggable(handle, target)
	local dragging, startPos, startInput, moved
	table.insert(connections, handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, moved, startInput, startPos = true, false, input.Position, target.Position
		end
	end))
	table.insert(connections, UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - startInput
			if d.Magnitude > 4 then moved = true end
			target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end))
	table.insert(connections, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
end
draggable(title, frame)
draggable(pill, pill)

------------------------------------------------------------------
-- ย้ายเซิร์ฟ / รีจอย -> รัน bridge ต่อเอง
------------------------------------------------------------------
local queueTeleport = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)
if queueTeleport and LocalPlayer then
	table.insert(connections, LocalPlayer.OnTeleport:Connect(function(st)
		if st == Enum.TeleportState.Started and alive and conn.token then
			pcall(queueTeleport, 'loadstring(game:HttpGet("' .. SCRIPT_URL .. '"))()')
		end
	end))
end

------------------------------------------------------------------
-- เริ่ม
------------------------------------------------------------------
setStatus("idle", "ใส่รหัส 6 หลักจาก Claude")
task.spawn(function()
	autoConnect()
	if conn.state == "connected" then
		task.wait(2)
		if alive and conn.state == "connected" then setMinimized(true) end
	end
end)
