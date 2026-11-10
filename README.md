<img src="docs/images/logo.png" width="96" alt="LiveCore Studio logo">

# LiveCore Studio

Aplikasi live video production native macOS (Swift, SwiftUI, AVFoundation, Metal, Core Audio, VideoToolbox) dengan
workflow Preview/Program ala vMix/OBS untuk wedding, event korporat, seminar, meeting, dan siaran. Arsitektur dan kode
orisinal: tidak ada kode, aset, atau implementasi vMix/OBS yang disalin. LiveCore Studio **tidak** mengklaim setara vMix;
setiap fitur punya status yang jelas di [docs/FEATURE_STATUS.md](docs/FEATURE_STATUS.md).

> **Versi terbaru: 0.64.0 (build 90)**, pre-release tanpa tanda tangan. Fungsi inti (kamera, Preview/Program, CUT/AUTO,
> meter audio, rekaman, live streaming ke YouTube/Facebook) sudah dilaporkan berfungsi di Mac pengguna. Banyak fitur
> sesudahnya sudah dikompilasi dan diuji otomatis di CI, tetapi **belum dites di perangkat**; lihat kolom Verifikasi
> di FEATURE_STATUS.

## Install (DMG tanpa tanda tangan)

1. Buka [Releases](https://github.com/wartamimi/livecore-studio/releases) dan unduh
   `LiveCoreStudio-<versi>-unsigned.dmg` dari rilis terbaru (`dev-build-N` = build pengembangan, `build-N` = dari `main`).
2. Buka DMG, seret **LiveCore Studio** ke **Applications**.
3. Pertama kali dibuka: klik kanan app → **Open** → **Open** (Gatekeeper, karena app belum ditandatangani Developer ID).
   Bila tetap diblokir: System Settings › Privacy & Security › **Open Anyway**.
4. Izinkan akses Kamera, Mikrofon, dan (untuk input layar/jendela) Screen Recording saat diminta.

Kebutuhan: macOS 13 Ventura atau lebih baru, Mac Intel atau Apple Silicon (Universal). Kompatibilitas tiap Mac dan
perangkat capture ditentukan dari hasil tes, bukan dijanjikan. Opsional: NDI Tools / NDI Runtime (input & output NDI),
driver Blackmagic Desktop Video (DeckLink), `cloudflared` atau Tailscale (Web Controller dari internet).

## Fitur dan status

Ringkasan di bawah; rincian, versi, dan bukti per fitur ada di [FEATURE_STATUS.md](docs/FEATURE_STATUS.md).
**Implemented** = kode lengkap ada (belum tentu sudah dites di Mac), **Partial** = sebagian, **Planned** = belum ada
kode, **Blocked** = butuh sesuatu di luar kendali proyek.

### Video
| Fitur | Status |
|---|---|
| Kamera USB/UVC & built-in, capture card HDMI/SDI yang tampil sebagai UVC (format, fps 24/25, deinterlace, range warna) | Implemented (kamera inti dites pengguna) |
| Preview/Program, CUT, AUTO, T-bar; Dissolve, Fade, Wipe, Push, Slide, Iris, stinger, transisi shader Metal custom | Implemented |
| Input: file video, playlist video, gambar (semua format ImageIO), warna, Colour Bars, teks, jam/countdown, slideshow, running text (RSS/.txt), browser, scene, QR Code, bendera dunia, Virtual Set (12 studio orisinal) | Implemented |
| Input tangkap layar/jendela dengan audio aplikasi (Zoom/Teams/Meet) | Implemented |
| Input NDI, SRT (listener/caller, H.264/HEVC), Blackmagic DeckLink | Implemented (DeckLink belum dites dengan kartu) |
| Title Designer, lower third, template title termasuk 3D, file template `.lctitle` | Implemented |
| Layer Designer (PiP, crop, bingkai, sudut, mask), chroma key, koreksi warna, LUT, tab Animation | Implemented |
| Multiview (beberapa layout), overlay 1–4, canvas 16:9 / 9:16 / custom, vertical output | Implemented |
| Instant replay dengan slow motion | Implemented |
| Text3D sungguhan (ekstrusi), title khusus vertikal | Partial / Planned |

### Audio
| Fitur | Status |
|---|---|
| Mixer multi-kanal, fader, mute, solo, meter, master + Bus A–D, audio follow video, delay/sinkronisasi | Implemented |
| EQ, high-pass/LPF, noise gate, compressor, limiter per kanal dan master | Implemented |
| Plugin audio Audio Unit (AUv2/v3) dan VST3, insert hingga 8 per kanal + master | Implemented (sandbox VST3 terpisah, latency compensation: Planned) |
| Monitoring ke perangkat output terpisah, mix-minus | Implemented |

### Streaming & rekaman
| Fitur | Status |
|---|---|
| RTMP/RTMPS custom, stream key di Keychain, H.264 VideoToolbox + AAC, hingga 3 tujuan dengan satu encode | Implemented (dites pengguna ke YouTube/Facebook) |
| Statistik bitrate/drop/durasi, reconnect otomatis | Implemented (reconnect belum dites di Mac) |
| Rekam Program MP4/MOV (H.264/HEVC), MOV tahan crash, penanganan disk penuh | Implemented |
| MultiCorder/ISO per input (maks 4), snapshot PNG, tanda highlight | Implemented |
| Output: fullscreen ke layar lain, 4 output EXTERNAL, output NDI (untuk NDI Virtual Camera di Zoom/Meet) | Implemented |
| Enkripsi SRT, video 10-bit & playout DeckLink | Planned |

### Kontrol & integrasi
| Fitur | Status |
|---|---|
| Shortcut keyboard yang bisa diatur (dengan preset), MIDI dengan Learn | Implemented |
| Web Controller dari HP/tablet (PIN, video Program/Preview, mixer, audio monitor), online via Cloudflare/Tailscale | Implemented / Partial |
| LCS Live: tamu jarak jauh lewat link browser | Partial, belum dites di Mac |
| Transkripsi/subtitle realtime (Apple Speech, ElevenLabs) | Implemented / Partial |
| Pustaka online Pixabay (API key sendiri) | Implemented |
| Simpan/muat proyek `.livecore`, template proyek, tema tampilan, UI Inggris + Indonesia | Implemented |
| AJA Kona/Io (NTV2) | Blocked (butuh integrasi SDK besar dan perangkat uji) |
| Magewell Pro SDK | Planned |
| Developer ID, notarisasi, auto-update | Blocked (butuh akun Apple Developer) |
| Input Zoom Meeting SDK | Ditunda (tidak ada di build publik) |
| Syphon, kamera virtual sendiri | Dihapus atas permintaan pengguna (pakai NDI) |

## Build dari source (di Mac)

Kebutuhan: macOS 13+, **Xcode 16+ lengkap** (bukan hanya Command Line Tools), Homebrew.

```bash
brew install xcodegen ffmpeg
swift test                        # unit test inti (LiveCoreCore)
scripts/rtmp_e2e_test.sh          # uji RTMP end-to-end ke server ffmpeg lokal
scripts/build_macos.sh release    # generate Xcode project + build .app (Universal)
open build/DerivedData/Build/Products/Release/LiveCoreStudio.app
scripts/make_dmg.sh               # → build/LiveCoreStudio-<versi>-unsigned.dmg
```

Pengembangan di Xcode: `xcodegen generate && open LiveCoreStudio.xcodeproj` → skema *LiveCoreStudio* → ⌘R.

> Jika muncul `xcode-select: error: tool 'xcodebuild' requires Xcode`, pasang Xcode dari App Store, buka sekali, lalu:
> `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -license accept && xcodebuild -runFirstLaunch`.

**CI** (`.github/workflows/ci.yml`): tes inti di Linux; di macOS build app, unit test, dan cek engine (NDI, ISO,
replay, plugin audio, title, SRT, dll.); lalu DMG dipublikasikan otomatis sebagai pre-release `dev-build-N`
(branch `claude/*`) atau `build-N` (`main`).

## Struktur proyek
```
Package.swift                 SwiftPM: library, app, alat cek CI, tes
project.yml                   XcodeGen → LiveCoreStudio.xcodeproj
App/, Config/                 Entry point, Info.plist, entitlements
Sources/CAtomics/             C11 atomics untuk thread real-time
Sources/LiveCoreCore/         Inti portabel & teruji di Linux: switching, layout, DSP audio, RTMP/FLV, SRT, model proyek
Sources/LiveCoreEngine/       macOS: sumber video, render Metal, audio engine, encode, streaming, rekaman, perangkat
Sources/LiveCoreServices/     Layanan: autosave, log, Pixabay, Google Fonts, template title
Sources/LiveCoreRemote/       Server Web Controller
Sources/LiveCoreUI/           SwiftUI: AppModel, Views, lokalisasi {en,id}.lproj
Sources/CDeckLink, CNDI, CVST3  Jembatan C/C++ ke Blackmagic, NDI (dimuat saat jalan), host VST3
Sources/livecore-*-check/     Alat uji otomatis yang dijalankan CI
Tests/LiveCoreCoreTests/      Unit test
scripts/                      build, DMG, tes RTMP, CI
docs/                         Dokumentasi
```

## Dokumentasi
| Dokumen | Isi |
|---|---|
| [FEATURE_STATUS.md](docs/FEATURE_STATUS.md) | Status setiap fitur: implemented / partial / planned / blocked, beserta verifikasinya |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Modul, aliran video/audio/data, concurrency, timestamp, pixel format |
| [ENVIRONMENT.md](docs/ENVIRONMENT.md) | Target macOS, Intel vs Apple Silicon, pilihan framework, lisensi, risiko |
| [TEST_PLAN.md](docs/TEST_PLAN.md) / [TEST_RESULTS.md](docs/TEST_RESULTS.md) | Tes manual & otomatis, dan hasilnya |
| [KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) | Batasan yang diketahui |
| [RTMP_GUIDE.md](docs/RTMP_GUIDE.md) | Konfigurasi RTMP/RTMPS per platform |
| [CAPTURE_DEVICES.md](docs/CAPTURE_DEVICES.md) | Perangkat capture yang didukung |
| [CUSTOM_TRANSITIONS.md](docs/CUSTOM_TRANSITIONS.md) | Membuat transisi shader Metal sendiri |
| [COMPANION.md](docs/COMPANION.md) | Kontrol dari Stream Deck lewat Bitfocus Companion |
| [PACKAGING.md](docs/PACKAGING.md) | Build, DMG, code signing, notarisasi |

## Roadmap singkat
- **Selesai di kode:** MVP (M1), workflow produksi (M2), sebagian besar ekspansi broadcast (M3: NDI, SRT, DeckLink,
  multi-destination, ISO, plugin audio, Web Controller).
- **Berikutnya:** tes perangkat untuk fitur yang belum diverifikasi, optimasi capture NV12/GPU di Mac Intel,
  video 10-bit dan playout DeckLink, sandbox VST3.
- **Butuh pihak luar:** AJA NTV2, Magewell SDK, Developer ID + notarisasi.

NDI® adalah merek dagang Vizrt NDI AB. Blackmagic Design, DeckLink, VST (Steinberg), dan merek lain milik pemiliknya
masing-masing.
