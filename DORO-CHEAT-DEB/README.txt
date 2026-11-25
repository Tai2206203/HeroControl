DORO-CHEAT DEB — SOURCE RIÊNG

Đây là bản fork độc lập từ TIPA 0.18.0 build 38. Menu, ảnh, READ MEMORY mặc định
ON, ESP, camera và reports được sao chép vào chính cây source này. Không dùng
symlink, không import source từ thư mục cha và không cần cài TIPA để chạy DEB.
ORIGIN.json ghi nguồn gốc; thay đổi DEB không tự đồng bộ ngược sang TIPA.

Định danh và dữ liệu riêng
- Package: local.dorocheat.deb
- Bundle: local.dorocheat.deb.app; tên trên Home Screen: DORO-CHEAT DEB.
- State/settings: /var/mobile/Library/Application Support/DORO-CHEAT-DEB.
- Adapter riêng: DoroCheatDebRuntime.dylib/.plist, game Documents/DoroCheatDebRuntime.
- Không xóa dữ liệu TIPA hoặc gỡ adapter tên HeroControlRuntime của TIPA.
Không chạy hai HUD/adapter cùng lúc. Trước khi chuyển từ TIPA, bật READ MEMORY ở
TIPA để gỡ adapter cũ, đóng hẳn/mở lại game, rồi đóng HUD TIPA trước khi mở DEB.

Build trên macOS có Xcode, Python 3
  make validate
  make package PACKAGE_SCHEME=roothide
  make package PACKAGE_SCHEME=rootless
  make package PACKAGE_SCHEME=rootful
Không cần Theos hoặc dpkg để đóng gói: package-deb.py tạo ar/control.tar.gz/data.tar.gz
chuẩn Debian từ app iOS đã build và ký. Không đổi tên ZIP/TIPA thành DEB.
Nguồn trong ZIP có thể giải nén sang thư mục/repo khác và chạy các lệnh trên.
Bản iPhone nhắm iOS 15 trở lên; hỗ trợ API riêng/quyền jailbreak thực tế cần thử máy.

Chọn đúng file
- roothide: iphoneos-arm64e, layout /Applications được RootHide/dpkg đặt vào bootstrap;
  maintainer script dùng công cụ jbroot để lấy đường dẫn app thực.
- rootless: iphoneos-arm64, app ở /var/jb/Applications/DORO-CHEAT-DEB.app.
- rootful: iphoneos-arm, app ở /Applications/DORO-CHEAT-DEB.app.
Tên kiến trúc gói RootHide không có nghĩa source được biên dịch CPU arm64e: binary
arm64 dùng được trên thiết bị arm64e; kiến trúc gói là quy ước bootstrap/dpkg.
Các biến thể phải được kiểm thử trên môi trường tương ứng; chưa xác nhận trên máy.

Kết quả
  dist/doro-cheat-deb_0.18.0-1_<architecture>.deb
  dist/*.deb.sha256
  dist/DORO-CHEAT-DEB-source.zip
Build-DEB workflow của repo cha tạo ba biến thể riêng. Nếu tách thành repo riêng,
workflow nằm trong .github/workflows/build.yml cũng build độc lập.

Cài/gỡ
Cài bằng Sileo/Zebra phù hợp jailbreak, sau đó mở icon DORO-CHEAT DEB. Postinst chỉ
tạo vùng setting mobile và chạy uicache; không respring, không tự bật chức năng.
Khi gỡ/nâng cấp, prerm yêu cầu HUD riêng dừng và gỡ adapter DEB riêng; giữ setting
và lịch sử. Hook đã nạp cần đóng hẳn/mở lại game. Nếu READ MEMORY OFF, cam/reports
vẫn là các chức năng có can thiệp như bản TIPA; ON chỉ mở ESP và dọn trạng thái cũ.

Giới hạn tại máy phát triển Windows
Có thể kiểm tra source, test packer và xuất ZIP source tại đây. Không thể biên dịch
app iOS/DEB dùng thật khi thiếu Xcode/SDK Apple. Các file DEB dùng thật do CI macOS
hoặc máy Mac chạy build-deb.sh tạo ra; fixture DEB trong unittest không phải app.

Tài liệu định dạng/môi trường
https://theos.dev/docs/rootless
https://github.com/roothide/Developer
https://github.com/roothide/Procursus-roothide/blob/main/Makefile
https://www.debian.org/doc/debian-policy/ch-controlfields.html

Telegram
Workflow gui tung file .deb sau khi luu Artifacts, dung Actions secrets TELEGRAM_BOT_TOKEN
va TELEGRAM_CHAT_ID cua repository. Khong dua token vao source. Neu tach repo rieng,
can khai bao lai hai secrets trong repo moi. Thieu secrets: bo qua gui, van giu Artifacts.
Loi gui: bao do buoc Telegram, file da build van nam trong Artifacts; khong tu retry.
