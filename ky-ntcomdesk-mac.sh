#!/usr/bin/env bash
# KÝ SỐ + CÔNG CHỨNG bản NtcomDesk cho macOS — CHẠY TRÊN MÁY macOS.
#
# GitHub Actions dựng ra file .dmg CHƯA KÝ (máy Linux không ký được vì codesign/
# notarytool/stapler đều là công cụ của Apple). Script này lo nốt phần đó.
#
#   bash ky-ntcomdesk-mac.sh                      # ký + công chứng mọi .dmg cạnh script
#   bash ky-ntcomdesk-mac.sh NtcomDesk-1.5.0-aarch64.dmg   # chỉ định file cụ thể
#   bash ky-ntcomdesk-mac.sh --chi-ky             # chỉ ký, chưa gửi công chứng
#   bash ky-ntcomdesk-mac.sh --ho-so ntcom        # dùng hồ sơ notarytool đã lưu
#
# CHUẨN BỊ MỘT LẦN trên máy Mac:
#   - Xcode Command Line Tools:  xcode-select --install
#   - Chứng thư "Developer ID Application" đã nằm trong Keychain
#     (tải ở developer.apple.com -> Certificates rồi bấm đúp để cài).
#   - Lưu thông tin công chứng (chỉ làm 1 lần):
#       xcrun notarytool store-credentials ntcom \
#         --apple-id ten@ntcomvn.com --team-id XXXXXXXXXX \
#         --password abcd-efgh-ijkl-mnop
#     (password là "App-Specific Password" tạo ở account.apple.com, KHÔNG phải
#      mật khẩu Apple ID)
set -euo pipefail

CHI_KY=0; HO_SO="ntcom"; DINH_DANH=""; DMG_CHIDINH=()
while [ $# -gt 0 ]; do
  case "$1" in
    --chi-ky) CHI_KY=1 ;;
    --ho-so) HO_SO="${2:-ntcom}"; shift ;;
    --ho-so=*) HO_SO="${1#*=}" ;;
    --dinh-danh) DINH_DANH="${2:-}"; shift ;;
    --dinh-danh=*) DINH_DANH="${1#*=}" ;;
    *.dmg) DMG_CHIDINH+=("$1") ;;
    *) echo "Tham số lạ: $1"; exit 2 ;;
  esac
  shift
done

[ "$(uname)" = "Darwin" ] || { echo "Script này chỉ chạy trên máy macOS."; exit 1; }
command -v codesign >/dev/null || { echo "Thiếu Xcode CLT: xcode-select --install"; exit 1; }
GOC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Entitlements của NtcomDesk (khớp bản build) — ghi ra file tạm để ký gói.
QUYEN="/tmp/ntcomdesk-ent-$$.plist"; rm -f "$QUYEN"
cat > "$QUYEN" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key><false/>
	<key>com.apple.security.cs.allow-jit</key><true/>
	<key>com.apple.security.device.audio-input</key><true/>
	<key>com.apple.security.network.client</key><true/>
	<key>com.apple.security.network.server</key><true/>
	<key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
PLIST

# Tìm chứng thư ký
if [ -z "$DINH_DANH" ]; then
  DINH_DANH="$(security find-identity -v -p codesigning 2>/dev/null |
               grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')"
fi
[ -n "$DINH_DANH" ] || { echo "Không thấy chứng thư 'Developer ID Application' trong Keychain."; \
  echo "Kiểm: security find-identity -v -p codesigning"; exit 1; }
echo "==> Ký bằng: $DINH_DANH"

