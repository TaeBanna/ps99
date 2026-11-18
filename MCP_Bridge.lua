--// Claude Bridge: ให้ Claude (ผ่าน MCP) รันโค้ด / อ่าน console / ดูค่าต่างๆ ในเกมได้เอง
--//
--// วิธีใช้:
--//   1. บน PC เปิด Claude Code (ที่ติดตั้ง mcp-bridge แล้ว) แล้วพิมพ์ "ขอรหัสเชื่อมต่อ roblox"
--//   2. รันใน executor:
--//      loadstring(game:HttpGet("https://raw.githubusercontent.com/TaeBanna/ps99/main/MCP_Bridge.lua"))()
--//   3. พิมพ์รหัส 6 หลักในหน้าต่าง Claude Bridge -> เสร็จ
--//   ครั้งต่อไปต่อเองอัตโนมัติ ไม่ต้องใส่รหัส ใช้ได้ทุกเน็ต (ต่าง Wi-Fi / เน็ตมือถือ)
--//
--// ไฟล์นี้ไม่มี API key หรือข้อมูลลับใดๆ — มีแค่ที่อยู่ของ relay
--// token ที่ได้จากการจับคู่ถูกเก็บไว้ในเครื่องที่รันเกมเท่านั้น (ClaudeBridge.json)
--//
--// หยุด: getgenv().MCPBridgeStop()

if not game:IsLoaded() then game.Loaded:Wait() end

local SCRIPT_URL = "https://raw.githubusercontent.com/TaeBanna/ps99/main/MCP_Bridge.lua"
local RELAY_URL = "https://nltqfqfjcaebdxfcjvvt.supabase.co/functions/v1/claude-bridge"
local SAVE_FILE = "ClaudeBridge.json"

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
local function relay(action, tbl)
	tbl = tbl or {}
	tbl.action = action
	local ok, res = pcall(httpRequest, {
		Url = RELAY_URL,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = encode(tbl),
	})
	if not ok or type(res) ~= "table" then return nil, 0, "ต่อเน็ตไม่ได้: " .. tostring(res) end
	local code = tonumber(res.StatusCode or res.Status) or 0
	local dok, data = pcall(HttpService.JSONDecode, HttpService, res.Body or "")
	data = dok and type(data) == "table" and data or {}
	if code ~= 200 then return nil, code, data.error or ("HTTP " .. code) end
	return data, 200
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
local conn = { token = nil, state = "idle" } -- state: idle | searching | connected | lost
local setStatus -- จาก GUI
local pcOnline = false

local function send(messages)
	return relay("game_send", { token = conn.token, clientId = clientId, messages = messages })
end

local function takeLogs()
	local batch = logBuffer
	logBuffer = {}
	return batch
end

local function runCommand(cmd)
	local handler = handlers[cmd.type]
	local ok, res = pcall(function()
		if not handler then return { ok = false, error = "ไม่รู้จักคำสั่ง: " .. tostring(cmd.type) } end
		return handler(cmd)
	end)
	if not ok then res = { ok = false, error = "bridge error: " .. tostring(res) } end
	res.id = cmd.id
	res.kind = "result"
	-- ส่งผลพร้อม log ล่าสุด (Claude เห็น console ทันทีหลังรัน)
	local msgs = { res }
	if #logBuffer > 0 then msgs[2] = { kind = "logs", entries = takeLogs() } end
	for _ = 1, 3 do
		local _, code = send(msgs)
		if code == 200 then break end
		task.wait(1)
	end
end

local function forget(reason)
	conn.token = nil
	conn.state = "idle"
	saveSaved(nil)
	if setStatus then setStatus("idle", reason or "ยังไม่ได้เชื่อมต่อ") end
end

