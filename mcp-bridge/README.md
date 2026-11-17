# Claude Bridge (Roblox ↔ Claude)

ให้ Claude ควบคุมเกมได้เหมือนคุณกดรันเอง: รันสคริปต์, อ่าน console, ดูค่าทุกอย่างในเกม
แล้วแก้โค้ด → รันใหม่ → ดู error เองจนกว่าจะใช้ได้

เชื่อมต่อด้วย **รหัส 6 หลัก** อย่างเดียว ไม่ต้องหา IP

## ติดตั้งบน PC (ครั้งเดียว)

1. ลง [Node.js](https://nodejs.org) (เวอร์ชัน 18 ขึ้นไป)
2. clone repo นี้ลงเครื่อง เช่น `C:\ps99`
3. เปิด cmd ในโฟลเดอร์ repo แล้วพิมพ์
   ```
   claude mcp add roblox -- node C:\ps99\mcp-bridge\server.js
   ```
   (ถ้าเคยเพิ่มแบบเก่าไว้ ให้ `claude mcp remove roblox` ก่อน)
4. เปิด `claude` ครั้งแรก ถ้า Windows Firewall เด้งถาม ให้กด **Allow** (Private network)

## เชื่อมต่อ

1. ใน Claude Code พิมพ์: **"ขอรหัสเชื่อมต่อ roblox"** → ได้รหัส 6 หลัก
2. ในเกมรัน
   ```lua
   loadstring(game:HttpGet("https://raw.githubusercontent.com/TaeBanna/ps99/main/MCP_Bridge.lua"))()
   ```
3. พิมพ์รหัสในหน้าต่าง **Claude Bridge** → กด **เชื่อมต่อ** → จุดเขียว = เสร็จ

ครั้งต่อไปแค่รันสคริปต์ มันจะต่อเองอัตโนมัติ (ไม่ต้องใส่รหัส) ย้ายเซิร์ฟ/รีจอยก็ต่อเอง

> มือถือต้องอยู่ **Wi-Fi เดียวกับ PC** สคริปต์จะสแกนหา PC ให้เอง
> ถ้าหาไม่เจอ ให้ถาม Claude ว่า IP ของ PC คืออะไร แล้วใส่ในช่อง "IP ของ PC"

## ความปลอดภัย

- รหัส 6 หลักใช้ได้ **ครั้งเดียว** พอจับคู่แล้วจะเปลี่ยนเป็นกุญแจลับยาว 64 ตัวที่เก็บไว้ในเครื่องคุณกับในเกมเท่านั้น
- ใส่รหัสผิด 5 ครั้ง → รหัสเปลี่ยนใหม่ทันที, โดนเดาบ่อยๆ → พักการจับคู่ 1 นาที (สุ่มเดาไม่มีทางทัน)
- ไม่ผ่านเซิร์ฟเวอร์ภายนอก คุยกันตรงๆ ในวง Wi-Fi บ้านคุณ
- ยกเลิกการจับคู่ทุกเครื่อง: บอก Claude ว่า "ยกเลิกการจับคู่ roblox ทั้งหมด" หรือกดปุ่ม "ยกเลิกการเชื่อมต่อ" ในเกม

## สิ่งที่ Claude ทำได้

| tool | ทำอะไร |
|---|---|
| `roblox_pair` | ขอรหัสจับคู่ / ยกเลิกการจับคู่ |
| `roblox_status` | ดูว่าเกมเชื่อมต่ออยู่ไหม (ผู้เล่น, PlaceId, JobId, executor) |
| `roblox_execute` | รันโค้ด Luau อะไรก็ได้ในเกม ได้ผล print / return / error+traceback กลับมา |
| `roblox_run_file` | รันไฟล์ `.lua` ในเครื่องตรงๆ (เช่น `AutoEgg_GUI.lua` ที่เพิ่งแก้ ไม่ต้อง push ก่อน) |
| `roblox_get_logs` | อ่าน console (print/warn/error จากทุกสคริปต์ รวมของเกมเอง) |
| `roblox_get_tree` | ดู Instance แบบ Explorer พร้อม Value และ Attributes |
| `roblox_inspect` | ดู property / attribute / tag ของ Instance และ `require` ModuleScript มาดูข้อมูลข้างใน |

ตัวอย่างคำสั่ง:
- "รัน AutoEgg_GUI.lua แล้วดู error ใน console แก้ให้จนใช้ได้"
- "ดูว่าใน Workspace.__THINGS.Plots มีอะไร plot ไหนเป็นของเรา"
- "require ReplicatedStorage.Library.Client.Save แล้วดูว่ามีเพ็ทอะไรบ้าง"

## ปัญหาที่พบบ่อย

- **หา PC ไม่เจอ**: เช็กว่าเปิด Claude Code อยู่ (server รันเฉพาะตอน Claude เปิด), อยู่ Wi-Fi เดียวกัน,
  Firewall อนุญาต Node แล้ว — ทดสอบโดยเปิดเบราว์เซอร์มือถือไปที่ `http://<IP ของ PC>:8765` ต้องเห็น `{"ok":true,...}`
- **Wi-Fi สาธารณะ / hotspot บางที่** ไม่ให้เครื่องคุยกันเอง (client isolation) ใช้ไม่ได้
- **port ชน (EADDRINUSE)**: มี Claude อีกหน้าต่างเปิด bridge อยู่แล้ว ใช้หน้าต่างนั้น หรือปิดก่อน
- **เกมค้างตอนสแกน**: executor บางตัวทำ HTTP แบบไม่ yield ให้ใส่ IP ของ PC ในช่อง IP แทนการสแกน
- หยุด bridge ในเกม: `getgenv().MCPBridgeStop()`
