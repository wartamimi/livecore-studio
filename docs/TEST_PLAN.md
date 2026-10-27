# Test Plan — Milestone 1

## A. Tes otomatis (dapat dijalankan di Linux dan macOS)
| ID | Tes | Perintah |
|---|---|---|
| A-01 | Unit test LiveCoreCore (47 tes: switcher, transisi, overlay, layout, DSP, ring buffer lock-free, clock anchor, AMF0, AVC/AAC, FLV, RTMP URL/chunk/sesi, antrean kongesti, settings) | `swift test` |
| A-02 | E2E RTMP: publish H.264 High 720p30 + AAC 48k selama 10 s ke server RTMP ffmpeg, verifikasi ffprobe + decode semua frame | `scripts/rtmp_e2e_test.sh` |
| A-03 | E2E FLV writer → ffprobe | (bagian dari A-02) |
| A-04 | Kegagalan koneksi: server tidak ada, server memutus di tengah stream; stream key tidak bocor di log | (bagian dari A-02) |
| A-05 | Build app + Universal binary + Info.plist + codesign verify | `scripts/build_macos.sh release` (Mac) |

## B. Tes manual di Mac (wajib sebelum M1 dinyatakan selesai)
Persiapan: `brew install xcodegen ffmpeg`; jalankan `scripts/build_macos.sh debug`, buka app. Catat model Mac, chip, versi macOS.

| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-01 | App dapat dibangun | `scripts/build_macos.sh` | Tanpa error; `lipo -archs` = `x86_64 arm64` (Release) |
| T-02 | App dapat dibuka | `open build/.../LiveCoreStudio.app` | Jendela tampil, FPS ≈ target, tanpa crash |
| T-03 | Tambah input video | + → kamera; + → file video; + → gambar; + → Title | Izin kamera diminta; thumbnail bergerak; status hijau |
| T-04 | Preview menampilkan sumber terpilih | Klik tile 2 / tekan "2" | Monitor Preview menampilkan input 2; bingkai tile hijau |
| T-05 | CUT | Tekan Space | Program berganti seketika; Preview mendapat input sebelumnya |
| T-06 | AUTO | Pilih Dissolve/Fade/Wipe, durasi 1 s, tekan Return | Transisi halus tepat 1 s, tanpa freeze; T-bar bekerja |
| T-07 | Audio & sinkronisasi | Tambah mikrofon; bicara/tepuk tangan di depan kamera; rekam 30 s | Meter bereaksi; mute & fader terdengar; di rekaman, tepukan visual vs audio ≤ 1 frame setelah kalibrasi offset |
| T-08 | Streaming start/stop | Settings › Stream: URL + key (YouTube/Facebook RTMPS/server lokal); Start | Status LIVE, bitrate ≈ setelan, platform menerima; Stop bersih |
| T-08b | Server lokal | Terminal: `ffmpeg -listen 1 -i rtmp://127.0.0.1/live/test -c copy out.flv`; URL `rtmp://127.0.0.1/live`, key `test`; stream 60 s lalu Stop | `ffprobe out.flv`: h264 + aac, durasi ≈ 60 s |
| T-09 | Recording valid | Start/Stop rekam 60 s | `ffprobe -v error -show_streams file.mp4` → h264 + aac, durasi ≈ 60 s; `ffmpeg -v error -i file.mp4 -f null -` tanpa error |
| T-10 | Stream + rekam bersamaan | Jalankan keduanya 10 menit | Keduanya valid; FPS render stabil |
| T-11 | Kegagalan koneksi | Saat LIVE, matikan Wi-Fi 20 s lalu nyalakan | Status "Reconnecting", kembali LIVE otomatis; app tidak hang. URL/key salah → pesan error jelas, tanpa key di pesan |
| T-12 | Perubahan perangkat | Cabut kamera USB & mikrofon USB saat LIVE + REC; colok kembali | Tidak crash; status "No signal"; pulih otomatis setelah dicolok; rekaman tetap valid |
| T-13 | Pengukuran beban | 1080p30, 2 kamera, stream 6 Mbps + rekam, 30 menit; catat top bar + Activity Monitor | Catat CPU %, RAM, GPU ms/frame, FPS, dropped, termal (lihat format di TEST_RESULTS.md) |
| T-14 | Disk penuh | Rekam ke flashdisk kecil hampir penuh | Rekaman berhenti dengan pesan; file yang tersimpan dapat diputar |
| T-15 | Izin ditolak | Tolak izin kamera/mikrofon | Pesan jelas dengan petunjuk System Settings; app tetap jalan |
| T-16 | Bahasa Indonesia | System Settings › General › Language & Region › Applications › LiveCore Studio → Bahasa Indonesia | Label UI berbahasa Indonesia |

Format pencatatan hasil per tes: `ID | Passed/Failed/Not tested | perangkat | catatan + bukti (screenshot/log/ffprobe)`.