local connectGen = 0
local function startSession(token)
	connectGen = connectGen + 1
	local gen = connectGen
	conn.token, conn.state = token, "searching"
	saveSaved({ token = token })
	setStatus("searching", "กำลังเชื่อมต่อ...")

	-- ส่ง log (เฉพาะตอน Claude บน PC เปิดอยู่ ประหยัดโควตา)
	task.spawn(function()
		while alive and gen == connectGen do
			if pcOnline and #logBuffer > 0 then
				local batch = takeLogs()
				local _, code = send({ { kind = "logs", entries = batch } })
				if code ~= 200 then
					for i = #batch, 1, -1 do table.insert(logBuffer, 1, batch[i]) end
					while #logBuffer > 2000 do table.remove(logBuffer, 1) end
					task.wait(3)
				end
			end
			task.wait(2)
		end
	end)

	-- รับคำสั่ง
	task.spawn(function()
		local fails = 0
		while alive and gen == connectGen do
			local data, code, err = relay("game_poll", { token = conn.token, clientId = clientId, info = info(), wait = 8000 })
			if not alive or gen ~= connectGen then break end
			if code == 200 then
				fails = 0
				pcOnline = data.pcOnline == true
				conn.state = "connected"
				if pcOnline then
					setStatus("connected", "เชื่อมต่อแล้ว — Claude ควบคุมเกมนี้ได้")
				else
					setStatus("connected", "พร้อมแล้ว — รอ Claude บน PC เปิด")
				end
				for _, cmd in ipairs(data.commands or {}) do task.spawn(runCommand, cmd) end
				if not pcOnline then
					-- PC ปิดอยู่: เช็กห่างๆ ประหยัดโควตา
					for _ = 1, 15 do
						if not alive or gen ~= connectGen then break end
						task.wait(1)
					end
				end
			elseif code == 401 then
				connectGen = connectGen + 1
				forget("การจับคู่ถูกยกเลิก ใส่รหัสใหม่")
				break
			else
				fails = fails + 1
				conn.state = "lost"
				pcOnline = false
				setStatus("lost", "เน็ตหลุด กำลังต่อใหม่... (" .. tostring(err) .. ")")
				task.wait(math.min(2 * fails, 15))
			end
		end
	end)
end

-- จับคู่ด้วยรหัส
local busy = false
local function pairWithCode(code)
	if busy then return end
	busy = true
	code = tostring(code or ""):gsub("%D", "")
	if #code ~= 6 then
		setStatus("idle", "รหัสต้องเป็นตัวเลข 6 หลัก")
		busy = false
		return
	end
	setStatus("searching", "กำลังจับคู่...")
	local data, status, err = relay("game_pair", { code = code, info = info() })
	busy = false
	if status == 200 and data.token then
		print("[Claude] จับคู่สำเร็จ")
		startSession(data.token)
	else
		setStatus("idle", tostring(err or "จับคู่ไม่สำเร็จ"))
	end
end

-- ต่อเองด้วย token ที่เคยจับคู่ไว้
local function autoConnect()
	local saved = loadSaved()
	if saved and saved.token then
		startSession(saved.token)
	else
		setStatus("idle", "ใส่รหัส 6 หลักจาก Claude")
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
	Size = UDim2.fromOffset(300, 186), Position = UDim2.new(0.5, -150, 0, 70), BackgroundColor3 = COLORS.bg, Active = true,
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
local pairBox = make("Frame", { Size = UDim2.new(1, -28, 0, 100), Position = UDim2.fromOffset(14, 76), BackgroundTransparency = 1 }, frame)
local codeBox = make("TextBox", {
	Size = UDim2.new(1, 0, 0, 46), BackgroundColor3 = COLORS.panel, Text = "", PlaceholderText = "รหัส 6 หลัก",
	TextColor3 = COLORS.text, PlaceholderColor3 = COLORS.sub, Font = Enum.Font.GothamBold, TextSize = 26, ClearTextOnFocus = false,
}, pairBox)
corner(codeBox, 8)
local connectBtn = make("TextButton", {
	Size = UDim2.new(1, 0, 0, 38), Position = UDim2.fromOffset(0, 56), BackgroundColor3 = COLORS.accent,
	Text = "เชื่อมต่อ", TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 16,
}, pairBox)
corner(connectBtn, 8)

-- ส่วนตอนเชื่อมต่อแล้ว
local connectedBox = make("Frame", { Size = UDim2.new(1, -28, 0, 100), Position = UDim2.fromOffset(14, 76), BackgroundTransparency = 1, Visible = false }, frame)
make("TextLabel", {
	Size = UDim2.new(1, 0, 0, 52), BackgroundTransparency = 1, TextWrapped = true,
	Text = "สั่งงานใน Claude Code บน PC ได้เลย\nย้ายเซิร์ฟ/รีจอย จะต่อเองอัตโนมัติ",
	TextColor3 = COLORS.text, Font = Enum.Font.Gotham, TextSize = 14,
}, connectedBox)
local unpairBtn = make("TextButton", {
	Size = UDim2.new(1, 0, 0, 38), Position = UDim2.fromOffset(0, 56), BackgroundColor3 = COLORS.panel,
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
		connectBtn.Text = busy and "กำลังจับคู่..." or "เชื่อมต่อ"
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
	connectGen = connectGen + 1 -- หยุด session เก่า
	conn.state = "idle"
	task.spawn(pairWithCode, codeBox.Text)
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
	for _ = 1, 30 do
		if not alive or conn.state == "connected" then break end
		task.wait(0.5)
	end
	task.wait(1.5)
	if alive and conn.state == "connected" then setMinimized(true) end
end)
