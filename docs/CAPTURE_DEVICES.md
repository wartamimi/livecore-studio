# Panduan Dukungan & Penambahan Capture Device

## Yang didukung di M1
Semua perangkat video yang muncul di macOS sebagai `AVCaptureDevice` (cek: FaceTime/QuickTime › New Movie Recording ›
daftar kamera, atau `system_profiler SPCameraDataType`):
- Kamera built-in, webcam USB (UVC), Continuity Camera (macOS 14+).
- Capture HDMI **kelas UVC**: dongle USB HDMI generik, Elgato Cam Link 4K, AVerMedia Live Gamer (UVC), Magewell USB Capture,
  Blackmagic UltraStudio/Web Presenter/ATEM Mini (mode webcam).
- Audio HDMI dari perangkat tersebut biasanya muncul sebagai input audio terpisah → tambahkan di mixer.

**Tidak ada janji dukungan universal**: format (MJPEG/YUY2/NV12), resolusi, dan frame rate tergantung firmware perangkat.
LiveCore memilih format perangkat terdekat dengan resolusi output yang mendukung frame rate output, dan menampilkan
status "No signal" bila perangkat dicabut atau sumber HDMI hilang.

## Belum didukung (butuh SDK vendor)
| Perangkat | Jalur | Status |
|---|---|---|
| Blackmagic DeckLink / UltraStudio / Intensity | DeckLink API dari driver Desktop Video (`Sources/CDeckLink`) | Implemented 0.54.0, belum dites dengan kartu (T-297..T-300) |
| AJA U-TAP (USB) | UVC/UAC, jalur kamera biasa | Didukung lewat jalur kamera |
| AJA Io/Kona/T-TAP | AJA NTV2 (libajantv2, open source MIT) | Blocked: belum diintegrasikan (pustaka C++ besar, butuh perangkat AJA untuk uji) |
| Magewell Pro Capture (PCIe/Thunderbolt) | Magewell SDK | Planned M3 |
| NDI | NDI SDK (lisensi NDI, atribusi wajib) | Planned M3 |

## Cara menambah jenis sumber baru (untuk developer)
1. Buat kelas di `Sources/LiveCoreEngine/Sources/` yang mengimplementasikan `VideoSource`:
   - `currentFrame()` harus cepat & non-blocking → simpan frame terbaru di `FrameSlot`.
   - Frame wajib `CVPixelBuffer` **BGRA, IOSurface-backed, Metal-compatible** (pakai `PixelBufferFactory.attributes`).
     Jika SDK vendor memberi UYVY/v210, konversi dengan `VTPixelTransferSession` atau shader Metal ke BGRA.
   - Laporkan `status` (`.starting/.live/.noSignal/.error`) di main thread lewat `onStatusChange`.
2. Tambahkan `case` baru di `InputKind`, ikon di `InputTile`, dan fungsi `add…` di `ProductionEngine` (pola `addCamera`).
3. Audio dari perangkat: buat `MixerChannel` via `mixer.addChannel` dan tulis Float32 48 kHz non-interleaved ke
   `ringL/ringR` (lihat `AudioCaptureInput`) — jangan alokasi atau blocking di callback SDK.
4. Discovery & hot-plug: tambahkan enumerasi di `DeviceManager` dan panggil `onChange`.
5. Uji: T-03, T-12, T-13 dari `TEST_PLAN.md` dengan perangkat nyata.

### DeckLink (0.54.0)
Tambah input › Blackmagic DeckLink / UltraStudio…. Butuh Blackmagic Desktop Video (driver + `DeckLinkAPI.framework`)
terpasang; LiveCore tidak menyertakan apa pun dari runtime itu. Header SDK 12.0 di `Sources/CDeckLink/decklink`
berlisensi bebas Blackmagic (boleh didistribusikan, catatan lisensi wajib tetap ada).

### Kerangka DeckLink (rancangan awal M3)
Callback `IDeckLinkInputCallback::VideoInputFrameArrived` → salin/konversi frame ke `CVPixelBuffer` dari pool →
`FrameSlot.put`; `VideoInputFormatChanged` → rekonfigurasi (deteksi format otomatis); audio 48 kHz PCM dari frame yang sama →
ring mixer. SDK dimuat dinamis (`DeckLinkAPIDispatch.cpp`) sehingga app tetap jalan tanpa driver Desktop Video.
