#!/usr/bin/env node
// Create (or revoke) the private ChatGPT connector URL for the Roblox bridge.
//   node mcp-bridge/chatgpt-link.js           -> prints a new URL (any previous URL stops working)
//   node mcp-bridge/chatgpt-link.js --revoke  -> disables ChatGPT access
// The URL contains a secret key: anyone who has it can run code in your paired game. Never share it.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");

const RELAY_URL = process.env.ROBLOX_BRIDGE_RELAY || "https://nltqfqfjcaebdxfcjvvt.supabase.co/functions/v1/claude-bridge";
const CONFIG_FILE = path.join(os.homedir(), ".claude-roblox-bridge.json");

(async () => {
	let owner;
	try { owner = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8")).ownerSecret; } catch {}
	if (!owner) { console.error(`No owner key in ${CONFIG_FILE}. Set up the bridge first.`); process.exit(1); }
	const revoke = process.argv.includes("--revoke");
	const res = await fetch(RELAY_URL, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ action: "pc_mcpkey", owner, revoke }),
	});
	const data = await res.json().catch(() => ({}));
	if (res.status !== 200) { console.error("Failed:", data.error || res.status); process.exit(1); }
	if (revoke) { console.log("ChatGPT access revoked. The old connector URL no longer works."); return; }
	console.log(`
ChatGPT connector URL (PRIVATE, anyone with it can run code in your game):

  ${RELAY_URL}/mcp/${data.key}

ChatGPT (web): Settings -> Apps & Connectors -> Advanced settings -> turn on Developer mode,
then Create connector: paste the URL above, Authentication = "No authentication", tick "I trust this application".
In a chat, choose Developer mode and enable the connector.

Running this script again creates a new URL and invalidates this one. Revoke: node mcp-bridge/chatgpt-link.js --revoke
`);
})().catch((e) => { console.error("Error:", e.message); process.exit(1); });
