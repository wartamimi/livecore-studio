# Kamera virtual LiveCore (seperti OBS)

Status: **Blocked** di build unsigned. Kodenya sudah ada sejak 0.22.0.

## Cara kerjanya
- `CameraExtension/` adalah CoreMediaIO **Camera Extension** (system extension), sama seperti kamera virtual OBS.
  Perangkatnya "LiveCore Virtual Camera" punya dua stream: *sink* (diisi LiveCore Studio) dan *source* (dibaca Zoom,
  Meet, OBS, QuickTime…). Tanpa kiriman dari LiveCore gambarnya hitam; ukuran lain diskalakan ke 1920×1080 30 fps.
- Extension di-embed di `LiveCoreStudio.app/Contents/Library/SystemExtensions/` (target XcodeGen
  `LiveCoreCameraExtension`; `scripts/build_macos.sh` memeriksa ada).
- App mengaktifkannya lewat `OSSystemExtensionRequest` (EXTERNAL ⚙ › Aktifkan kamera virtual) dan mengirim frame lewat
  `CMIOStreamCopyBufferQueue` ke stream sink (`VirtualCameraSender`), seperti plug-in mac-virtualcam OBS.

## Kenapa belum aktif
macOS hanya memasang system extension bila:
1. app dan extension ditandatangani dengan **Developer ID** (Team ID) dan dinotarisasi;
2. app punya entitlement `com.apple.developer.system-extension.install` (butuh provisioning profile Developer ID
   dengan kapabilitas System Extension);
3. app dijalankan dari `/Applications`;
4. pengguna mengizinkannya di System Settings › General › Login Items & Extensions › Camera Extensions.

Build CI ditandatangani ad-hoc (tanpa Team ID), jadi permintaan aktivasi ditolak (app menampilkan alasannya).
Menambahkan entitlement nomor 2 ke build ad-hoc membuat app langsung ditutup macOS saat dibuka, jadi tidak dilakukan.
Plug-in DAL lama (cara OBS sebelum 30) tidak dimuat lagi oleh macOS 14+. Jalan tanpa akun hanya mematikan SIP +
`systemextensionsctl developer on`, yang melemahkan keamanan Mac dan tidak disarankan.

## Setelah punya Apple Developer Program
1. Buat App ID `studio.livecore.LiveCoreStudio` (kapabilitas System Extension) dan
   `studio.livecore.LiveCoreStudio.CameraExtension`, serta App Group `<TEAMID>.studio.livecore.LiveCoreStudio`.
2. Buat provisioning profile Developer ID untuk keduanya.
3. Di `project.yml`: isi `DEVELOPMENT_TEAM`, ganti `CODE_SIGN_IDENTITY` ke "Developer ID Application", dan tambahkan
   `com.apple.developer.system-extension.install: true` ke entitlements app.
4. Tanda tangani, notarisasi (`xcrun notarytool`), staple, lalu buat DMG. CI bisa melakukannya dengan sertifikat +
   profil disimpan sebagai secret GitHub (tidak pernah di repo atau chat).

## Sementara: Syphon + OBS
EXTERNAL ⚙ › centang **Syphon** di output yang diinginkan, nyalakan **EXTERNAL**. Di OBS: tambah source
"Syphon Client" › "LiveCore Studio – Output N", lalu **Start Virtual Camera**. Pilih "OBS Virtual Camera" di Zoom/Meet.
