#!/usr/bin/env node
// Roblox <-> Claude MCP bridge (ไม่ต้องลง npm package อะไรเลย ใช้แค่ Node 18+)
//
//   Claude Code / Claude Desktop ──MCP (stdio)──> server.js ──HTTP :8765──  MCP_Bridge.lua (ใน executor)
//
// การจับคู่:
//   1. server สุ่มรหัส 6 หลัก (ขอดูได้ด้วย tool roblox_pair)
//   2. ในเกมพิมพ์รหัส -> สคริปต์สแกนหา PC ในวง Wi-Fi เอง -> ส่งรหัสมา
//   3. รหัสถูก -> ได้ token ยาวกลับไป (เก็บทั้งสองฝั่ง ครั้งหน้าต่อเองไม่ต้องใส่รหัส)
//   รหัสใช้ได้ครั้งเดียว / ผิด 5 ครั้งเปลี่ยนรหัสใหม่ทันที
//
// stdout = ช่อง MCP ห้ามเขียนอย่างอื่นลงไป (ใช้ log() ที่เขียนลง stderr)

"use strict";
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");

const PORT = Number(process.env.ROBLOX_MCP_PORT || 8765);
const HOST = process.env.ROBLOX_MCP_HOST || "0.0.0.0";
const BASE_DIR = path.resolve(process.env.ROBLOX_MCP_ROOT || path.join(__dirname, ".."));
const SESSIONS_FILE = path.join(__dirname, ".sessions.json");
const POLL_HOLD_MS = 10000;     // poll ค้างรอคำสั่งได้นานสุดเท่านี้
const CLIENT_STALE_MS = 30000;  // ไม่ poll มานานเกินนี้ = ถือว่าหลุด
const MAX_LOGS = 5000;
const MAX_PAIR_FAILS = 5;       // ใส่รหัสผิดเกินนี้ -> สุ่มรหัสใหม่
const PAIR_LOCK_AFTER = 10;     // เปลี่ยนรหัสเพราะโดนเดาเกินนี้ -> พักการจับคู่ชั่วคราว
const PAIR_LOCK_MS = 60000;

const log = (...a) => process.stderr.write("[roblox-mcp] " + a.join(" ") + "\n");

// ------------------------------------------------------------------
// การจับคู่ + token
// ------------------------------------------------------------------
let sessions = {}; // token -> { player, pairedAt }
try { sessions = JSON.parse(fs.readFileSync(SESSIONS_FILE, "utf8")) || {}; } catch { sessions = {}; }
function saveSessions() {
	try { fs.writeFileSync(SESSIONS_FILE, JSON.stringify(sessions, null, 2)); } catch (e) { log("บันทึก session ไม่ได้: " + e.message); }
}

let pairCode = "";
let pairFails = 0;
let pairRotations = 0;
let pairLockedUntil = 0;
function newPairCode() {
	pairCode = String(crypto.randomInt(0, 1000000)).padStart(6, "0");
	pairFails = 0;
	log(`รหัสจับคู่: ${pairCode}`);
}
newPairCode();

function safeEqual(a, b) {
	const x = Buffer.from(String(a)), y = Buffer.from(String(b));
	return x.length === y.length && crypto.timingSafeEqual(x, y);
}

function lanIps() {
	const out = [];
	for (const list of Object.values(os.networkInterfaces())) {
		for (const a of list || []) if (a.family === "IPv4" && !a.internal) out.push(a.address);
	}
	return out;
}

// ------------------------------------------------------------------
// state ของ client
// ------------------------------------------------------------------
const clients = new Map();  // clientId -> { info, lastSeen, queue: [], waiter }
const pending = new Map();  // cmdId -> { resolve, timer }
let logs = [];              // { seq, t, clientId, type, msg }
let logSeq = 0;
let cmdSeq = 0;

function getClient(id) {
	let c = clients.get(id);
	if (!c) {
		c = { info: {}, lastSeen: 0, queue: [], waiter: null };
		clients.set(id, c);
	}
	return c;
}

function liveClients() {
	const now = Date.now();
	return [...clients.entries()].filter(([, c]) => now - c.lastSeen < CLIENT_STALE_MS);
}

