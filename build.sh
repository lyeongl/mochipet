#!/bin/sh
# MochiPet.app(Claude 세션마다 뜨는 펫)을 만든다. Xcode Command Line Tools(swiftc)가 필요하다.
#   ./build.sh           빌드
#   ./build.sh gallery   빌드하고 gallery/ 의 그림과 GIF 도 다시 뽑는다 (그림을 고쳤을 때)
set -e
cd "$(dirname "$0")"
APP=MochiPet.app
BIN=$APP/Contents/MacOS/MochiPet

mkdir -p "$APP/Contents/MacOS"
swiftc -O Sources/*.swift -o "$BIN"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MochiPet</string>
<key>CFBundleIdentifier</key><string>local.mochipet</string>
<key>CFBundleName</key><string>MochiPet</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
"$BIN" --selftest

# 코드로 그리는 펫의 모든 프레임을 종류마다 한 장(gallery/<종류>.png)으로 뽑는다. 어떤 종류와 자세가 있는지 폴더에서 볼 수 있다.
# 평소 빌드에서는 뽑지 않는다. 뽑을 때마다 추적 중인 파일이 바뀌기 때문이다.
if [ "$1" = gallery ]; then
    rm -rf gallery
    "$BIN" --gallery gallery
fi
