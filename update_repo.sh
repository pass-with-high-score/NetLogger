#!/bin/bash

echo "📦 1. Xóa các bản build cũ..."
make clean
rm -f packages/*.deb

echo "🛠 2. Biên dịch bản Tweak mới nhất..."
make package

echo "📂 3. Copy .deb vào thư mục repo (docs/debs)..."
cp packages/*.deb docs/debs/

echo "🔍 4. Đang quét và tạo Packages file (yêu cầu dpkg)..."
cd docs || exit

# Kiểm tra xem dpkg-scanpackages có tồn tại không
if ! command -v dpkg-scanpackages &> /dev/null; then
    echo "❌ LỖI: Không tìm thấy 'dpkg-scanpackages'. Vui lòng cài đặt bằng 'brew install dpkg' trên macOS."
    exit 1
fi

# Quét tất cả file .deb trong thư mục /debs/ và ghi vào Packages
dpkg-scanpackages -m ./debs > Packages

echo "🗜 5. Đang nén Packages file (Bzip2, XZ, Zstd, Gzip)..."
bzip2 -fks Packages
gzip -fk Packages
xz -fk Packages 2>/dev/null || echo "⚠️ Bỏ qua nén xz (chưa cài xz)"
zstd -q -f -c19 Packages > Packages.zst 2>/dev/null || echo "⚠️ Bỏ qua nén zstd (chưa cài zstd)"

echo "📄 6. Đang tạo file Release..."
# Header của file Release
cat <<EOF > Release
Origin: NetLogger Repository
Label: NetLogger Repo
Suite: stable
Version: 1.0
Codename: netlogger
Architectures: iphoneos-arm iphoneos-arm64 iphoneos-arm64e
Components: main
Description: Official repository for NetLogger Tweak
MD5Sum:
EOF

# Hàm tính toán Hash và Size (tương thích macOS/Darwin)
generate_hashes() {
    for file in Packages Packages.bz2 Packages.gz Packages.xz Packages.zst; do
        if [ -f "$file" ]; then
            # Lấy size (macOS dùng stat -f %z, Linux dùng stat -c %s)
            if [[ "$OSTYPE" == "darwin"* ]]; then
                size=$(stat -f %z "$file")
                md5=$(md5 -q "$file")
                sha256=$(shasum -a 256 "$file" | awk '{print $1}')
            else
                size=$(stat -c %s "$file")
                md5=$(md5sum "$file" | awk '{print $1}')
                sha256=$(sha256sum "$file" | awk '{print $1}')
            fi
            
            # Lưu vào mảng tạm để ghi sau
            case $1 in
                "MD5") echo " $md5 $size $file" >> Release ;;
                "SHA256") echo " $sha256 $size $file" >> Release ;;
            esac
        fi
    done
}

# Ghi MD5Sum
generate_hashes "MD5"

# Ghi SHA256
echo "SHA256:" >> Release
generate_hashes "SHA256"

cd ..

echo "✅ HOÀN TẤT!
Xin hãy chạy các lệnh sau để đẩy lên Github:
  git add docs/
  git commit -m \"Update repo metadata\"
  git push
"
