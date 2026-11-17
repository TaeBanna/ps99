// Claude Bridge relay (Supabase Edge Function)
//
// ตัวกลางส่งข้อความระหว่าง PC (server.js) กับเกม (MCP_Bridge.lua) ผ่านอินเทอร์เน็ต
// - ไม่ต้องใช้ API key ใดๆ (verify_jwt = false) ยืนยันตัวตนเอง:
//     PC   = owner secret (สร้างบน PC เก็บในเครื่อง ฝั่งนี้เก็บแค่ hash)
//     เกม  = device token (ได้จากการจับคู่ด้วยรหัส 6 หลัก ฝั่งนี้เก็บแค่ hash)
// - ตารางเปิด RLS ไม่มี policy -> เข้าถึงได้เฉพาะ service role ในฟังก์ชันนี้

import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
	auth: { persistSession: false },
});

const PAIR_TTL_MS = 10 * 60 * 1000; // รหัส 6 หลักหมดอายุใน 10 นาที
const MAX_PAIR_FAILS = 5;           // ผิดเกินนี้ รหัสใช้ไม่ได้อีก
const PC_ONLINE_MS = 60 * 1000;
const enc = new TextEncoder();

async function sha(s: string): Promise<string> {
	const h = await crypto.subtle.digest("SHA-256", enc.encode(s));
	return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function randHex(bytes: number): string {
	const a = new Uint8Array(bytes);
	crypto.getRandomValues(a);
	return [...a].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function sixDigits(): string {
	const a = new Uint32Array(1);
	do crypto.getRandomValues(a); while (a[0] >= 4294000000); // ตัด modulo bias
	return String(a[0] % 1000000).padStart(6, "0");
}
const json = (o: unknown, status = 200) =>
	new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function getOwner() {
	const { data, error } = await db.from("bridge_owner").select("*").eq("id", 1).single();
	if (error) throw error;
	return data;
}
async function isOwner(secret: unknown) {
	if (typeof secret !== "string" || secret.length < 32) return false;
	const o = await getOwner();
	return !!o.secret_hash && o.secret_hash === (await sha(secret));
}
async function isDevice(token: unknown) {
	if (typeof token !== "string" || token.length < 32) return false;
	const { data } = await db.from("bridge_devices").select("token_hash").eq("token_hash", await sha(token)).maybeSingle();
	return !!data;
}

// รอรับข้อความใน channel (long-poll) แล้วลบทิ้งเมื่อส่งออก
async function consume(channel: string, waitMs: number, signal: AbortSignal) {
	const deadline = Date.now() + waitMs;
	for (;;) {
		const { data, error } = await db.from("bridge_messages").select("id, body").eq("channel", channel).order("id").limit(200);
		if (error) throw error;
		if (data.length) {
			if (signal.aborted) return [];
			const ids = data.map((m) => m.id);
			const { data: del, error: e2 } = await db.from("bridge_messages").delete().in("id", ids).select("id, body");
			if (e2) throw e2;
			if (del.length) return del.sort((a, b) => a.id - b.id).map((m) => m.body);
		}
		if (Date.now() >= deadline || signal.aborted) return [];
		await sleep(250);
	}
}

function cleanId(v: unknown) {
	return String(v ?? "default").slice(0, 64);
}

async function cleanup() {
	const old = new Date(Date.now() - 15 * 60 * 1000).toISOString();
	await db.from("bridge_messages").delete().lt("created_at", old);
	const day = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
	await db.from("bridge_clients").delete().lt("last_seen", day);
}

Deno.serve(async (req) => {
	if (req.method === "GET") return json({ ok: true, name: "claude-bridge" });
	if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

	let b: Record<string, any>;
	try {
		b = await req.json();
	} catch {
		return json({ error: "bad json" }, 400);
	}
	if (Math.random() < 0.02) cleanup().catch(() => {});

	try {
		switch (b.action) {
			// ---------------- PC ----------------
			case "setup": { // ครั้งแรกครั้งเดียว: ผูก owner secret ของ PC
				const o = await getOwner();
				if (!o.setup_hash) return json({ error: "ตั้งค่าไปแล้ว (setup code ใช้ได้ครั้งเดียว)" }, 403);
				if (typeof b.setupCode !== "string" || (await sha(b.setupCode)) !== o.setup_hash) {
					return json({ error: "setup code ไม่ถูกต้อง" }, 403);
				}
				if (typeof b.ownerSecret !== "string" || b.ownerSecret.length < 32) return json({ error: "owner secret สั้นเกินไป" }, 400);
				await db.from("bridge_owner").update({ secret_hash: await sha(b.ownerSecret), setup_hash: null }).eq("id", 1);
				return json({ ok: true });
			}
			case "pc_newcode": {
				if (!(await isOwner(b.owner))) return json({ error: "unauthorized" }, 401);
				const code = sixDigits();
				await db.from("bridge_owner").update({
					pair_hash: await sha(code),
					pair_expires: new Date(Date.now() + PAIR_TTL_MS).toISOString(),
					pair_fails: 0,
				}).eq("id", 1);
				return json({ code, expiresInSec: PAIR_TTL_MS / 1000 });
			}
			case "pc_unpair": {
				if (!(await isOwner(b.owner))) return json({ error: "unauthorized" }, 401);
				await db.from("bridge_devices").delete().neq("token_hash", "");
				await db.from("bridge_clients").delete().neq("client_id", "");
				await db.from("bridge_owner").update({ pair_hash: null }).eq("id", 1);
				return json({ ok: true });
			}
			case "pc_send": {
				if (!(await isOwner(b.owner))) return json({ error: "unauthorized" }, 401);
				const { error } = await db.from("bridge_messages").insert({ channel: "game:" + cleanId(b.to), body: b.body ?? {} });
				if (error) throw error;
				return json({ ok: true });
			}
			case "pc_poll": {
				if (!(await isOwner(b.owner))) return json({ error: "unauthorized" }, 401);
				await db.from("bridge_owner").update({ pc_seen: new Date().toISOString() }).eq("id", 1);
				const wait = Math.min(Math.max(Number(b.wait) || 0, 0), 25000);
				const messages = await consume("pc", wait, req.signal);
				const { data: clients } = await db.from("bridge_clients").select("client_id, info, last_seen");
				const { count } = await db.from("bridge_devices").select("token_hash", { count: "exact", head: true });
				return json({ messages, clients: clients ?? [], pairedDevices: count ?? 0 });
			}

			// ---------------- เกม ----------------
			case "game_pair": {
				const o = await getOwner();
				if (!o.pair_hash || !o.pair_expires || Date.parse(o.pair_expires) < Date.now()) {
					return json({ error: "ไม่มีรหัสที่ใช้ได้ ขอรหัสใหม่จาก Claude" }, 403);
				}
				if (typeof b.code !== "string" || (await sha(b.code.trim())) !== o.pair_hash) {
					const fails = (o.pair_fails ?? 0) + 1;
					const dead = fails >= MAX_PAIR_FAILS;
					await db.from("bridge_owner").update(dead ? { pair_fails: fails, pair_hash: null } : { pair_fails: fails }).eq("id", 1);
					return json({ error: dead ? "รหัสผิดหลายครั้ง รหัสถูกยกเลิก ขอรหัสใหม่จาก Claude" : "รหัสไม่ถูกต้อง" }, 403);
				}
				const token = randHex(32);
				const player = String(b.info?.player ?? "unknown").slice(0, 64);
				await db.from("bridge_devices").insert({ token_hash: await sha(token), player });
				await db.from("bridge_owner").update({ pair_hash: null, pair_fails: 0 }).eq("id", 1);
				await db.from("bridge_messages").insert({ channel: "pc", body: { kind: "paired", player } });
				return json({ token });
			}
			case "game_poll": {
				if (!(await isDevice(b.token))) return json({ error: "unpaired" }, 401);
				const clientId = cleanId(b.clientId);
				await db.from("bridge_clients").upsert({ client_id: clientId, info: b.info ?? {}, last_seen: new Date().toISOString() });
				const o = await getOwner();
				const pcOnline = !!o.pc_seen && Date.now() - Date.parse(o.pc_seen) < PC_ONLINE_MS;
				const wait = pcOnline ? Math.min(Math.max(Number(b.wait) || 0, 0), 10000) : 0;
				const commands = await consume("game:" + clientId, wait, req.signal);
				return json({ commands, pcOnline });
			}
			case "game_send": {
				if (!(await isDevice(b.token))) return json({ error: "unpaired" }, 401);
				const clientId = cleanId(b.clientId);
				const list = Array.isArray(b.messages) ? b.messages.slice(0, 50) : [];
				if (list.length) {
					const { error } = await db.from("bridge_messages").insert(
						list.map((m: any) => ({ channel: "pc", body: { ...(m ?? {}), clientId } })),
					);
					if (error) throw error;
				}
				return json({ ok: true });
			}
			default:
				return json({ error: "unknown action" }, 400);
		}
	} catch (e) {
		return json({ error: "server error: " + ((e as Error)?.message ?? String(e)) }, 500);
	}
});
