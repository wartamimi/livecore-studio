# Langkah 1 — Analisis Lingkungan & Kelayakan Teknis

Dokumen ini mencatat apa yang **benar-benar** tersedia saat proyek dibuat, keputusan teknis, dan risiko.

## 1. Lingkungan build yang tersedia (diperiksa, bukan diasumsikan)

| Item | Hasil pemeriksaan | Dampak |
|---|---|---|
| OS | Ubuntu 24.04.5 LTS, kernel Linux 6.18 (container cloud) | **Bukan macOS** |
| CPU | x86_64, 4 core, RAM 15 GB | — |
| Xcode / xcodebuild / macOS SDK | **Tidak ada** (tidak bisa dipasang di Linux) | App macOS tidak bisa dikompilasi / dijalankan di sini |
| Swift | Swift 6.0.3 (paket `swiftlang` Ubuntu, dipasang lokal tanpa root) | Target lintas-platform `LiveCoreCore` dapat dibangun & dites |
| ffmpeg / ffprobe | ffmpeg 6.1 (Ubuntu) | Dipakai sebagai server RTMP lokal dan alat inspeksi media |
| Kamera, mikrofon, capture card, GPU Metal | **Tidak ada** | Semua tes perangkat → *Blocked by environment* |
| Server streaming publik | Tidak diakses (tidak ada stream key) | Diganti server RTMP lokal (ffmpeg `-listen 1`) |

**Yang perlu diperiksa di MacBook Anda** (dicetak otomatis oleh `scripts/build_macos.sh`):
`sw_vers`, `uname -m` (arm64 / x86_64), `xcodebuild -version` (≥ 15), `swift --version` (≥ 5.9),
`system_profiler SPCameraDataType SPAudioDataType SPDisplaysDataType` (perangkat & GPU).

## 2. Target minimum macOS: **macOS 13 Ventura**

Alasan:
- SwiftUI `Window`, `openWindow`, `Grid`, `LabeledContent`, `Form.grouped` (macOS 13) dipakai di UI.
- `AVCaptureDevice.DiscoverySession` dengan `.externalUnknown`, `AVAudioSourceNode`, `VTCompressionSession`
  dengan encoder hardware, `AVAssetWriter.movieFragmentInterval`, `Network.framework` TLS — semua tersedia.
- macOS 13 masih mendukung Mac Intel mulai 2017, sehingga cakupan perangkat tetap luas.
- Fitur macOS 14 (`.external`, `.continuityCamera`, `.microphone`) dipakai lewat `#available`.
- Tidak memakai `Observation` (@Observable, macOS 14) maupun `Synchronization.Atomic` (macOS 15);
  diganti `ObservableObject` dan shim C11 atomics (`Sources/CAtomics`).

## 3. Intel vs Apple Silicon (dievaluasi terpisah)

| Aspek | Apple Silicon (M1–M4) | Intel (2017–2020) |
|---|---|---|
| Encode H.264 | Media engine (VideoToolbox HW) — beban CPU sangat rendah | Intel Quick Sync via VideoToolbox; Mac dengan chip T2 juga punya encoder HW. Kualitas/beban bervariasi per generasi |
| GPU / Metal | GPU terintegrasi, unified memory → IOSurface zero-copy sangat efisien | Intel UHD/Iris (lemah) atau AMD diskret; IOSurface tetap zero-copy tapi bandwidth lebih kecil |
| Thermal | Stabil untuk 1080p30 berjam-jam (perlu diuji) | MacBook Intel mudah *thermal throttling* pada 1080p60 → rekomendasi 720p30/1080p30 |
| Build | `arm64` | `x86_64`; `project.yml` membangun Universal (arm64+x86_64) untuk Release |
| Status verifikasi | **Belum diuji** (Blocked by environment) | **Belum diuji** (Blocked by environment) |

Aplikasi menampilkan apakah encoder yang dipakai hardware atau software (`kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder`),
FPS render aktual, waktu GPU per frame, dan status termal — sehingga kompatibilitas dapat diukur di perangkat nyata.

## 4. Pemilihan framework

| Fungsi | Pilihan | Alasan / alternatif yang ditolak |
|---|---|---|
| Capture video | AVFoundation `AVCaptureSession` + `AVCaptureVideoDataOutput` (BGRA) | API resmi untuk UVC & perangkat yang terdaftar di macOS. ScreenCaptureKit tidak dibutuhkan untuk M1 |
| Capture audio | `AVCaptureAudioDataOutput` per perangkat (konversi ke 48 kHz Float32 oleh OS) | `AVAudioEngine.inputNode` hanya mendukung satu perangkat input |
| Komposisi / transisi | Metal (shader dikompilasi saat runtime), `CVMetalTextureCache` | Core Image lebih lambat untuk multi-layer real-time; CPU compositing ditolak |
| Tampilan monitor | `CALayer.contents = IOSurface` | Tanpa salinan, tanpa re-render SwiftUI |
| Mixer audio | `AVAudioEngine` + satu `AVAudioSourceNode` (DSP sendiri, real-time safe) | AudioUnit graph manual: lebih rumit tanpa manfaat di M1 |
| Encode video | VideoToolbox `VTCompressionSession` H.264 (HW) | x264 (GPL) ditolak karena lisensi & beban CPU |
| Encode audio | AudioToolbox AAC-LC lewat `AVAudioConverter` | fdk-aac (lisensi tidak kompatibel GPL/komersial bebas) |
| RTMP/RTMPS | **Implementasi sendiri** (`LiveCoreCore/RTMP`, sans-IO) + `Network.framework` (TCP/TLS) | librtmp (LGPL, tidak terawat, tanpa RTMPS modern); FFmpeg (LGPL/GPL, ukuran & build kompleks). AVFoundation **tidak** menyediakan RTMP |
| Muxing FLV | Implementasi sendiri (`LiveCoreCore/Media`) | Diverifikasi dengan ffprobe |
| Recording | `AVAssetWriter` (MP4/MOV, H.264+AAC) | Format standar Apple, finalisasi yang benar |
| Penyimpanan stream key | Keychain (`SecItem*`) | Tidak pernah di UserDefaults/log/kode |

