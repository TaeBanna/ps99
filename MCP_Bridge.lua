--// MCP Bridge: ให้ Claude (ผ่าน MCP) รันโค้ด / อ่าน console / ดู Instance ในเกมได้เอง
--// ต้องรัน mcp-bridge/server.js บนเครื่องเดียวกัน (Claude Code / Claude Desktop เปิดให้อัตโนมัติ)
--//
--// วิธีใช้: รันใน executor
--//   loadstring(game:HttpGet("https://raw.githubusercontent.com/TaeBanna/ps99/main/MCP_Bridge.lua"))()
--// เปลี่ยน port:   getgenv().MCP_BRIDGE_URL = "http://127.0.0.1:8765"  (ตั้งก่อน loadstring)
--// หยุด:           getgenv().MCPBridgeStop()

if not game:IsLoaded() then game.Loaded:Wait() end

local genv = (getgenv and getgenv()) or shared
local BASE_URL = genv.MCP_BRIDGE_URL or "http://127.0.0.1:8765"

local httpRequest = (syn and syn.request) or request or http_request
	or (http and http.request) or (fluxus and fluxus.request)
if not httpRequest then
	warn("[MCP] executor นี้ไม่มีฟังก์ชัน request/http_request — ใช้ bridge ไม่ได้")
	return
end

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")

local LocalPlayer = Players.LocalPlayer

-- รันซ้ำ = หยุดตัวเก่าก่อน
if genv.MCPBridgeStop then pcall(genv.MCPBridgeStop) end
local alive = true
local connections = {}
genv.MCPBridgeStop = function()
	alive = false
	for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
	genv.MCPBridgeStop = nil
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
	}
end

------------------------------------------------------------------
-- HTTP
------------------------------------------------------------------
local function encode(tbl)
	local ok, s = pcall(HttpService.JSONEncode, HttpService, tbl)
	if ok then return s end
	-- string บางตัวมี byte แปลกๆ -> ล้างทิ้งแล้วลองใหม่
	local function clean(v)
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

local function post(path, tbl)
	tbl.clientId = clientId
	local ok, res = pcall(httpRequest, {
		Url = BASE_URL .. path,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = encode(tbl),
	})
	if not ok or type(res) ~= "table" then return nil, tostring(res) end
	local code = res.StatusCode or res.Status or 0
	if code ~= 200 then return nil, "HTTP " .. tostring(code) end
	local dok, data = pcall(HttpService.JSONDecode, HttpService, res.Body or "")
	return dok and data or {}, nil
end

