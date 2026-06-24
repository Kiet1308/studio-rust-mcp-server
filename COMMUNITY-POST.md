# Bài đăng group cộng đồng Roblox Studio VN

🎮 **[Open Source] Cho AI tự chơi và test game Roblox của bạn — MCP Server bản nâng cấp**

Chào mọi người, mình vừa hoàn thiện bản fork nâng cấp mạnh của **studio-rust-mcp-server** (repo gốc của Roblox đã ngừng phát triển). Mình thêm nguyên một bộ công cụ để AI (Claude Desktop, Claude Code, Cursor… — bất kỳ MCP client nào) **test game end-to-end như một người chơi thật** ngay trong Studio:

🔹 **Nhìn được game** — chụp màn hình đúng những gì người chơi thấy, crop từng UI riêng, tự đưa camera tới đối tượng cần xem

🔹 **Tương tác như người thật** — click nút UI, click vật thể 3D (ClickDetector), kéo thả/ngắm bằng chuột, giữ phím WASD, nhập text, điều khiển nhân vật đi/nhảy

🔹 **Đọc được lỗi** — console + script error kèm stack trace ở cả server lẫn client

🔹 **Thông minh hơn khi thao tác** — tìm UI theo text/tên/class, tự phát hiện nút bị popup che, liệt kê ProximityPrompt ("nhấn E") gần đó

🔹 **Tiện cho dev** — hỗ trợ nhiều cửa sổ Studio cùng lúc, tự khôi phục cửa sổ khi bị minimize, chạy code Luau theo ngữ cảnh edit/server/client

Ví dụ thật mình đã chạy: để Claude tự vào game farming của mình — tự bấm Play, nói chuyện NPC, mua hạt giống, mở inventory search đồ, đi tới chậu trống trồng cây, rồi tự kiểm tra xem có script error nào không. Toàn bộ không đụng chuột lần nào.

⚙️ **Cài đặt (Windows):**

1. Tải `rbx-studio-mcp.exe` ở mục Releases: https://github.com/Kiet1308/studio-rust-mcp-server/releases/latest
2. Chạy file exe một lần (tự cài plugin Studio + tự cấu hình Claude/Cursor)
3. Khởi động lại Studio và AI client → xong

📌 Repo + hướng dẫn chi tiết: https://github.com/Kiet1308/studio-rust-mcp-server (macOS thì build từ source theo README)

Project này mình **sẽ update thường xuyên** — trong kế hoạch có multiplayer nhiều client, record & replay thao tác, báo cáo test tự động… Rất mong mọi người tải về **test thử và phản hồi**: gặp bug, thấy thiếu tool gì, hay có ý tưởng hay thì comment ở đây hoặc mở Issue trên GitHub giúp mình nhé. Cảm ơn mọi người! 🙏

⚠️ Lưu ý: tool cho phép AI client chạy code và đọc nội dung place đang mở trong Studio — chỉ dùng với project của bạn và AI client bạn tin tưởng.

<!-- ============ HẾT PHẦN BÀI ĐĂNG — bên dưới là ghi chú riêng, đừng copy ============ -->

---

## Ghi chú trước khi đăng (không copy vào bài)

- **Chuyển repo sang Public trước khi đăng** (Settings → Danger Zone → Change visibility) — repo đang Private nên người ngoài bấm link sẽ thấy 404.
- **Kèm video/GIF demo ngắn** (~30s Claude tự chơi game: click NPC mua hạt + trồng cây) — bài có demo trực quan tương tác cao hơn hẳn.
- Nếu có người hỏi *"khác gì MCP có sẵn của Studio?"*: MCP chính chủ của Studio chỉ chạy code/đọc place, còn bản này cho AI "chơi" game thật sự — thấy màn hình, click, gõ phím, điều khiển nhân vật — nên test được gameplay end-to-end.
- Link `releases/latest` tự trỏ tới bản mới nhất mỗi lần release, không cần sửa bài đăng.