function pickClient(clientId) {
	if (clientId) {
		const c = clients.get(clientId);
		if (!c || Date.now() - c.lastSeen >= CLIENT_STALE_MS) throw new Error(`client "${clientId}" ไม่ได้เชื่อมต่ออยู่`);
		return clientId;
	}
	const live = liveClients().sort((a, b) => b[1].lastSeen - a[1].lastSeen);
	if (live.length === 0) {
		throw new Error(
			"ยังไม่มีเกมเชื่อมต่อ — ให้ผู้ใช้รัน MCP_Bridge.lua ใน executor แล้วใส่รหัสจับคู่ " + pairCode +
			" (ถ้าเคยจับคู่แล้วจะต่อเองอัตโนมัติ)"
		);
	}
	return live[0][0];
}

function flushQueue(c) {
	if (c.waiter && c.queue.length) {
		const w = c.waiter;
		c.waiter = null;
		clearTimeout(w.timer);
		w.send(c.queue.splice(0));
	}
}

// ส่งคำสั่งไปให้ Roblox แล้วรอผล
function sendCommand(clientId, type, payload, timeoutSec) {
	const id = String(++cmdSeq);
	const c = getClient(clientId);
	const waitMs = (timeoutSec + 10) * 1000; // เผื่อเวลา network
	return new Promise((resolve) => {
		const timer = setTimeout(() => {
			pending.delete(id);
			resolve({ ok: false, error: `ไม่ได้รับผลตอบกลับใน ${timeoutSec + 10} วินาที (เกมหลุด หรือค้าง?)` });
		}, waitMs);
		pending.set(id, { resolve, timer });
		c.queue.push({ id, type, timeout: timeoutSec, ...payload });
		flushQueue(c);
	});
}

function addLogs(clientId, entries) {
	for (const e of entries || []) {
		logs.push({ seq: ++logSeq, t: e.t || Date.now() / 1000, clientId, type: e.type || "output", msg: String(e.msg ?? "") });
	}
	if (logs.length > MAX_LOGS) logs = logs.slice(-MAX_LOGS);
}

// ------------------------------------------------------------------
// HTTP server (ฝั่ง Roblox คุยด้วย)
// ------------------------------------------------------------------
function readBody(req) {
	return new Promise((resolve) => {
		let data = "";
		req.on("data", (ch) => {
			data += ch;
			if (data.length > 20 * 1024 * 1024) req.destroy();
		});
		req.on("end", () => {
			try { resolve(data ? JSON.parse(data) : {}); } catch { resolve({}); }
		});
		req.on("error", () => resolve({}));
	});
}

function json(res, code, obj) {
	const s = JSON.stringify(obj);
	res.writeHead(code, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(s) });
	res.end(s);
}

function handlePair(body, res) {
	const now = Date.now();
	if (now < pairLockedUntil) {
		return json(res, 429, { error: `ใส่รหัสผิดบ่อยเกินไป รอ ${Math.ceil((pairLockedUntil - now) / 1000)} วินาที` });
	}
	if (!safeEqual(String(body.code || "").trim(), pairCode)) {
		pairFails++;
		let msg = "รหัสไม่ถูกต้อง";
		if (pairFails >= MAX_PAIR_FAILS) {
			pairRotations++;
			newPairCode();
			msg += " (ผิดหลายครั้ง รหัสถูกเปลี่ยนแล้ว ขอรหัสใหม่จาก Claude)";
			if (pairRotations >= PAIR_LOCK_AFTER) {
				pairRotations = 0;
				pairLockedUntil = now + PAIR_LOCK_MS;
			}
		}
		log("จับคู่ไม่สำเร็จ: " + msg);
		return json(res, 403, { error: msg });
	}
	const token = crypto.randomBytes(32).toString("hex");
	const player = (body.info && body.info.player) || "unknown";
	sessions[token] = { player, pairedAt: new Date().toISOString() };
	saveSessions();
	pairRotations = 0;
	newPairCode(); // รหัสใช้ได้ครั้งเดียว
	log(`จับคู่สำเร็จกับ ${player}`);
	return json(res, 200, { token, pc: os.hostname() });
}

