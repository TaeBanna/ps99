# Roblox ↔ Claude MCP Bridge

ให้ Claude รันโค้ดในเกม, อ่าน console, ดูโครงสร้าง Instance และรันไฟล์ที่เพิ่งแก้ได้เอง
ไม่ต้องก๊อป log ไปวางแล้วรันใหม่เองอีกต่อไป

```
Claude Code / Claude Desktop  ──MCP (stdio)──  mcp-bridge/server.js  ──HTTP 127.0.0.1:8765──  MCP_Bridge.lua (executor)
```

## ติดตั้ง (ทำครั้งเดียว)

1. ลง [Node.js](https://nodejs.org) เวอร์ชัน 18 ขึ้นไป (ไม่ต้อง `npm install` อะไรเพิ่ม)
2. clone repo นี้ลงเครื่อง เช่น `C:\ps99`
3. เพิ่ม MCP server ให้ Claude

   **Claude Code** (รันในโฟลเดอร์ repo):
   ```
   claude mcp add roblox -- node C:\ps99\mcp-bridge\server.js
   ```

   **Claude Desktop**: Settings → Developer → Edit Config แล้วใส่
   ```json
   {
     "mcpServers": {
       "roblox": { "command": "node", "args": ["C:\\ps99\\mcp-bridge\\server.js"] }
     }
   }
   ```
   แล้วปิด-เปิด Claude Desktop ใหม่

## ใช้งาน

1. เปิด Claude (server จะเริ่มเองอัตโนมัติ)
2. เข้าเกม แล้วรันใน executor:
   ```lua
   loadstring(game:HttpGet("https://raw.githubusercontent.com/TaeBanna/ps99/main/MCP_Bridge.lua"))()
   ```
   console จะขึ้น `[MCP] เชื่อมต่อกับ Claude bridge แล้ว`
3. สั่ง Claude ได้เลย เช่น
   - "รัน AutoEgg_GUI.lua แล้วดู error ใน console แก้ให้หน่อย"
   - "ดูว่าใน workspace.__THINGS.Plots มีอะไรบ้าง"
   - "เช็กว่า remote CustomEggs_Hatch รับ argument อะไร"

## Tools ที่ Claude ใช้ได้

| tool | ทำอะไร |
|---|---|
| `roblox_status` | ดูว่าเกมเชื่อมต่ออยู่ไหม (ผู้เล่น, PlaceId, JobId, executor) |
| `roblox_execute` | รันโค้ด Luau ในเกม ได้ผล print / return / error+traceback กลับมา |
| `roblox_run_file` | รันไฟล์ `.lua` ในเครื่องตรงๆ (ไม่ต้อง push ขึ้น GitHub ก่อน) |
| `roblox_get_logs` | อ่าน console (print/warn/error จากทุกสคริปต์ รวมของเกมเอง) |
| `roblox_get_tree` | ดู Instance แบบ Explorer พร้อม Value และ Attributes |

## ตั้งค่าเพิ่ม

- เปลี่ยน port: ตั้ง env `ROBLOX_MCP_PORT=9000` ให้ server แล้วใน executor
  `getgenv().MCP_BRIDGE_URL = "http://127.0.0.1:9000"` ก่อน loadstring
- เปลี่ยนโฟลเดอร์ที่ `roblox_run_file` อ่านได้: env `ROBLOX_MCP_ROOT`
- หยุด bridge ในเกม: `getgenv().MCPBridgeStop()`

## ปัญหาที่พบบ่อย

- **ไม่ขึ้นว่าเชื่อมต่อ**: เช็กว่า Claude เปิดอยู่ (server รันอยู่) — เปิด `http://127.0.0.1:8765` ในเบราว์เซอร์ต้องเห็น `{"ok":true,...}`
- **executor บางตัวบล็อก localhost**: ลองเปลี่ยน `MCP_BRIDGE_URL` เป็น `http://localhost:8765`
- **port ชน (EADDRINUSE)**: มี Claude อีกหน้าต่างเปิด server อยู่แล้ว ปิดอันนั้นหรือเปลี่ยน port
- ทุกอย่างคุยกันแค่ในเครื่อง (127.0.0.1) ไม่ได้เปิดออกเน็ต