## 5. Dokumentasi resmi yang menjadi acuan

- Apple: AVFoundation Capture (AVCaptureSession, DiscoverySession), VideoToolbox (VTCompressionSession, properti
  kVTCompressionPropertyKey_*), AVAudioEngine/AVAudioSourceNode, Metal Programming Guide, CVMetalTextureCache,
  AVAssetWriter, Network.framework (NWConnection, NWProtocolTLS), Keychain Services, TN2258 (AAC encoder delay 2112 sampel).
- Adobe RTMP Specification 1.0 (2012), Adobe Flash Video File Format Specification v10.1 (FLV), AMF0 Specification.
- ISO/IEC 14496-15 (AVCDecoderConfigurationRecord), ISO/IEC 14496-3 (AudioSpecificConfig, ADTS).
- Blackmagic Desktop Video SDK & NDI SDK: dievaluasi untuk M3 (lihat `CAPTURE_DEVICES.md`).

> Catatan jujur: dokumen di atas adalah sumber acuan desain. Lingkungan ini tidak memiliki akses ke perangkat Apple
> untuk memverifikasi perilaku runtime; perilaku tersebut ditandai *Blocked by environment* di `TEST_RESULTS.md`.

## 6. Lisensi dependency

| Komponen | Lisensi | Catatan |
|---|---|---|
| Framework Apple (AVFoundation, Metal, VideoToolbox, Core Audio, Network, Security, SwiftUI) | Bagian dari macOS SDK | Tanpa redistribusi pihak ketiga |
| Kode LiveCore (semua di repo ini) | Milik Anda (belum ditentukan; sarankan pilih sebelum distribusi) | Tidak ada kode vMix/OBS yang disalin |
| ffmpeg/ffprobe | LGPL/GPL | **Hanya alat uji** (scripts), tidak di-link / tidak dibundel |
| XcodeGen | MIT | Alat build, tidak dibundel |
| Blackmagic Desktop Video SDK (M3) | EULA Blackmagic (gratis, perlu registrasi) | Belum dipakai |
| NDI SDK (M3) | Lisensi NDI (wajib atribusi "NDI®", syarat distribusi) | Belum dipakai |

Aplikasi M1 **tidak memiliki dependency pihak ketiga** saat runtime. Sejak 0.13.0 satu dependency: Lottie (airbnb/lottie-spm 4.6.1, Apache-2.0) untuk input Lottie, ditanam sebagai Lottie.framework.

## 7. Risiko teknis terbesar

1. **Belum ada kompilasi di macOS** dari lingkungan ini. Kode macOS lolos *syntax parse* `swiftc` tetapi belum
   *type-check* terhadap SDK. Mitigasi: CI GitHub Actions `macos-14` + `scripts/build_macos.sh`.
2. **Drift clock audio** antar perangkat (tiap interface punya kristal sendiri). M1 memakai jitter buffer dengan
   batas latensi (skip/underrun), belum resampling adaptif → kemungkinan klik sesekali pada sesi panjang.
3. **Sinkronisasi A/V**: latensi capture kamera (1–3 frame) vs mikrofon berbeda per perangkat → disediakan offset manual
   dan prosedur uji tepuk tangan (T-07).
4. **Kompatibilitas capture card**: hanya perangkat yang tampil sebagai AVCaptureDevice (UVC) yang didukung di M1.
5. **Thermal/performa Intel** pada 1080p60 + rekam + stream.
6. **Server RTMP yang berbeda-beda** (YouTube/Facebook/Twitch/nginx-rtmp/Wowza): protokol sudah diuji pada server
   ffmpeg; platform lain wajib diuji manual (T-08).
7. **RTMPS**: memakai TLS sistem (Network.framework) — perlu uji ke Facebook/YouTube RTMPS.

## 8. Kriteria keberhasilan MVP (Milestone 1)

MVP dinyatakan berhasil **hanya jika semua ini lulus di Mac nyata** (lihat `TEST_PLAN.md`):
1. Build tanpa error di Xcode 15+ (Intel dan Apple Silicon).
2. ≥ 2 input video (kamera + file/gambar) tampil di Preview dan Program yang terpisah.
3. CUT dan AUTO (Dissolve/Fade/Wipe) bekerja tanpa freeze; FPS render ≥ 98% dari target selama 30 menit pada 1080p30.
4. Meter audio bereaksi; mute/fader terdengar di output monitor dan rekaman.
5. Streaming RTMP dan RTMPS ke minimal satu platform berjalan 30 menit tanpa putus, dan reconnect otomatis berhasil setelah jaringan dicabut.
6. Rekaman MP4 valid (ffprobe: H.264 + AAC, durasi sesuai), juga saat streaming bersamaan.
7. Mencabut kamera/mikrofon saat live tidak membuat crash.