const httpServer = http.createServer(async (req, res) => {
	const url = new URL(req.url, "http://x");
	// ใช้ตอนสแกนหา PC (ไม่มีข้อมูลลับ)
	if (req.method === "GET" && url.pathname === "/") return json(res, 200, { ok: true, name: "roblox-mcp-bridge", pc: os.hostname() });
	if (req.method !== "POST") return json(res, 404, { error: "not found" });

	const body = await readBody(req);
	if (url.pathname === "/pair") return handlePair(body, res);

	if (!body.token || !Object.prototype.hasOwnProperty.call(sessions, body.token)) {
		return json(res, 401, { error: "ยังไม่ได้จับคู่ หรือการจับคู่ถูกยกเลิก" });
	}

	const clientId = String(body.clientId || "default");
	const c = getClient(clientId);
	c.lastSeen = Date.now();
	if (body.info) c.info = body.info;
	if (body.logs) addLogs(clientId, body.logs);

	switch (url.pathname) {
		case "/poll": {
			if (c.waiter) { // poll ซ้อน -> ปิดอันเก่า
				clearTimeout(c.waiter.timer);
				c.waiter.send([]);
			}
			let done = false;
			const send = (cmds) => {
				if (done) return;
				done = true;
				c.lastSeen = Date.now();
				json(res, 200, { commands: cmds });
			};
			const waiter = { send, timer: setTimeout(() => { if (c.waiter === waiter) c.waiter = null; send([]); }, POLL_HOLD_MS) };
			c.waiter = waiter;
			req.on("close", () => { if (c.waiter === waiter) { clearTimeout(waiter.timer); c.waiter = null; } });
			flushQueue(c);
			return;
		}
		case "/result": {
			const p = pending.get(String(body.id));
			if (p) {
				clearTimeout(p.timer);
				pending.delete(String(body.id));
				p.resolve(body);
			}
			return json(res, 200, { ok: true });
		}
		case "/logs":
			return json(res, 200, { ok: true });
		default:
			return json(res, 404, { error: "not found" });
	}
});

httpServer.on("error", (e) => {
	log(`HTTP server error: ${e.message}` + (e.code === "EADDRINUSE" ? ` (port ${PORT} ถูกใช้อยู่ — มี Claude อีกหน้าต่างเปิด bridge อยู่แล้ว?)` : ""));
});
httpServer.listen(PORT, HOST, () => log(`listening on port ${PORT}  IP: ${lanIps().join(", ") || "-"}  (root: ${BASE_DIR})`));

// ------------------------------------------------------------------
// MCP tools
// ------------------------------------------------------------------
const clientIdProp = { type: "string", description: "เลือก client (ดูจาก roblox_status) ไม่ใส่ = ตัวล่าสุด" };