------------------------------------------------------------------
-- แปลงค่าเป็นข้อความอ่านง่าย
------------------------------------------------------------------
local function fmt(v, depth, seen)
	depth = depth or 0
	local t = typeof(v)
	if t == "string" then
		return depth == 0 and v or string.format("%q", v)
	elseif t == "Instance" then
		local ok, full = pcall(v.GetFullName, v)
		return (ok and full or tostring(v)) .. " [" .. v.ClassName .. "]"
	elseif t == "table" then
		seen = seen or {}
		if seen[v] then return "<cycle>" end
		if depth >= 3 then return "{...}" end
		seen[v] = true
		local parts, n = {}, 0
		for k, x in pairs(v) do
			n = n + 1
			if n > 50 then parts[#parts + 1] = "..." break end
			local key = type(k) == "string" and k or ("[" .. fmt(k, depth + 1, seen) .. "]")
			parts[#parts + 1] = string.rep("  ", depth + 1) .. key .. " = " .. fmt(x, depth + 1, seen)
		end
		seen[v] = nil
		if #parts == 0 then return "{}" end
		return "{\n" .. table.concat(parts, ",\n") .. "\n" .. string.rep("  ", depth) .. "}"
	elseif t == "function" then
		return tostring(v)
	elseif t == "EnumItem" or t == "Vector3" or t == "Vector2" or t == "CFrame" or t == "Color3" or t == "UDim2" then
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

-- ส่ง log เก่าที่มีอยู่แล้วไปด้วย (เห็น error ที่เกิดก่อนรัน bridge)
pcall(function()
	for _, entry in ipairs(LogService:GetLogHistory()) do
		pushLog(entry.message, entry.messageType, entry.timestamp)
	end
end)

table.insert(connections, LogService.MessageOut:Connect(function(msg, mtype)
	pushLog(msg, mtype)
end))

task.spawn(function()
	while alive do
		if #logBuffer > 0 then
			local batch = logBuffer
			logBuffer = {}
			local _, err = post("/logs", { logs = batch })
			if err then -- ส่งไม่ได้ -> เก็บไว้ส่งรอบหน้า
				for i = #batch, 1, -1 do table.insert(logBuffer, 1, batch[i]) end
				while #logBuffer > 2000 do table.remove(logBuffer, 1) end
				task.wait(2)
			end
		end
		task.wait(0.5)
	end
end)

------------------------------------------------------------------
-- คำสั่ง
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
		__newindex = persistent, -- global ที่ตั้งในโค้ด จะอยู่ต่อข้ามการรันครั้งต่อไป
	})
	rawset(env, "print", function(...)
		output[#output + 1] = joinArgs(...)
		print(...)
	end)
	rawset(env, "warn", function(...)
		output[#output + 1] = "[warn] " .. joinArgs(...)
		warn(...)
	end)
	return env
end

local handlers = {}

function handlers.exec(cmd)
	local output = {}
	local fn, cerr = loadstring(cmd.code or "", "=" .. tostring(cmd.chunkName or "mcp"))
	if not fn then
		return { ok = false, error = "compile error: " .. tostring(cerr), output = output }
	end
	setfenv(fn, makeEnv(output))

	local done, result = false, nil
	local started = tick()
	task.spawn(function()
		local packed = table.pack(xpcall(fn, function(e)
			return tostring(e) .. "\n" .. debug.traceback(nil, 2)
		end))
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

	local out = table.clone(output)
	if not done then
		return { ok = true, stillRunning = true, elapsed = math.floor((tick() - started) * 10) / 10, output = out }
	end
	result.output = out
	return result
end

local function resolvePath(path)
	path = tostring(path or "game")
	local sep = path:find("/", 1, true) and "/" or "."
	local parts = {}
	for p in string.gmatch(path, "[^" .. (sep == "." and "%." or "/") .. "]+") do parts[#parts + 1] = p end
	local node = game
	local i = 1
	if parts[1] == "game" then i = 2 end
	if parts[i] and node == game then
		local ok, svc = pcall(game.GetService, game, parts[i])
		if ok and svc then node = svc i = i + 1 end
	end
	for j = i, #parts do
		local child = node:FindFirstChild(parts[j])
		if not child then
			return nil, "ไม่เจอ '" .. parts[j] .. "' ใน " .. node:GetFullName()
		end
		node = child
	end
	return node
end

function handlers.tree(cmd)
	local root, err = resolvePath(cmd.path)
	if not root then return { ok = false, error = err } end
	local maxDepth = tonumber(cmd.depth) or 2
	local maxChildren = tonumber(cmd.maxChildren) or 50
	local filter = cmd.filter and string.lower(cmd.filter)
	local lines, MAX_LINES = {}, 3000

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

local function runCommand(cmd)
	local handler = handlers[cmd.type]
	local ok, res = pcall(function()
		if not handler then return { ok = false, error = "ไม่รู้จักคำสั่ง: " .. tostring(cmd.type) } end
		return handler(cmd)
	end)
	if not ok then res = { ok = false, error = "bridge error: " .. tostring(res) } end
	res.id = cmd.id
	for _ = 1, 3 do -- ส่งผลกลับ ลองซ้ำถ้าพลาด
		local _, err = post("/result", res)
		if not err then break end
		task.wait(1)
	end
end

------------------------------------------------------------------
-- poll loop
------------------------------------------------------------------
task.spawn(function()
	local connected, backoff = false, 1
	while alive do
		local data, err = post("/poll", { info = info() })
		if not alive then break end
		if data then
			if not connected then
				connected, backoff = true, 1
				print("[MCP] เชื่อมต่อกับ Claude bridge แล้ว (" .. BASE_URL .. ")")
			end
			for _, cmd in ipairs(data.commands or {}) do
				task.spawn(runCommand, cmd)
			end
		else
			if connected then
				connected = false
				warn("[MCP] หลุดจาก bridge (" .. tostring(err) .. ") — จะลองต่อใหม่เรื่อยๆ")
			end
			task.wait(backoff)
			backoff = math.min(backoff * 2, 5)
		end
	end
end)

print("[MCP] bridge เริ่มทำงาน client = " .. clientId .. " -> " .. BASE_URL)
