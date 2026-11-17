#!/usr/bin/env node
// Roblox <-> Claude MCP bridge (ไม่ต้องลง npm package อะไรเลย ใช้แค่ Node 18+)
//
//   Claude (Claude Code / Claude Desktop)
//        │  MCP ผ่าน stdio
//        ▼
//   server.js  ── HTTP 127.0.0.1:8765 ──  MCP_Bridge.lua (รันใน executor)
//
// - Claude เรียก tool -> server เก็บคำสั่งไว้ในคิว
// - สคริปต์ใน Roblox long-poll มาที่ /poll เอาคำสั่งไปรัน แล้วส่งผลกลับที่ /result
// - console log ใน Roblox ถูกส่งมาที่ /logs เรื่อยๆ ให้ Claude อ่านได้
//
// stdout = ช่อง MCP ห้าม console.log เด็ดขาด (ใช้ log() ที่เขียนลง stderr แทน)

"use strict";
const http = require("http");
const fs = require("fs");
const path = require("path");

const PORT = Number(process.env.ROBLOX_MCP_PORT || 8765);
const HOST = process.env.ROBLOX_MCP_HOST || "127.0.0.1";
const TOKEN = process.env.ROBLOX_MCP_TOKEN || "";
const IS_LOOPBACK = ["127.0.0.1", "localhost", "::1"].includes(HOST);
if (!IS_LOOPBACK && !TOKEN) {
	process.stderr.write("[roblox-mcp] เปิดให้เครื่องอื่นต่อได้ (ROBLOX_MCP_HOST=" + HOST + ") ต้องตั้ง ROBLOX_MCP_TOKEN ด้วย\n");
	process.exit(1);
}

// IP ในวง LAN ของเครื่องนี้ (เอาไปใส่ในมือถือ)
function lanUrls() {
	if (IS_LOOPBACK) return [`http://127.0.0.1:${PORT}`];
	const out = [];
	for (const list of Object.values(require("os").networkInterfaces())) {
		for (const a of list || []) if (a.family === "IPv4" && !a.internal) out.push(`http://${a.address}:${PORT}`);
	}
	return out;
}
const BASE_DIR = path.resolve(process.env.ROBLOX_MCP_ROOT || path.join(__dirname, ".."));
const POLL_HOLD_MS = 10000;     // poll ค้างรอคำสั่งได้นานสุดเท่านี้
const CLIENT_STALE_MS = 30000;  // ไม่ poll มานานเกินนี้ = ถือว่าหลุด
const MAX_LOGS = 5000;

const log = (...a) => process.stderr.write("[roblox-mcp] " + a.join(" ") + "\n");

// ------------------------------------------------------------------
// state
// ------------------------------------------------------------------
const clients = new Map();  // clientId -> { info, lastSeen, queue: [], waiter }
const pending = new Map();  // cmdId -> { resolve, timer, clientId }
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
		throw new Error("ยังไม่มี Roblox client เชื่อมต่อ — รัน MCP_Bridge.lua ใน executor ก่อน (และให้ server นี้รันอยู่ที่ port " + PORT + ")");
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
			resolve({ ok: false, error: `ไม่ได้รับผลตอบกลับใน ${timeoutSec + 10} วินาที (client หลุด หรือเกมค้าง?)` });
		}, waitMs);
		pending.set(id, { resolve, timer, clientId });
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

const httpServer = http.createServer(async (req, res) => {
	const url = new URL(req.url, "http://x");
	if (req.method === "GET" && url.pathname === "/") return json(res, 200, { ok: true, name: "roblox-mcp-bridge" });
	if (req.method !== "POST") return json(res, 404, { error: "not found" });

	const body = await readBody(req);
	if (TOKEN && body.token !== TOKEN) return json(res, 403, { error: "token ไม่ถูกต้อง" });
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
	log(`HTTP server error: ${e.message}` + (e.code === "EADDRINUSE" ? ` (port ${PORT} ถูกใช้อยู่ — มี server ตัวอื่นรันอยู่แล้ว? ตั้ง ROBLOX_MCP_PORT ใหม่ได้)` : ""));
});
httpServer.listen(PORT, HOST, () => log(`listening on ${lanUrls().join(" , ")}  (root: ${BASE_DIR})`));

// ------------------------------------------------------------------
// MCP tools
// ------------------------------------------------------------------
const clientIdProp = { type: "string", description: "เลือก client (ดูจาก roblox_status) ไม่ใส่ = ตัวล่าสุด" };

const TOOLS = [
	{
		name: "roblox_status",
		description: "ดูว่ามี Roblox client ไหนเชื่อมต่ออยู่บ้าง พร้อมข้อมูลเกม (PlaceId, JobId, ชื่อผู้เล่น, executor)",
		inputSchema: { type: "object", properties: {} },
	},
	{
		name: "roblox_execute",
		description:
			"รันโค้ด Luau ในเกม Roblox ผ่าน executor (มี getgenv, hookmetamethod ฯลฯ ตาม executor) " +
			"คืนค่า: ข้อความจาก print/warn ระหว่างรัน, ค่าที่ return, หรือ error + traceback " +
			"ตัวแปร global ที่ตั้ง (ไม่ใช้ local) จะอยู่ต่อข้ามการรันแต่ละครั้ง. " +
			"ถ้าโค้ดรันนานกว่า timeout จะคืนผลเท่าที่มีและปล่อยให้รันต่อเบื้องหลัง (ดู log ต่อได้ด้วย roblox_get_logs)",
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
			"path เช่น 'game.Workspace.__THINGS' หรือ 'ReplicatedStorage.Network'",
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
		case "roblox_status": {
			const now = Date.now();
			const rows = [...clients.entries()].map(([id, c]) => ({
				clientId: id,
				connected: now - c.lastSeen < CLIENT_STALE_MS,
				lastSeenSecAgo: c.lastSeen ? Math.round((now - c.lastSeen) / 1000) : null,
				...c.info,
			}));
			return text(JSON.stringify({ bridgeUrls: lanUrls(), tokenRequired: !!TOKEN, root: BASE_DIR, latestLogSeq: logSeq, clients: rows }, null, 2));
		}
		case "roblox_execute": {
			if (typeof args.code !== "string") return text("ต้องใส่ code", true);
			const timeout = Number(args.timeout) > 0 ? Number(args.timeout) : 15;
			const r = await sendCommand(pickClient(args.clientId), "exec", { code: args.code, chunkName: "mcp_exec" }, timeout);
			return formatResult(r);
		}
		case "roblox_run_file": {
			const full = path.resolve(BASE_DIR, String(args.path || ""));
			if (!full.startsWith(BASE_DIR + path.sep) && full !== BASE_DIR) return text("path ต้องอยู่ในโฟลเดอร์ " + BASE_DIR, true);
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
				depth: Number(args.depth) >= 0 && args.depth !== undefined ? Number(args.depth) : 2,
				maxChildren: Number(args.maxChildren) > 0 ? Number(args.maxChildren) : 50,
				filter: args.filter || null,
			}, 20);
			return r.ok ? text(r.tree || "") : text(r.error || "error", true);
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
					serverInfo: { name: "roblox-bridge", version: "1.0.0" },
					instructions:
						"เครื่องมือสำหรับดีบักสคริปต์ Roblox แบบสด: roblox_execute รันโค้ดในเกม, roblox_run_file รันไฟล์ในเครื่อง, " +
						"roblox_get_logs อ่าน console, roblox_get_tree สำรวจ Instance. เริ่มจาก roblox_status เพื่อเช็กว่าเกมเชื่อมต่ออยู่",
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