const TOOLS = [
	{
		name: "roblox_pair",
		description:
			"ขอรหัสจับคู่ 6 หลักสำหรับเชื่อมเกมเข้ากับ Claude — ใช้เมื่อผู้ใช้ขอรหัส/อยากเชื่อมต่อเกม. " +
			"ผู้ใช้รัน MCP_Bridge.lua ใน executor แล้วพิมพ์รหัสนี้ในหน้าต่างที่ขึ้นมา. unpair=true จะยกเลิกการจับคู่ทุกเครื่อง",
		inputSchema: {
			type: "object",
			properties: { unpair: { type: "boolean", description: "ยกเลิก token ทั้งหมด (ทุกเครื่องต้องใส่รหัสใหม่)" } },
		},
	},
	{
		name: "roblox_status",
		description: "ดูว่าเกมเชื่อมต่ออยู่ไหม พร้อมข้อมูลเกม (ผู้เล่น, PlaceId, JobId, executor) และรหัสจับคู่ปัจจุบัน",
		inputSchema: { type: "object", properties: {} },
	},
	{
		name: "roblox_execute",
		description:
			"รันโค้ด Luau ในเกม Roblox ผ่าน executor (เหมือนผู้ใช้กดรันเอง มี getgenv, hookmetamethod ฯลฯ ตาม executor). " +
			"คืนค่า: ข้อความจาก print/warn ระหว่างรัน, ค่าที่ return (แปลงเป็นข้อความอ่านง่าย รวมถึง table/Instance), หรือ error + traceback. " +
			"ตัวแปร global (ไม่ใช้ local) อยู่ต่อข้ามการรันแต่ละครั้ง. มีฟังก์ชันช่วย inspect(value) คืนข้อความอธิบายค่า. " +
			"โค้ดที่รันนานกว่า timeout จะคืนผลเท่าที่มีแล้วรันต่อเบื้องหลัง (ดูต่อด้วย roblox_get_logs)",
		inputSchema: {
			type: "object",
			properties: {
				code: { type: "string", description: "โค้ด Luau" },
				timeout: { type: "number", description: "วินาทีที่รอผล (ค่าเริ่มต้น 15)" },
				clientId: clientIdProp,
			},
			required: ["code"],
		},
	},
	{
		name: "roblox_run_file",
		description:
			"อ่านไฟล์ .lua จากเครื่อง (path เทียบกับโฟลเดอร์ repo) แล้วส่งไปรันในเกมทันที — ใช้ทดสอบโค้ดที่เพิ่งแก้โดยไม่ต้อง push ขึ้น GitHub. " +
			"สคริปต์ที่วนลูปตลอดจะคืนผลหลัง timeout และรันต่อเบื้องหลัง",
		inputSchema: {
			type: "object",
			properties: {
				path: { type: "string", description: "เช่น AutoEgg_GUI.lua" },
				timeout: { type: "number", description: "วินาทีที่รอผล (ค่าเริ่มต้น 5)" },
				clientId: clientIdProp,
			},
			required: ["path"],
		},
	},
	{
		name: "roblox_get_logs",
		description:
			"อ่าน console log ของเกม (print, warn, error จากทุกสคริปต์ รวมถึง error ของเกมเอง). " +
			"ใช้ since = seq ล่าสุดที่เคยอ่าน เพื่อดูเฉพาะ log ใหม่",
		inputSchema: {
			type: "object",
			properties: {
				since: { type: "number", description: "เอาเฉพาะ log ที่ seq มากกว่านี้" },
				limit: { type: "number", description: "จำนวนบรรทัดสูงสุด (ค่าเริ่มต้น 200, เอาบรรทัดท้ายสุด)" },
				filter: { type: "string", description: "กรองเฉพาะบรรทัดที่มีคำนี้ (ไม่สนตัวพิมพ์เล็กใหญ่)" },
				type: { type: "string", enum: ["output", "info", "warning", "error"], description: "กรองตามประเภท" },
				clear: { type: "boolean", description: "ล้าง log ทั้งหมดหลังอ่าน" },
			},
		},
	},
	{
		name: "roblox_get_tree",
		description:
			"ดูโครงสร้าง Instance ในเกม (เหมือนหน้าต่าง Explorer) พร้อม ClassName, Value ของ ValueBase และ Attributes. " +
			"path คั่นด้วย . หรือ / เช่น 'Workspace.__THINGS', 'Players.LocalPlayer.PlayerGui', 'ReplicatedStorage/Network'",
		inputSchema: {
			type: "object",
			properties: {
				path: { type: "string", description: "ค่าเริ่มต้น 'game'" },
				depth: { type: "number", description: "ลึกกี่ชั้น (ค่าเริ่มต้น 2)" },
				maxChildren: { type: "number", description: "แสดงลูกสูงสุดกี่ตัวต่อ node (ค่าเริ่มต้น 50)" },
				filter: { type: "string", description: "แสดงเฉพาะ node ที่ชื่อมีคำนี้ (ยังไล่ลงไปในลูกตามปกติ)" },
				clientId: clientIdProp,
			},
		},
	},
	{
		name: "roblox_inspect",
		description:
			"ดูรายละเอียด Instance เดียว: property ที่อ่านได้ (Position, CFrame, Size, Text, Value, Health ฯลฯ), Attributes, Tags, ลูกโดยสรุป. " +
			"ถ้าเป็น ModuleScript ใส่ require=true เพื่อดูค่าที่ module คืนมา (เช่นข้อมูลใน ReplicatedStorage.Library)",
		inputSchema: {
			type: "object",
			properties: {
				path: { type: "string", description: "เช่น 'Players.LocalPlayer.Character.HumanoidRootPart'" },
				require: { type: "boolean", description: "require ModuleScript แล้วแสดงผล" },
				clientId: clientIdProp,
			},
			required: ["path"],
		},
	},
];

