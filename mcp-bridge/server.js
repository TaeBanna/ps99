#!/usr/bin/env node
// Claude Bridge — MCP server (ไม่ต้องลง npm package อะไรเลย ใช้แค่ Node 18+)
//
//   Claude Code ──MCP (stdio)──> server.js ──https──> Supabase relay <──https── MCP_Bridge.lua (ในเกม)
//
// ทั้ง PC และเกมเป็นฝ่ายต่อออกไปหา relay -> ใช้ต่าง Wi-Fi / เน็ตมือถือได้
//
// ความปลอดภัย:
// - ไม่มี API key ใดๆ ในไฟล์นี้หรือใน repo
// - owner secret สร้างบนเครื่องนี้ตอน setup ครั้งแรก เก็บที่ ~/.claude-roblox-bridge.json (นอก repo)
//   relay เก็บแค่ hash
// - เกมได้ token จากการจับคู่ด้วยรหัส 6 หลัก (ใช้ได้ครั้งเดียว หมดอายุ 10 นาที ผิด 5 ครั้งยกเลิก)
//
// stdout = ช่อง MCP ห้ามเขียนอย่างอื่นลงไป (ใช้ log() ที่เขียนลง stderr)

"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");

const RELAY_URL = process.env.ROBLOX_BRIDGE_RELAY || "https://iutqukkvewkyzwpwyjee.supabase.co/functions/v1/claude-bridge";
const CONFIG_FILE = path.join(os.homedir(), ".claude-roblox-bridge.json");
const BASE_DIR = path.resolve(process.env.ROBLOX_MCP_ROOT || path.join(__dirname, ".."));
const SCRIPT_URL = "https://raw.githubusercontent.com/TaeBanna/ps99/main/MCP_Bridge.lua";
const CLIENT_STALE_MS = 45000;
const MAX_LOGS = 5000;

const log = (...a) => process.stderr.write("[claude-bridge] " + a.join(" ") + "\n");

// ------------------------------------------------------------------
// config (owner secret) — อยู่ในเครื่องเท่านั้น
// ------------------------------------------------------------------
let config = {};
try { config = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8")) || {}; } catch { config = {}; }
function saveConfig() {
	fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2), { mode: 0o600 });
}

async function relay(action, body = {}, timeoutMs = 35000) {
	const ctrl = new AbortController();
	const t = setTimeout(() => ctrl.abort(), timeoutMs);
	try {
		const res = await fetch(RELAY_URL, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ action, ...body }),
			signal: ctrl.signal,
		});
		let data = {};
		try { data = await res.json(); } catch {}
		return { status: res.status, data };
	} catch (e) {
		return { status: 0, data: { error: "ต่อ relay ไม่ได้: " + (e.name === "AbortError" ? "timeout" : e.message) } };
	} finally {
		clearTimeout(t);
	}
}

// ------------------------------------------------------------------
// state
// ------------------------------------------------------------------
let clients = [];          // [{ client_id, info, last_seen }]
let pairedDevices = 0;
let relayError = null;
const pending = new Map(); // cmdId -> { resolve, timer }
let logs = [];             // { seq, t, clientId, type, msg }
let logSeq = 0;
let cmdSeq = 0;
let lastPaired = null;

function addLogs(clientId, entries) {
	for (const e of entries || []) {
		logs.push({ seq: ++logSeq, t: e.t || Date.now() / 1000, clientId, type: e.type || "output", msg: String(e.msg ?? "") });
	}
	if (logs.length > MAX_LOGS) logs = logs.slice(-MAX_LOGS);
}

function liveClients() {
	const now = Date.now();
	return clients.filter((c) => now - Date.parse(c.last_seen) < CLIENT_STALE_MS)
		.sort((a, b) => Date.parse(b.last_seen) - Date.parse(a.last_seen));
}

function needSetup() {
	return !config.ownerSecret;
}

const SETUP_HELP =
	"ยังไม่ได้ตั้งค่า bridge บนเครื่องนี้ — ให้ผู้ใช้บอก setup code (ได้จากตอนติดตั้ง รูปแบบ XXXXXX-XXXXXX-XXXXXX-XXXXXX) แล้วเรียก roblox_setup";

