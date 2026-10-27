# LiveCore Studio

Aplikasi live video production native macOS (Swift, SwiftUI, AVFoundation, Metal, Core Audio, VideoToolbox) dengan
workflow Preview/Program ala vMix/OBS untuk wedding, event korporat, seminar, dan siaran. Arsitektur dan kode orisinal —
tidak ada kode, aset, atau implementasi vMix/OBS yang disalin.

> **Status: 0.25.0 — Milestone 3 berjalan.** 0.25.0 menambah Layer Designer di monitor Preview (geser/ubah ukuran
> langsung dengan snapping, crop dengan menarik tepi — Shift untuk simetris —, bingkai, sudut melengkung, sembunyikan/kunci
> layer, Flatten Layers, dan tata letak tersimpan sebagai template), tombol FULLSCREEN ala vMix di bar atas dengan ⚙ untuk
> memilih layar dan gambar tiap output (layar ke-2/ke-3), tombol FOTO seukuran RECORD, transisi awal Dissolve, dan dock
> Playlist yang baru muncul setelah ada playlist — menunggu tes T-96..T-100. 0.24.0 menambah output NDI®: tiap output bisa dikirim sebagai sumber NDI
> "LiveCore Output N", sehingga Zoom/Meet bisa memakai LiveCore lewat kamera "NDI Virtual Camera" dari NDI Tools tanpa OBS.
> LiveCore memakai runtime NDI yang sudah terpasang (NDI Tools / NDI Runtime) dan tidak menyertakannya. CI membuktikan proses
> lain menemukan sumber NDI dan menerima frame-nya — menunggu tes T-93..T-95 di Mac. 0.23.0 memperbaiki Syphon (frame dikirim sejak awal, Output 1 otomatis
> nyala saat EXTERNAL, status "aplikasi tersambung", dan CI kini membuktikan proses lain bisa menemukan source dan membaca
> frame-nya), memperlambat kedipan NOT RECORDING, menghapus kamera virtual Camera Extension, memindahkan foto Program ke
> bawah monitor Program dan instant replay ke bawah T-bar, menyatukan gembok RECORD/STREAM, dan mengganti dock Overlay
> dengan nomor 1–4 di bawah tiap input (fade, layar penuh) — menunggu tes T-88..T-92. 0.22.0 memindahkan RECORD / STREAM ke dock bawah yang selalu tampil
> (dengan tombol ⚙ masing-masing) dan menambah EXTERNAL: 4 output dengan gambar sendiri-sendiri (Program, Preview, atau
> satu input) ke jendela/layar penuh dan ke aplikasi lain lewat Syphon (OBS "Syphon Client" → OBS Virtual Camera),
> pengingat NOT RECORDING berkedip di monitor Program, dan klik di Playlist kini hanya memilih (klik dua kali untuk
> memutar) — menunggu tes T-82..T-86. 0.21.0 menambah tombol x + gembok untuk kanal audio di mixer dan dock
> Playlist di samping mixer (klik untuk memutar, seret untuk mengurutkan, cari, M3U) — menunggu tes T-80..T-81.
> 0.20.0 menambah animasi masuk/keluar overlay (geser, zoom), eyedropper
> chroma key, dan fade antarlagu musik — menunggu tes T-77..T-79. 0.19.0 menambah arah teks berjalan (kiri → kanan) dan teks dari feed
> RSS/Atom — menunggu tes T-76. 0.18.0 memperbaiki klik saat delay audio diubah, membuat AFV crossfade
> selama transisi AUTO, dan memperbaiki teks berjalan yang sangat panjang; menambah teks berjalan dari file .txt, Ken
> Burns dan folder yang dipantau di slideshow — menunggu tes T-72..T-75. 0.17.0 menambah putar input 90°/270°, input teks berjalan (ticker) dan
> slideshow foto (folder, durasi per foto, crossfade) — menunggu tes T-69..T-71. 0.16.0 menambah koreksi warna & balik/putar per input dan nada tes 1 kHz —
> menunggu tes T-67..T-68. 0.15.0 menghapus Lottie, menambah input Scene + template tata letak,
> Colour Bars, tombol fullscreen per input, pengaturan capture card, Properti Audio per kanal, dan transparansi + tepi
> halus untuk media transparan — menunggu tes T-61..T-66. Virtual camera: lewat NDI → NDI Virtual Camera (0.24.0, tanpa OBS) atau Syphon → OBS Virtual Camera (Camera Extension sendiri dihapus di 0.23.0).
> 0.14.0 memperbaiki Lottie .json yang tidak tampil, menghapus menu Tambah
> Bentuk, menambah tombol "x" untuk menutup source, gembok untuk source / streaming / rekaman, konfirmasi Stop, dan
> rekam otomatis saat streaming — menunggu tes T-57..T-60.
> 0.13.2 memperbaiki crash saat dibuka di 0.13.0/0.13.1 (Lottie kini di-link statis).
> 0.13.0 menambah input Lottie (.json/.lottie), gaya layer (crop, sudut
> bulat, elips, border, bentuk), overlay ke Preview (klik) / Program (klik dua jari), dan memperbaiki tombol Tambah Layer —
> menunggu tes T-54..T-56. 0.12.0 menambah transisi custom: shader Metal milik sendiri (Baru/Impor)
> plus 6 contoh bawaan — menunggu tes T-52..T-53. 0.10.1 sama dengan 0.10.0 (input Zoom SDK dari 0.11.x ditarik dari build publik dan ditunda). 0.10.0 menambah audio follow video (AFV), input tangkap jendela/layar
> dengan audio aplikasi (untuk Zoom/Teams/Meet; Zoom SDK resmi ditunda), dan instant replay 5/10/20 detik
> dengan slow motion — menunggu tes T-45..T-47. 0.9.0 menambah tombol Fullscreen output ke layar pilihan, pilihan bus audio
> (Master/Bus A/Bus B) untuk rekaman dan tiap tujuan stream, serta satu menu "Tambah Media" / "Tambah Media Playlist"
> untuk video dan audio, plus perbaikan glitch T-bar di ujung — menunggu tes T-41..T-44. 0.8.0 menambah input playlist video, auto play saat masuk Program, dan
> transport media (seekbar, play/pause, prev/next; media dimuat dalam keadaan jeda).
> 0.7.0 menambah kontrol MIDI dengan Learn, input musik (playlist file audio
> ke mixer), dan panel dock yang bisa dikecilkan — dikompilasi & diuji unit, menunggu tes T-35..T-36. 0.6.0 (dilaporkan berfungsi) menambah browser source,
> input jam / hitung mundur / stopwatch, dan snapshot Program ke PNG.
> 0.5.0 (dilaporkan berfungsi) menambah transisi stinger dan aux bus A/B dengan output ke perangkat terpisah (mix-minus).
> 0.4.0 (dilaporkan berfungsi oleh pengguna) menambah streaming ke beberapa tujuan sekaligus (hingga 3, satu encode)
> dan transisi baru (Wipe 4 arah, Push, Slide, Iris) — dikompilasi & diuji unit, menunggu tes perangkat T-28..T-29.
> 0.3.1 memperbaiki crash capture card generik (dikonfirmasi pengguna). 0.3.0 menambah editor scene visual, lower third yang dapat diatur,
> EQ/high-pass, dan koreksi drift clock audio. Fungsi inti M1 (kamera, CUT/AUTO, meter, rekam, stream) dilaporkan
> berfungsi di Mac pengguna. M2 menambah audio file video ke mixer, noise gate, chroma key, Multiview, dan simpan/muat
> proyek — dikompilasi & diuji unit, menunggu tes perangkat T-17..T-22.
>
> Catatan M1 sebelumnya:
> Logika inti (switcher, transisi, DSP audio, FLV/RTMP) lulus 47 unit test dan uji end-to-end RTMP ke server nyata
> (ffmpeg) di Linux. Seluruh kode khusus macOS sudah ditulis dan lolos *syntax parse*, tetapi **belum dikompilasi atau
> dijalankan di macOS** karena lingkungan pembuatan tidak memiliki Mac/Xcode. Milestone 1 baru dinyatakan selesai setelah
> tes manual di `docs/TEST_PLAN.md` lulus di MacBook. Detail: `docs/TEST_RESULTS.md`.

