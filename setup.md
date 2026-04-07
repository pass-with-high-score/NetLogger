Để thiết lập dự án này một cách chuẩn xác nhất với Theos, bạn sẽ cần tạo một cấu trúc gộp (bao gồm cả Tweak và Preference Bundle) và cấu hình thêm thư viện **AltList** để hiển thị danh sách app.

Dưới đây là các câu lệnh và thao tác setup chi tiết từng bước:

### Bước 1: Khởi tạo dự án bằng Theos
Mở Terminal, di chuyển đến thư mục bạn muốn lưu code (ví dụ: `cd ~/TheosProjects`) và chạy lệnh khởi tạo:

```bash
$THEOS/bin/nic.pl
```

Khi bảng menu hiện ra, hãy chọn template **`iphone/tweak_with_simple_preferences`** (thường là phím số **`15`**).

Sau đó, điền các thông số như sau:
* **Project Name:** `NetLogger`
* **Package Name:** `com.minh.netlogger`
* **Author/Maintainer Name:** `Minh`
* **MobileSubstrate Bundle filter:** `com.apple.UIKit` 
    *(Lưu ý: Vì chúng ta muốn tweak tiêm vào tất cả các app để nó tự động kiểm tra xem app đó có được bật trong Cài đặt hay không, nên ta chọn `com.apple.UIKit` - framework nền tảng của mọi app có giao diện).*

---

### Bước 2: Cấu hình thư viện AltList (Rất quan trọng)
Vì bạn dùng iOS 16 (Dopamine Rootless) và cần một menu chọn App trong Cài đặt, thư viện **AltList** là bắt buộc. 

**1. Khai báo thư viện phụ thuộc (Dependencies)**
Mở file `control` (nằm ở thư mục gốc của dự án vừa tạo) và thêm AltList vào dòng `Depends`, sao cho nó trông như thế này:
```text
Package: com.minh.netlogger
Name: NetLogger
Depends: mobilesubstrate, com.opa334.altlist
Version: 0.0.1
Architecture: iphoneos-arm64
...
```

**2. Link thư viện vào dự án**
Mở file `Makefile` (ở thư mục gốc) và thêm `altlist` vào mục `LIBRARIES`. Đảm bảo file có các dòng sau cho kiến trúc Rootless:

```makefile
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NetLogger
NetLogger_FILES = Tweak.x
NetLogger_CFLAGS = -fobjc-arc
NetLogger_LIBRARIES = altlist   # <--- Thêm dòng này

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += netloggerprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
```

---

### Bước 3: Cài đặt AltList SDK vào Theos (Nếu bạn chưa có)
Để máy tính của bạn có thể biên dịch được code có chứa AltList, Theos cần có file header `.h` và file thư viện `.tbd` của AltList. Nếu bạn đã cài AltList SDK trước đó thì bỏ qua, nếu chưa thì chạy 2 lệnh sau trong Terminal:

**Tải file Header:**
```bash
wget https://raw.githubusercontent.com/opa334/AltList/master/AltList.h -O $THEOS/include/AltList.h
```

**Tải file Thư viện (cho Rootless):**
```bash
wget https://raw.githubusercontent.com/opa334/AltList/master/libaltlist.tbd -O $THEOS/lib/iphone/rootless/libaltlist.tbd
```

---

### Bước 4: Chuẩn bị file thiết kế giao diện (Root.plist)
Đi vào thư mục Settings của dự án: `cd netloggerprefs/Resources/`
Mở file `Root.plist` lên và thay thế toàn bộ nội dung bằng đoạn XML này để tạo ra giao diện gồm: Nút bấm xem Log và Menu chọn App.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>items</key>
    <array>
        <dict>
            <key>cell</key>
            <string>PSGroupCell</string>
            <key>label</key>
            <string>Bảng Điều Khiển</string>
        </dict>
        <dict>
            <key>cell</key>
            <string>PSLinkListCell</string>
            <key>detail</key>
            <string>ATLApplicationSelectionController</string>
            <key>defaults</key>
            <string>com.minh.netlogger</string>
            <key>key</key>
            <string>selectedApps</string>
            <key>label</key>
            <string>Chọn App Lắng Nghe</string>
            <key>sections</key>
            <array>
                <dict>
                    <key>sectionType</key>
                    <string>Visible</string>
                </dict>
            </array>
        </dict>
    </array>
    <key>title</key>
    <string>NetLogger</string>
</dict>
</plist>
```

Đến đây, phần khung xương (Setup) của dự án đã hoàn chỉnh. Bạn chỉ việc dán logic Hook vào file `Tweak.x` như tôi đã hướng dẫn ở lần trước, và chạy `make package install` là xong! Tweak của bạn đã sẵn sàng chạy trên Dopamine.