# Danh sách .dmg cần xử lý
if [ ${#DMG_CHIDINH[@]} -gt 0 ]; then
  CAC_DMG=("${DMG_CHIDINH[@]}")
else
  CAC_DMG=(); while IFS= read -r d; do CAC_DMG+=("$d"); done < <(find "$GOC" -maxdepth 1 -name "*.dmg" | sort)
fi
[ ${#CAC_DMG[@]} -gt 0 ] || { echo "Không thấy file .dmg nào. Đặt file .dmg cạnh script hoặc truyền tên file."; exit 1; }

ky_app() {  # $1 = đường dẫn .app
  local APP="$1"
  xattr -cr "$APP" 2>/dev/null || true
  local CHINH; CHINH="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Contents/Info.plist" 2>/dev/null || true)"
  local CAC_KY=()
  # Mọi file trong Contents/MacOS trừ file chương trình chính
  while IFS= read -r f; do
    [ -n "$CHINH" ] && [ "$f" = "$APP/Contents/MacOS/$CHINH" ] && continue
    CAC_KY+=("$f")
  done < <(find "$APP/Contents/MacOS" -type f 2>/dev/null)
  # Ngoài thư mục đó: chỉ ký file mã máy Mach-O (framework/dylib/helper)
  while IFS= read -r f; do
    case "$(file -b "$f" 2>/dev/null)" in *Mach-O*) CAC_KY+=("$f") ;; esac
  done < <(find "$APP" -type f -not -path "$APP/Contents/MacOS/*" 2>/dev/null)
  echo "    Ký ${#CAC_KY[@]} file bên trong (chừa $CHINH cho bước ký gói)"
  if [ ${#CAC_KY[@]} -gt 0 ]; then
    printf '%s\0' "${CAC_KY[@]}" | xargs -0 -n 25 codesign --force --timestamp --options runtime --sign "$DINH_DANH"
  fi
  echo "    Ký cả gói"
  codesign --force --timestamp --options runtime --entitlements "$QUYEN" --sign "$DINH_DANH" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
}

for DMG in "${CAC_DMG[@]}"; do
  echo; echo "==========================================================="
  echo " $DMG"; echo "==========================================================="
  MNT="/tmp/ntcomdesk-mnt-$$-$RANDOM"; mkdir -p "$MNT"
  WORK="/tmp/ntcomdesk-work-$$-$RANDOM"; mkdir -p "$WORK"
  hdiutil attach "$DMG" -nobrowse -mountpoint "$MNT" >/dev/null
  APPSRC="$(find "$MNT" -maxdepth 1 -name "*.app" -type d | head -1)"
  [ -n "$APPSRC" ] || { echo "Không thấy .app trong dmg"; hdiutil detach "$MNT" >/dev/null; exit 1; }
  cp -R "$APPSRC" "$WORK/"
  hdiutil detach "$MNT" >/dev/null
  APP="$WORK/$(basename "$APPSRC")"

  echo "--- Ký ứng dụng ---"
  ky_app "$APP"

  if [ "$CHI_KY" = "1" ]; then echo "  (bỏ qua công chứng vì --chi-ky)"; continue; fi

  echo "--- Đóng lại thành dmg đã ký (có alias Applications để kéo-thả) ---"
  RA="$GOC/$(basename "$DMG" .dmg)-signed.dmg"; rm -f "$RA"
  # Cần create-dmg để có bố cục kéo-thả chuẩn macOS. Thiếu thì cài qua Homebrew.
  if ! command -v create-dmg >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      echo "    Cài create-dmg qua Homebrew..."; brew install create-dmg
    fi
  fi
  APPNAME="$(basename "$APP")"
  if command -v create-dmg >/dev/null 2>&1; then
    # App bên trái, alias Applications bên phải -> người dùng chỉ việc kéo qua.
    create-dmg \
      --volname "NtcomDesk" \
      --window-pos 200 120 \
      --window-size 660 420 \
      --icon-size 120 \
      --icon "$APPNAME" 165 210 \
      --app-drop-link 495 210 \
      --hide-extension "$APPNAME" \
      --no-internet-enable \
      "$RA" "$APP" >/dev/null
  else
    echo "    (Không có create-dmg và không có brew -> tạo dmg trơn, KHÔNG có alias Applications)"
    hdiutil create -volname "NtcomDesk" -srcfolder "$APP" -ov -format UDZO "$RA" >/dev/null
  fi
  codesign --force --timestamp --sign "$DINH_DANH" "$RA"

  echo "--- Gửi Apple công chứng (chờ vài phút) ---"
  if ! xcrun notarytool submit "$RA" --keychain-profile "$HO_SO" --wait; then
    echo "CÔNG CHỨNG HỎNG. Xem log:"
    echo "  xcrun notarytool history --keychain-profile $HO_SO"
    echo "  xcrun notarytool log <id> --keychain-profile $HO_SO"
    exit 1
  fi
  echo "--- Đóng dấu vào dmg ---"
  xcrun stapler staple "$RA"
  echo "--- Kiểm cuối ---"
  xcrun stapler validate "$RA"
  spctl -a -vvv -t open --context context:primary-signature "$RA" 2>&1 || true
  echo "    -> $RA"
done
echo; echo "XONG. Upload các file *-signed.dmg lên GitHub Releases cho anh."
