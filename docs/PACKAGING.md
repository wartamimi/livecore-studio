# Membangun, Packaging & Code Signing di Mac

## Prasyarat
- macOS 13+ untuk menjalankan app; untuk build: **Xcode 16+ lengkap** (XcodeGen terbaru menghasilkan format proyek Xcode 16; Xcode 15.4 hanya bisa build lewat `swift build`/`scripts/bundle_spm_app.sh`) (Swift 5.9+). Command Line Tools saja tidak cukup (tidak ada `xcodebuild`, SDK lengkap, XCTest).
  Setelah memasang Xcode: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`,
  `sudo xcodebuild -license accept`, `xcodebuild -runFirstLaunch`, lalu verifikasi `xcodebuild -version`.
- `brew install xcodegen ffmpeg` (ffmpeg hanya untuk tes).

## Build
```bash
git clone <repo> && cd LiveCoreStudio
swift test                         # unit test core
scripts/rtmp_e2e_test.sh           # E2E RTMP ke server ffmpeg lokal
scripts/build_macos.sh release     # xcodegen + xcodebuild → build/DerivedData/Build/Products/Release/LiveCoreStudio.app
open build/DerivedData/Build/Products/Release/LiveCoreStudio.app
```
DMG (tanpa tanda tangan) untuk dibagikan: `scripts/make_dmg.sh` → `build/LiveCoreStudio-0.13.0-unsigned.dmg`. Pertama kali dibuka: klik kanan app → Open (Gatekeeper).
Alternatif tanpa XcodeGen: `scripts/bundle_spm_app.sh` (SwiftPM + bundle .app manual + ad-hoc codesign).
Untuk mengembangkan di Xcode: `xcodegen generate && open LiveCoreStudio.xcodeproj`, pilih skema *LiveCoreStudio*, ⌘R.

> Jangan menjalankan `swift run LiveCoreStudio` langsung: binary tanpa Info.plist akan dihentikan TCC saat mengakses kamera.

## Code signing & notarisasi (distribusi di luar App Store)
1. Butuh Apple Developer Program dan sertifikat **Developer ID Application**.
2. Di `project.yml` ganti `CODE_SIGN_IDENTITY: "-"` → `"Developer ID Application"` dan tambahkan `DEVELOPMENT_TEAM: <TEAMID>`.
3. Archive & export:
```bash
xcodegen generate
xcodebuild -project LiveCoreStudio.xcodeproj -scheme LiveCoreStudio -configuration Release -archivePath build/LiveCore.xcarchive archive
xcodebuild -exportArchive -archivePath build/LiveCore.xcarchive -exportPath build/export -exportOptionsPlist ExportOptions.plist
# ExportOptions.plist: method = developer-id
ditto -c -k --keepParent build/export/LiveCoreStudio.app build/LiveCoreStudio.zip
xcrun notarytool submit build/LiveCoreStudio.zip --keychain-profile <profil> --wait
xcrun stapler staple build/export/LiveCoreStudio.app
spctl --assess --type execute -vv build/export/LiveCoreStudio.app
```
Hardened runtime aktif; entitlement `com.apple.security.device.camera` dan `…audio-input` wajib agar izin kamera/mikrofon
berfungsi pada build yang dinotarisasi.

Lingkungan pembuatan proyek ini (Linux) **tidak dapat** melakukan signing/notarisasi.

## CI
`.github/workflows/ci.yml`: job Linux (unit + E2E) dan job `macos-14` (unit + E2E + build app + upload artefak .app).
Setelah repo di-push ke GitHub, status CI menjadi bukti kompilasi macOS pertama.