function pickClient(clientId) {
	if (needSetup()) throw new Error(SETUP_HELP);
	const live = liveClients();
	if (clientId) {
		if (!live.find((c) => c.client_id === clientId)) throw new Error(`client "${clientId}" ไม่ได้เชื่อมต่ออยู่`);
		return clientId;
	}
	if (!live.length) {
		throw new Error(
			"ยังไม่มีเกมเชื่อมต่อ" + (relayError ? ` (relay: ${relayError})` : "") +
			" — ให้ผู้ใช้รัน MCP_Bridge.lua ในเกม ถ้ายังไม่เคยจับคู่ ใช้ roblox_pair ขอรหัส 6 หลัก"
		);
	}
	return live[0].client_id;
}

async function sendCommand(clientId, type, payload, timeoutSec) {
	const id = `${Date.now().toString(36)}-${++cmdSeq}`;
	const waitMs = (timeoutSec + 20) * 1000; // เผื่อเวลา network
	const result = new Promise((resolve) => {
		const timer = setTimeout(() => {
			pending.delete(id);
			resolve({ ok: false, error: `ไม่ได้รับผลตอบกลับใน ${timeoutSec + 20} วินาที (เกมหลุด หรือค้าง?)` });
		}, waitMs);
		pending.set(id, { resolve, timer });
	});
	const r = await relay("pc_send", { owner: config.ownerSecret, to: clientId, body: { id, type, timeout: timeoutSec, ...payload } });
	if (r.status !== 200) {
		const p = pending.get(id);
		if (p) { clearTimeout(p.timer); pending.delete(id); }
		return { ok: false, error: "ส่งคำสั่งไม่สำเร็จ: " + (r.data.error || r.status) };
	}
	return result;
}

// ------------------------------------------------------------------
// poll relay ตลอดเวลา (รับผล / log / สถานะเกม)
// ------------------------------------------------------------------
async function pollLoop() {
	let backoff = 1000;
	for (;;) {
		if (needSetup()) { await new Promise((r) => setTimeout(r, 500)); continue; }
		const r = await relay("pc_poll", { owner: config.ownerSecret, wait: 25000 }, 40000);
		if (r.status === 200) {
			relayError = null;
			backoff = 1000;
			clients = r.data.clients || [];
			pairedDevices = r.data.pairedDevices || 0;
			for (const m of r.data.messages || []) {
				if (m.kind === "result") {
					const p = pending.get(String(m.id));
					if (p) {
						clearTimeout(p.timer);
						pending.delete(String(m.id));
						p.resolve(m);
					}
				} else if (m.kind === "logs") {
					addLogs(m.clientId, m.entries);
				} else if (m.kind === "paired") {
					lastPaired = { player: m.player, at: new Date() };
					log(`จับคู่สำเร็จกับ ${m.player}`);
				}
			}
		} else {
			relayError = r.data.error || `HTTP ${r.status}`;
			if (r.status === 401) relayError = "owner secret ไม่ถูกต้อง (ลบ ~/.claude-roblox-bridge.json แล้ว setup ใหม่)";
			log("relay error: " + relayError);
			await new Promise((res) => setTimeout(res, backoff));
			backoff = Math.min(backoff * 2, 15000);
		}
	}
}
pollLoop();

// ------------------------------------------------------------------
// MCP tools
// ------------------------------------------------------------------
const clientIdProp = { type: "string", description: "เลือกเกม (ดูจาก roblox_status) ไม่ใส่ = ตัวล่าสุด" };