function text(t, isError = false) {
	return { content: [{ type: "text", text: t }], isError };
}

function formatResult(r) {
	const parts = [];
	if (r.output && r.output.length) parts.push("--- output ---\n" + r.output.join("\n"));
	if (r.ok) {
		if (r.returns && r.returns.length) parts.push("--- return ---\n" + r.returns.join("\n"));
		if (r.stillRunning) parts.push(`(ยังรันอยู่เบื้องหลังหลังจากผ่าน ${r.elapsed ?? "?"} วินาที — ดูต่อด้วย roblox_get_logs)`);
		if (!parts.length) parts.push("(รันสำเร็จ ไม่มี output)");
		return text(parts.join("\n\n"));
	}
	parts.push("--- error ---\n" + (r.error || "unknown error"));
	return text(parts.join("\n\n"), true);
}

async function callTool(name, args = {}) {
	switch (name) {
		case "roblox_pair": {
			if (args.unpair) {
				sessions = {};
				saveSessions();
				newPairCode();
				return text(`ยกเลิกการจับคู่ทั้งหมดแล้ว รหัสใหม่: ${pairCode}`);
			}
			const live = liveClients().map(([id]) => id);
			return text(
				`รหัสจับคู่: ${pairCode}\n\n` +
				`วิธีใช้: รันในเกม (executor)\n` +
				`loadstring(game:HttpGet("https://raw.githubusercontent.com/TaeBanna/ps99/main/MCP_Bridge.lua"))()\n` +
				`แล้วพิมพ์รหัสในหน้าต่าง Claude Bridge (มือถือต้องอยู่ Wi-Fi เดียวกับ PC)\n\n` +
				`IP ของ PC (ถ้าสแกนหาไม่เจอ ให้พิมพ์ในช่อง IP): ${lanIps().join(", ") || "-"}\n` +
				`เกมที่เชื่อมต่ออยู่ตอนนี้: ${live.length ? live.join(", ") : "ไม่มี"}`
			);
		}
		case "roblox_status": {
			const now = Date.now();
			const rows = [...clients.entries()].map(([id, c]) => ({
				clientId: id,
				connected: now - c.lastSeen < CLIENT_STALE_MS,
				lastSeenSecAgo: c.lastSeen ? Math.round((now - c.lastSeen) / 1000) : null,
				...c.info,
			}));
			return text(JSON.stringify({
				pairCode, pcIps: lanIps(), port: PORT, pairedDevices: Object.keys(sessions).length,
				root: BASE_DIR, latestLogSeq: logSeq, clients: rows,
			}, null, 2));
		}
		case "roblox_execute": {
			if (typeof args.code !== "string") return text("ต้องใส่ code", true);
			const timeout = Number(args.timeout) > 0 ? Number(args.timeout) : 15;
			const r = await sendCommand(pickClient(args.clientId), "exec", { code: args.code, chunkName: "mcp_exec" }, timeout);
			return formatResult(r);
		}
		case "roblox_run_file": {
			const full = path.resolve(BASE_DIR, String(args.path || ""));
			if (!full.startsWith(BASE_DIR + path.sep)) return text("path ต้องอยู่ในโฟลเดอร์ " + BASE_DIR, true);
			let code;
			try { code = fs.readFileSync(full, "utf8"); } catch (e) { return text("อ่านไฟล์ไม่ได้: " + e.message, true); }
			const timeout = Number(args.timeout) > 0 ? Number(args.timeout) : 5;
			const r = await sendCommand(pickClient(args.clientId), "exec", { code, chunkName: path.basename(full) }, timeout);
			return formatResult(r);
		}
		case "roblox_get_logs": {
			const since = Number(args.since) || 0;
			const limit = Number(args.limit) > 0 ? Number(args.limit) : 200;
			const f = args.filter ? String(args.filter).toLowerCase() : null;
			let out = logs.filter((l) => l.seq > since && (!args.type || l.type === args.type) && (!f || l.msg.toLowerCase().includes(f)));
			const total = out.length;
			out = out.slice(-limit);
			if (args.clear) logs = [];
			const lines = out.map((l) => {
				const d = new Date(l.t * 1000).toTimeString().slice(0, 8);
				const tag = l.type === "output" ? "" : `[${l.type.toUpperCase()}] `;
				return `#${l.seq} ${d} ${tag}${l.msg}`;
			});
			const header = `latestSeq=${logSeq}  แสดง ${out.length}/${total} บรรทัด`;
			return text(header + (lines.length ? "\n" + lines.join("\n") : "\n(ไม่มี log)"));
		}
		case "roblox_get_tree": {
			const r = await sendCommand(pickClient(args.clientId), "tree", {
				path: args.path || "game",
				depth: args.depth !== undefined && Number(args.depth) >= 0 ? Number(args.depth) : 2,
				maxChildren: Number(args.maxChildren) > 0 ? Number(args.maxChildren) : 50,
				filter: args.filter || null,
			}, 20);
			return r.ok ? text(r.tree || "") : text(r.error || "error", true);
		}
		case "roblox_inspect": {
			const r = await sendCommand(pickClient(args.clientId), "inspect", { path: args.path, require: !!args.require }, 20);
			return r.ok ? text(r.text || "") : text(r.error || "error", true);
		}
		default:
			return text("ไม่รู้จัก tool: " + name, true);
	}
}

