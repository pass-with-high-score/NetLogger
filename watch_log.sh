#!/bin/bash

# Đường dẫn file log trên iPhone của bạn
LOG_FILE="/var/mobile/Library/Preferences/com.minh.netlogger.logs.txt"

echo "=========================================="
echo "   📡 ĐÀI QUAN SÁT NETLOGGER TWEAK 📡   "
echo "=========================================="
echo "1. Xem Log Trực Tiếp (Real-time)"
echo "2. Xem toàn bộ file Log (Từ đầu đến cuối)"
echo "3. Xóa trắng file Log (Clear data)"
echo "4. Thoát"
echo "=========================================="
read -p "👉 Chọn chức năng (1/2/3/4): " choice

case $choice in
    1)
        echo "🟢 Đang kết nối tới iPhone (Live stream)... Bấm Ctrl+C để thoát."
        # Lệnh tail -f giúp tự động cuộn màn hình khi có dòng log mới xuất hiện
        ssh -p 2222 mobile@127.0.0.1 "tail -f $LOG_FILE"
        ;;
    2)
        echo "📄 Đang tải nội dung file log..."
        # Lệnh cat để in toàn bộ dữ liệu
        ssh -p 2222 mobile@127.0.0.1 "cat $LOG_FILE"
        ;;
    3)
        echo "🧹 Đang dọn dẹp file log..."
        # Lệnh echo rỗng đè vào file để xóa trắng
        ssh -p 2222 mobile@127.0.0.1 "echo '' > $LOG_FILE"
        echo "✅ Đã xóa sạch lịch sử!"
        ;;
    4)
        echo "👋 Tạm biệt!"
        exit 0
        ;;
    *)
        echo "❌ Lựa chọn không hợp lệ!"
        ;;
esac