## Mulai cepat (di Mac)
```bash
brew install xcodegen ffmpeg
swift test                        # 73 unit test inti
scripts/rtmp_e2e_test.sh          # uji RTMP end-to-end ke server ffmpeg lokal
scripts/build_macos.sh release    # generate Xcode project + build .app (Universal)
open build/DerivedData/Build/Products/Release/LiveCoreStudio.app
```
Pengembangan di Xcode: `xcodegen generate && open LiveCoreStudio.xcodeproj` → skema *LiveCoreStudio* → ⌘R.
Kebutuhan: macOS 13 Ventura+, **Xcode 16+ lengkap** (bukan hanya Command Line Tools). Mac Intel (2017+) dan Apple Silicon.

> Jika muncul `xcode-select: error: tool 'xcodebuild' requires Xcode`, pasang Xcode dari App Store, buka sekali, lalu:
> `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -license accept && xcodebuild -runFirstLaunch`.
> Cek dengan `xcodebuild -version`. Script `build_macos.sh` sekarang mendeteksi ini dan mencetak perbaikannya.

## Cara pakai singkat
1. **+** di panel Inputs → kamera / file video / gambar / judul / warna. Izinkan akses kamera & mikrofon.
2. Klik tile (atau tombol 1–9) → **Preview**. **CUT** (Space) atau **AUTO** (Return) → **Program**. Klik ganda tile = cut langsung.
3. Mixer: **+** → mikrofon/interface. Fader, M (mute), S (solo ke monitor), PGM (routing), Comp (compressor), limiter master.
4. Overlay 1–4: pilih sumber + layout (lower third, PiP), klik nomor untuk on/off (fade).
5. ⚙︎ Settings → Stream: URL + key (disimpan di Keychain) → **Start Stream** (⌘L). **Start Recording** (⌘R).
6. Jendela Program Output (ikon ⧉) dapat diseret ke monitor/proyektor eksternal → ⌃⌘F.
7. **Multiview** (ikon grid): Preview, Program, dan semua input dengan tally — cocok untuk monitor kedua.
8. **Chroma key**: klik kanan input kamera/file/gambar → Chroma Key…; lalu jadikan layer PiP atau overlay di atas latar.
9. **File video dengan suara** otomatis mendapat kanal mixer (ikon film). **Noise gate**: tombol DSP di kanal.
11. **Editor scene**: klik kanan input → Edit Scene Layers… (seret/ubah ukuran PiP). **EQ/HPF** dan status clock: tombol DSP.
10. **Proyek**: File › Save Project (⌘S) / Open Project (⌘O) menyimpan input, layer, overlay, key, mixer (tanpa stream key).

