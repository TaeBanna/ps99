# Claude Bridge (Roblox ↔ Claude)

ให้ Claude ควบคุมเกมได้เหมือนคุณกดรันเอง: รันสคริปต์, อ่าน console, ดูค่าทุกอย่างในเกม
แล้วแก้โค้ด → รันใหม่ → ดู error เองจนกว่าจะใช้ได้

**ใช้ผ่านอินเทอร์เน็ต** — มือถือกับ PC อยู่คนละ Wi-Fi หรือใช้เน็ตมือถือก็ได้
เชื่อมต่อด้วยรหัส 6 หลักครั้งเดียว ครั้งต่อไปต่อเองอัตโนมัติ

```
มือถือ (MCP_Bridge.lua) ──https──► Supabase relay ◄──https── PC (Claude Code + server.js)
```

## ติดตั้งบน PC (ครั้งเดียว)

1. ลง [Node.js](https://nodejs.org) (เวอร์ชัน 18 ขึ้นไป)
2. clone repo นี้ลงเครื่อง เช่น `C:\ps99`
3. เพิ่ม MCP ให้ Claude Code
   ```
   claude mcp remove roblox
   claude mcp add roblox -- node C:\ps99\mcp-bridge\server.js
   ```
4. เปิด `claude` แล้วพิมพ์: **"ตั้งค่า roblox bridge ด้วย setup code XXXXXX-XXXXXX-XXXXXX-XXXXXX"**
   (setup code ได้จากตอนติดตั้ง ใช้ได้ครั้งเดียว)
   → เครื่องจะสร้างกุญแจเจ้าของเก็บไว้ที่ `~/.claude-roblox-bridge.json` (อย่าแชร์ไฟล์นี้)

## เชื่อมเกม

1. ใน Claude Code พิมพ์: **"ขอรหัสเชื่อมต่อ roblox"** → ได้รหัส 6 หลัก (หมดอายุ 10 นาที)
2. ในเกมรัน
   ```lua
   loadstring(game:HttpGet("https://raw.githubusercontent.com/TaeBanna/ps99/main/MCP_Bridge.lua"))()
   ```
3. พิมพ์รหัสในหน้าต่าง **Claude Bridge** → กด **เชื่อมต่อ** → จุดเขียว = เสร็จ

ครั้งต่อไปแค่รันสคริปต์ มันต่อเองอัตโนมัติ ย้ายเซิร์ฟ/รีจอยก็ต่อเอง

## ความปลอดภัย

- **ไม่มี API key หรือข้อมูลลับใน repo** — `MCP_Bridge.lua` และ `server.js` มีแค่ที่อยู่ของ relay
  ซึ่งรู้ไปก็ทำอะไรไม่ได้ถ้าไม่มีกุญแจ
- กุญแจเจ้าของสร้างบน PC ของคุณเอง ไม่เคยผ่านแชทหรือ GitHub — relay เก็บแค่ hash (SHA-256)
- token ของเกมได้จากการจับคู่เท่านั้น เก็บในเครื่องที่รันเกม relay เก็บแค่ hash
- รหัส 6 หลักออกได้เฉพาะ PC ที่มีกุญแจเจ้าของ, หมดอายุ 10 นาที, ใช้ได้ครั้งเดียว, ผิด 5 ครั้งรหัสถูกยกเลิก
- ตารางใน Supabase เปิด RLS และไม่มี policy → เข้าผ่าน API ปกติไม่ได้เลย ใช้ได้เฉพาะ Edge Function
- ข้อความในตัวกลางถูกลบทันทีที่ส่งถึง (ที่ค้างเกิน 15 นาทีถูกลบอัตโนมัติ)
- ยกเลิกการจับคู่ทุกเครื่อง: บอก Claude "ยกเลิกการจับคู่ roblox ทั้งหมด" หรือกดปุ่มในเกม

## สิ่งที่ Claude ทำได้

| tool | ทำอะไร |
|---|---|
| `roblox_setup` | ตั้งค่าเครื่องครั้งแรกด้วย setup code |
| `roblox_pair` | ขอรหัสจับคู่ / ยกเลิกการจับคู่ |
| `roblox_status` | ดูว่าเกมเชื่อมต่ออยู่ไหม (ผู้เล่น, PlaceId, JobId, executor, มือถือ/PC) |
| `roblox_execute` | รันโค้ด Luau อะไรก็ได้ในเกม ได้ผล print / return / error+traceback กลับมา |
| `roblox_run_file` | รันไฟล์ `.lua` ในเครื่องตรงๆ (ไม่ต้อง push ก่อน) |
| `roblox_get_logs` | อ่าน console (print/warn/error ทุกสคริปต์) |
| `roblox_get_tree` | ดู Instance แบบ Explorer พร้อม Value และ Attributes |
| `roblox_inspect` | ดู property / attribute / tag และ `require` ModuleScript |

## ใช้กับ ChatGPT / Codex

ตัวเดียวกันใช้ได้หลาย AI พร้อมกัน (เกมจับคู่ครั้งเดียว)

| ใช้กับ | วิธีต่อ |
|---|---|
| Claude Code / Claude CLI | `claude mcp add roblox --scope user -- node C:\ps99\mcp-bridge\server.js` |
| Codex (CLI / VS Code / แอป Codex) | `codex mcp add roblox -- node C:\ps99\mcp-bridge\server.js` |
| ChatGPT (เว็บ/แอป) | remote MCP ผ่าน relay — ดูด้านล่าง |

**ChatGPT (เว็บ/แอป)** ต่อกับ MCP บนเครื่องเราไม่ได้ ต้องเป็น MCP บนอินเทอร์เน็ต (HTTPS) จึงใช้ endpoint ใน relay โดยตรง ไม่ต้องเปิด PC ค้าง:

1. บน PC รัน `node mcp-bridge/chatgpt-link.js` → ได้ URL ส่วนตัว (มีกุญแจลับในลิงก์ **ห้ามแชร์**)
2. ChatGPT → Settings → Apps & Connectors → Advanced settings → เปิด **Developer mode**
3. Create connector → ใส่ URL, Authentication = **No authentication**, ติ๊ก "I trust this application"
4. ในแชท เลือก Developer mode แล้วเปิด connector นี้ → สั่งงานได้เลย (ChatGPT จะถามยืนยันก่อนรันโค้ดทุกครั้ง)

- รันสคริปต์ซ้ำ = ได้ URL ใหม่ ตัวเก่าใช้ไม่ได้ทันที / ปิดสิทธิ์: `node mcp-bridge/chatgpt-link.js --revoke`
- tools ฝั่ง ChatGPT: `roblox_status`, `roblox_execute`, `roblox_get_logs`, `roblox_get_tree`, `roblox_inspect`
  (ไม่มี `roblox_run_file` เพราะ ChatGPT เข้าไฟล์ในเครื่องไม่ได้ — วางโค้ดในแชทแทน)
- Developer mode เป็น beta ของ OpenAI และขึ้นกับแพ็กเกจที่ใช้

## ความเร็ว

วัดจากเกมจริง (MuMu + Delta, ไทย ↔ relay สิงคโปร์): ส่งโค้ด → ได้ผลกลับ **~0.4–0.6 วินาที** ต่อคำสั่ง
- PC ส่งคำสั่งและรอผลใน request เดียว (`pc_exec`), relay เช็กข้อความทุก 50ms, cache การยืนยันตัวตน
- ถ้าไม่มี AI ไหนเปิดอยู่ เกมจะเช็กห่างๆ (~15 วิ) เพื่อประหยัดโควตา คำสั่งแรกหลังเปิดอาจช้ากว่าปกติ

## Supabase (relay)

- project: `claude-roblox-bridge` (Singapore) แยกจากแอปอื่น
- โค้ด Edge Function: [`supabase/claude-bridge/index.ts`](supabase/claude-bridge/index.ts) (deploy ด้วย verify_jwt = false เพราะยืนยันตัวตนเอง)
- แพ็กฟรี: 500,000 ครั้ง/เดือน — เกมเช็กห่างๆ ตอน Claude ปิดอยู่ และส่ง log เฉพาะตอน Claude เปิด
- project ฟรีถูกพักถ้าไม่มีการใช้งาน 7 วัน → เข้า dashboard กด Resume

## ปัญหาที่พบบ่อย

- **"รอ Claude บน PC เปิด"**: เปิด `claude` บน PC (server ทำงานเฉพาะตอน Claude เปิด)
- **ต่อเน็ตไม่ได้**: executor ต้องมี `request`/`http_request` และอนุญาต https
- **ลืม/ทำกุญแจเจ้าของหาย**: ต้องรีเซ็ตใน Supabase แล้วขอ setup code ใหม่
- หยุด bridge ในเกม: `getgenv().MCPBridgeStop()`