// ------------------------------------------------------------------
// MCP stdio (JSON-RPC 2.0, ทีละบรรทัด)
// ------------------------------------------------------------------
function send(msg) {
	process.stdout.write(JSON.stringify(msg) + "\n");
}

async function handle(msg) {
	const { id, method, params } = msg;
	const isRequest = id !== undefined && id !== null;
	try {
		let result;
		switch (method) {
			case "initialize":
				result = {
					protocolVersion: (params && params.protocolVersion) || "2025-06-18",
					capabilities: { tools: {} },
					serverInfo: { name: "roblox-bridge", version: "2.0.0" },
					instructions:
						"เครื่องมือควบคุมเกม Roblox ของผู้ใช้แบบสด. ถ้าผู้ใช้ขอรหัสเชื่อมต่อ ใช้ roblox_pair. " +
						"roblox_execute รันโค้ดในเกม, roblox_run_file รันไฟล์ในเครื่อง, roblox_get_logs อ่าน console, " +
						"roblox_get_tree / roblox_inspect สำรวจ Instance. เช็กการเชื่อมต่อด้วย roblox_status",
				};
				break;
			case "ping":
				result = {};
				break;
			case "tools/list":
				result = { tools: TOOLS };
				break;
			case "tools/call":
				try {
					result = await callTool(params.name, params.arguments || {});
				} catch (e) {
					result = text(String(e && e.message ? e.message : e), true);
				}
				break;
			case "resources/list":
				result = { resources: [] };
				break;
			case "prompts/list":
				result = { prompts: [] };
				break;
			default:
				if (isRequest) send({ jsonrpc: "2.0", id, error: { code: -32601, message: "Method not found: " + method } });
				return;
		}
		if (isRequest) send({ jsonrpc: "2.0", id, result });
	} catch (e) {
		if (isRequest) send({ jsonrpc: "2.0", id, error: { code: -32603, message: String(e && e.message ? e.message : e) } });
	}
}

let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
	buf += chunk;
	let i;
	while ((i = buf.indexOf("\n")) >= 0) {
		const line = buf.slice(0, i).trim();
		buf = buf.slice(i + 1);
		if (!line) continue;
		let msg;
		try { msg = JSON.parse(line); } catch { continue; }
		if (Array.isArray(msg)) msg.forEach(handle); else handle(msg);
	}
});
process.stdin.on("end", () => process.exit(0));