## Struktur proyek
```
Package.swift                 SwiftPM (CAtomics, LiveCoreCore, LiveCoreEngine, LiveCoreUI, app, CLI, tests)
project.yml                   XcodeGen → LiveCoreStudio.xcodeproj (Info.plist, entitlements, signing)
App/                          Entry point @main
Config/                       Info.plist, entitlements
Sources/CAtomics/             C11 atomics (lock-free untuk thread real-time)
Sources/LiveCoreCore/         Portabel & teruji: Switching/ Layout/ Audio/ Media/ RTMP/ Concurrency/ Model/ Util/
Sources/LiveCoreEngine/       macOS: Sources/ (kamera, file, gambar, warna, teks) Render/ (Metal) Audio/ Encode/
                              Output/ (streaming, recording) Devices/ System/ ProductionEngine.swift
Sources/LiveCoreUI/           SwiftUI: AppModel, Views/, Theme, Shortcuts, Resources/{en,id}.lproj
Sources/livecore-rtmp-push/   CLI validasi RTMP/FLV
Tests/LiveCoreCoreTests/      Unit test
scripts/                      build_macos.sh, bundle_spm_app.sh, rtmp_e2e_test.sh, validate_linux.sh
docs/                         Dokumentasi (lihat di bawah)
.github/workflows/ci.yml      CI Linux + macOS
```

## Dokumentasi
| Dokumen | Isi |
|---|---|
| [ENVIRONMENT.md](docs/ENVIRONMENT.md) | Analisis lingkungan, target macOS, Intel vs Apple Silicon, pilihan framework, lisensi, risiko, kriteria MVP |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Modul, diagram, aliran video/audio/data, concurrency, timestamp, pixel format, desain UI |
| [FEATURE_STATUS.md](docs/FEATURE_STATUS.md) | Implemented / partial / planned / blocked |
| [TEST_PLAN.md](docs/TEST_PLAN.md) | Tes otomatis & manual (T-01…T-16) |
| [TEST_RESULTS.md](docs/TEST_RESULTS.md) | Hasil aktual: Passed / Failed / Not tested / Blocked |
| [KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) | Batasan yang diketahui |
| [RTMP_GUIDE.md](docs/RTMP_GUIDE.md) | Konfigurasi RTMP/RTMPS per platform |
| [CAPTURE_DEVICES.md](docs/CAPTURE_DEVICES.md) | Perangkat yang didukung & cara menambah dukungan |
| [PACKAGING.md](docs/PACKAGING.md) | Build, packaging, code signing, notarisasi |

## Roadmap
- **M1 Working MVP** (kode selesai, menunggu verifikasi Mac): input kamera/file/gambar/teks/warna, Preview/Program,
  CUT/Dissolve/Fade/Wipe/T-bar, overlay & PiP dasar, mixer + compressor/limiter + meter, RTMP/RTMPS + reconnect, rekaman MP4/MOV.
- **M2 Production Workflow** — selesai di kode (0.2.0, menunggu tes perangkat): audio file video ke mixer, noise gate,
  multiview, simpan/muat proyek, chroma key. 0.3.0: koreksi drift clock, EQ/HPF, editor scene visual,
  lower third yang dapat diatur. 0.6.0: browser source. Masih planned: capture 4:2:0, optimasi performa.
- **M3 Broadcast Expansion** — 0.4.0: multi-destination streaming, transisi Wipe/Push/Slide/Iris. 0.5.0: stinger,
  aux bus A/B + mix-minus. Masih planned: Blackmagic DeckLink, AJA/Magewell SDK, NDI (perlu SDK vendor), output SDI/HDMI,
  profil operator.
