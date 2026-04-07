#!/bin/bash

echo "🔨 Đang biên dịch Tweak..."
make package

# Tìm file .deb mới nhất vừa được tạo ra trong thư mục packages
LATEST_DEB=$(ls -t packages/*.deb 2>/dev/null | head -n 1)

if [ -z "$LATEST_DEB" ]; then
    echo "❌ Lỗi: Không tìm thấy file .deb! Kiểm tra lại code xem có lỗi build không."
    exit 1
fi

echo "📦 Đã đóng gói xong: $LATEST_DEB"
echo "🚀 Đang gửi sang iPhone..."

# Bắn file sang iPhone vào thư mục Downloads qua cáp (iproxy)
# Lệnh này dùng quyền mobile nên KHÔNG BAO GIỜ bị hỏi pass sudo
scp -P 2222 "$LATEST_DEB" mobile@127.0.0.1:/var/mobile/Downloads/

echo "✅ Xong! Hãy mở Filza trên iPhone, vào đường dẫn: /var/mobile/Downloads/ để cài đặt."