const TOOLS = [
	{
		name: "roblox_setup",
		description: "ตั้งค่าครั้งแรกบนเครื่องนี้ด้วย setup code (ใช้ได้ครั้งเดียว) — สร้างกุญแจเจ้าของเก็บไว้ในเครื่อง",
		inputSchema: { type: "object", properties: { setupCode: { type: "string" } }, required: ["setupCode"] },
	},
	{
		name: "roblox_pair",
		description:
			"ขอรหัสจับคู่ 6 หลัก (หมดอายุ 10 นาที ใช้ได้ครั้งเดียว) สำหรับเชื่อมเกมเข้ากับ Claude — ใช้เมื่อผู้ใช้ขอรหัส/อยากเชื่อมต่อเกม. " +
			"unpair=true ยกเลิกการจับคู่ทุกเครื่อง",
		inputSchema: { type: "object", properties: { unpair: { type: "boolean" } } },
	},
	{
		name: "roblox_status",
		description: "ดูว่าเกมเชื่อมต่ออยู่ไหม พร้อมข้อมูลเกม (ผู้เล่น, PlaceId, JobId, executor, device)",
		inputSchema: { type: "object", properties: {} },
	},
	{
		name: "roblox_execute",
		description:
			"รันโค้ด Luau ในเกม Roblox ผ่าน executor (เหมือนผู้ใช้กดรันเอง มี getgenv, hookmetamethod ฯลฯ ตาม executor). " +
			"คืนค่า: ข้อความจาก print/warn ระหว่างรัน, ค่าที่ return (แปลงเป็นข้อความอ่านง่าย รวมถึง table/Instance), หรือ error + traceback. " +
			"ตัวแปร global (ไม่ใช้ local) อยู่ต่อข้ามการรันแต่ละครั้ง. มีฟังก์ชันช่วย inspect(value). " +
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
			"อ่านไฟล์ .lua จากเครื่อง (path เทียบกับโฟลเดอร์ repo) แล้วส่งไปรันในเกมทันที — ทดสอบโค้ดที่เพิ่งแก้โดยไม่ต้อง push ขึ้น GitHub. " +
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
			"อ่าน console log ของเกม (print, warn, error จากทุกสคริปต์ รวมถึงของเกมเอง). ใช้ since = seq ล่าสุดที่เคยอ่าน เพื่อดูเฉพาะ log ใหม่. " +
			"log ถูกส่งมาเฉพาะตอน Claude เปิดอยู่ (ก่อนหน้านั้นเกมเก็บไว้ให้ได้ 2000 บรรทัด)",
		inputSchema: {
			type: "object",
			properties: {
				since: { type: "number" },
				limit: { type: "number", description: "ค่าเริ่มต้น 200 (เอาบรรทัดท้ายสุด)" },
				filter: { type: "string", description: "กรองเฉพาะบรรทัดที่มีคำนี้" },
				type: { type: "string", enum: ["output", "info", "warning", "error"] },
				clear: { type: "boolean" },
			},
		},
	},
	{
		name: "roblox_get_tree",
		description:
			"ดูโครงสร้าง Instance ในเกม (เหมือน Explorer) พร้อม ClassName, Value และ Attributes. " +
			"path คั่นด้วย . หรือ / เช่น 'Workspace.__THINGS', 'Players.LocalPlayer.PlayerGui'",
		inputSchema: {
			type: "object",
			properties: {
				path: { type: "string", description: "ค่าเริ่มต้น 'game'" },
				depth: { type: "number", description: "ค่าเริ่มต้น 2" },
				maxChildren: { type: "number", description: "ค่าเริ่มต้น 50" },
				filter: { type: "string" },
				clientId: clientIdProp,
			},
		},
	},
	{
		name: "roblox_inspect",
		description:
			"ดูรายละเอียด Instance เดียว: properties, Attributes, Tags, ลูกโดยสรุป. ModuleScript ใส่ require=true เพื่อดูค่าที่ module คืนมา",
		inputSchema: {
			type: "object",
			properties: { path: { type: "string" }, require: { type: "boolean" }, clientId: clientIdProp },
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
	if (name !== "roblox_setup" && needSetup()) return text(SETUP_HELP, true);
	switch (name) {
		case "roblox_setup": {
			if (config.ownerSecret) return text("เครื่องนี้ตั้งค่าไว้แล้ว ใช้ roblox_pair ได้เลย");
			const ownerSecret = crypto.randomBytes(32).toString("hex");
			const r = await relay("setup", { setupCode: String(args.setupCode || "").trim(), ownerSecret });
			if (r.status !== 200) return text("setup ไม่สำเร็จ: " + (r.data.error || r.status), true);
			config.ownerSecret = ownerSecret;
			saveConfig();
			return text(`ตั้งค่าสำเร็จ กุญแจเจ้าของถูกเก็บไว้ที่ ${CONFIG_FILE} (อย่าแชร์ไฟล์นี้) — ต่อไปใช้ roblox_pair ขอรหัสเชื่อมเกมได้เลย`);
		}
		case "roblox_pair": {
			if (args.unpair) {
				const r = await relay("pc_unpair", { owner: config.ownerSecret });
				return r.status === 200 ? text("ยกเลิกการจับคู่ทุกเครื่องแล้ว") : text("ไม่สำเร็จ: " + (r.data.error || r.status), true);
			}
			const r = await relay("pc_newcode", { owner: config.ownerSecret });
			if (r.status !== 200) return text("ขอรหัสไม่สำเร็จ: " + (r.data.error || r.status), true);
			const live = liveClients().map((c) => c.client_id);
			return text(
				`รหัสจับคู่: ${r.data.code}   (หมดอายุใน ${Math.round(r.data.expiresInSec / 60)} นาที ใช้ได้ครั้งเดียว)\n\n` +
				`วิธีใช้: รันในเกม\nloadstring(game:HttpGet("${SCRIPT_URL}"))()\nแล้วพิมพ์รหัสในหน้าต่าง Claude Bridge\n\n` +
				`เกมที่เชื่อมต่ออยู่ตอนนี้: ${live.length ? live.join(", ") : "ไม่มี"}`
			);
		}
		case "roblox_status": {
			const now = Date.now();
			return text(JSON.stringify({
				relay: relayError ? "error: " + relayError : "ok",
				pairedDevices,
				lastPaired,
				clients: clients.map((c) => ({
					clientId: c.client_id,
					connected: now - Date.parse(c.last_seen) < CLIENT_STALE_MS,
					lastSeenSecAgo: Math.round((now - Date.parse(c.last_seen)) / 1000),
					...(c.info || {}),
				})),
				latestLogSeq: logSeq,
				root: BASE_DIR,
			}, null, 2));
		}
		case "roblox_execute": {
			if (typeof args.code !== "string") return text("ต้องใส่ code", true);
			const timeout = Number(args.timeout) > 0 ? Number(args.timeout) : 15;
			return formatResult(await sendCommand(pickClient(args.clientId), "exec", { code: args.code, chunkName: "mcp_exec" }, timeout));
		}
		case "roblox_run_file": {
			const full = path.resolve(BASE_DIR, String(args.path || ""));
			if (!full.startsWith(BASE_DIR + path.sep)) return text("path ต้องอยู่ในโฟลเดอร์ " + BASE_DIR, true);
			let code;
			try { code = fs.readFileSync(full, "utf8"); } catch (e) { return text("อ่านไฟล์ไม่ได้: " + e.message, true); }
			const timeout = Number(args.timeout) > 0 ? Number(args.timeout) : 5;
			return formatResult(await sendCommand(pickClient(args.clientId), "exec", { code, chunkName: path.basename(full) }, timeout));
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
			return text(`latestSeq=${logSeq}  แสดง ${out.length}/${total} บรรทัด` + (lines.length ? "\n" + lines.join("\n") : "\n(ไม่มี log)"));
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
					serverInfo: { name: "roblox-bridge", version: "3.0.0" },
					instructions:
						"เครื่องมือควบคุมเกม Roblox ของผู้ใช้แบบสดผ่านอินเทอร์เน็ต. ครั้งแรกต้อง roblox_setup ด้วย setup code. " +
						"ผู้ใช้ขอรหัสเชื่อมต่อ -> roblox_pair. roblox_execute รันโค้ดในเกม, roblox_run_file รันไฟล์ในเครื่อง, " +
						"roblox_get_logs อ่าน console, roblox_get_tree / roblox_inspect สำรวจ Instance, roblox_status เช็กการเชื่อมต่อ",
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
