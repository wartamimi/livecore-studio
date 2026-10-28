# LiveCore Studio

Aplikasi live video production native macOS (Swift, SwiftUI, AVFoundation, Metal, Core Audio, VideoToolbox) dengan
workflow Preview/Program ala vMix/OBS untuk wedding, event korporat, seminar, dan siaran. Arsitektur dan kode orisinal —
tidak ada kode, aset, atau implementasi vMix/OBS yang disalin.

> **Status: 0.41.0 — Milestone 3 berjalan.** 0.41.0: animasi GT 60 fps lebih halus, animasi keluar mengikuti template, pasang font dari folder (font yang sudah ada dilewati). 0.40.0: editor title GT lanjutan (properti dan animasi per elemen, seret di pratinjau, ganti gambar) dan unduh font otomatis dari Google Fonts. 0.39.0: impor template title vMix GT (.gtzip) — kotak, gradasi, teks, gambar dan animasi masuk Reveal/Expand/Zoom, teks bisa diubah (Text3D digambar datar; lihat FEATURE_STATUS). 0.38.0: jendela edit Web kini menampilkan seluruh halaman diperkecil pas ke jendela (tidak nge-zoom/terpotong, scroll jalan) dan fullscreen di halaman memakai ukuran input; PRE-FLIGHT pindah ke Pengaturan; switch Operator/Lanjutan dihapus; animasi title tidak lagi tersendat saat menu dibuka, antrean GPU 3 frame dan log penyebab FPS drop; build DMG di CI lebih cepat; dan input baru Radio Online dari direktori gratis Radio Browser (HTTPS MP3/AAC, judul lagu, sambung ulang otomatis). 0.37.0 adalah rilis stabilisasi dari hasil evaluasi: simpan otomatis tiap 30 detik dengan tawaran pemulihan setelah crash, undo/redo (⌘Z) untuk input, Layer Designer, Title Designer dan editor scene, log di disk dan menu Ekspor Log & Diagnostik (tanpa stream key), mode Operator/Lanjutan, panel OUTPUTS, pemeriksaan PRE-FLIGHT sebelum live, template proyek (Pernikahan, Seminar, Rapat) di layar sambutan, meter LUFS (EBU R128) dan ducking musik otomatis, sumber data title dari CSV/Excel/Google Sheets, kontrol kamera PTZ (VISCA), kontrol Stream Deck lewat Companion (docs/COMPANION.md), output SRT, label Eksperimental untuk fitur yang rentan, dan uji soak otomatis di CI (rekam + stream, stream diputus di tengah, disk penuh). Belum: input SRT, tamu WebRTC, Developer ID/auto-update (butuh akun Apple Developer). 0.36.1: tombol fullscreen di halaman web (YouTube, Vimeo, Facebook, player embed) kini membuat video memenuhi gambar input, bukan layar Mac; dan memperbaiki layar hitam setelah Selesai bila jendela edit web sempat dibuat layar penuh. 0.36.0: input Web diperbaiki dan dibuat seperti vMix — "Edit halaman" kini membuka jendela biasa dengan bar alamat, back/forward, reload dan tombol Selesai (di 0.35.0 jendela itu menutupi app), suara halaman masuk ke channel "Web audio" di mixer (macOS 14.2+), plus opsi video saja (video halaman mengisi gambar), zoom, CSS kustom dan bisukan; title bisa dianimasikan per huruf (mesin ketik, memudar, naik, turun, membesar) setiap kali tampil; input PowerPoint punya mode Live: PowerPoint memutar slideshow di jendela dan input menangkap gambar dan suaranya sehingga animasi, transisi dan video ikut tampil (seperti vMix, butuh PowerPoint); input baru Frame kamera dengan 8 template (bingkai bersih, membulat, lingkaran, polaroid, neon, broadcast, vertikal 9:16, sinema); tombol Page Down/Page Up (clicker presentasi) mengganti slide; dan foto dari tombol PHOTO bisa langsung dijadikan input. 0.35.0: menekan nomor overlay (1-4) kini memutar animasi masuk/keluar yang diatur per template title/lower third (tab Animasi di Title Designer, ada tombol "Coba animasi"); teks berjalan pindah ke Title Designer (kategori Teks berjalan, 6 template) dengan setelan lanjutan (label BREAKING/NEWS, pemisah, font, ketebalan, huruf besar, posisi pita atas/bawah/kustom, bayangan, animasi); input media otomatis play saat CUT/AUTO ke Program dan kembali ke awal saat keluar, dengan tombol AUTO dan ↺ restart on/off di tile (off = lanjut dari posisi terakhir, seperti vMix); ISOCorder bisa memilih bus audio (Master / Aux A / Aux B) per input; tombol minimize input pindah ke baris atas di antara tombol fullscreen dan X; tombol PHOTO memberi kilat dan notifikasi "Foto tersimpan" (klik untuk buka di Finder); input Web punya mode "Edit halaman" untuk klik dan mengetik di halaman lalu "Selesai — tampilkan"; dan input baru PowerPoint / Keynote / PDF (slide sebelumnya/berikutnya, nomor slide). 0.34.0 menambah Title Designer: 21 template (12 lower third, 6 judul, 3 pojok: strap klasik/membulat, dua warna, nama berkotak, garis aksen, kaca modern, berita LIVE, garis bawah, pil, akun sosmed, bar selebar layar, strap kanan, headline, judul layar penuh, bab, kutipan, penutup, banner breaking, logo pojok, label lokasi, badge LIVE) dengan pratinjau langsung dan setelan lanjutan seperti vMix: font, ketebalan, miring, huruf besar, jarak huruf & baris, rata, warna per teks, kotak/kotak kedua/aksen, sudut & pil, padding, lebar minimum, posisi 9 titik + geser + margin aman + ukuran, outline dan bayangan. Dock bawah kembali bersih: teks status di samping ⚙ dihapus (status ada di tooltip dan panel ⚙) dan tombol diberi jarak dari ⚙. 0.33.1 mengganti nama MultiCorder menjadi ISOCorder (tombol ISOCORDER) dan merapikan dock bawah: tata letaknya menyesuaikan lebar jendela (lebar: status di samping tombol; sedang: status lebih ringkas, chip OUT tanpa nama sumber; sempit: status singkat di dalam tombol) sehingga teks tidak terpotong; status lengkap selalu ada di tooltip. 0.33.0 memisahkan MultiCorder dari RECORD: tombol ISOCORDER sendiri di dock, pilih input sendiri (maks 4) dan profil rekaman sendiri (bawaan HEVC 25 Mbps MOV). Recorder dan MultiCorder kini punya setelan lanjutan: H.264 / HEVC / ProRes 422 (Proxy, LT, 422, HQ), bitrate 2–150 Mbps, interval keyframe, B-frame, audio AAC 128–320 kbps atau PCM 24-bit, plus perkiraan GB per jam. Encoder hardware diminta untuk setiap file, B-frame mati secara bawaan, dan jumlah frame terbuang tiap file tampil di dock. Panel input mendapat label warna (8 warna): input berwarna sama otomatis masuk satu grup dengan judul yang bisa diganti nama, filter per warna, dan tiap input bisa di-minimize menjadi baris ringkas seperti vMix. 0.32.0 menambah MultiCorder (rekaman ISO): sampai 4 input pilihan
> ikut direkam ke file masing-masing selama RECORD berjalan ("… - ISO 2 Kamera Wide.mp4"), ukuran penuh dengan
> layer-nya, audio & format sama dengan rekaman Program — untuk edit ulang wedding/event. Diuji di CI macOS
> (`livecore-iso-check`: file Program + ISO bersamaan, keduanya bisa diputar dengan video+audio); menunggu tes
> T-131..T-133. 0.31.0 mendesain ulang Web Controller menjadi panel switcher bergaya
> hardware: gambar Program/Preview langsung (JPEG ±3 fps, hanya saat halaman dibuka), dua baris bus Preview/Program
> dengan tombol menyala, tuas T-bar besar (horizontal di HP, vertikal di tablet), pilihan jenis dan durasi transisi,
> mixer audio (fader master & per kanal, mute, meter), LED REC/LIVE dengan timer, keypad PIN, dan getaran saat ditekan
> (Android). Menunggu tes T-127..T-130. 0.30.0 menambah Web Controller: remote dari browser HP, tablet atau
> komputer lain di jaringan yang sama (tanpa install aplikasi) untuk Preview, CUT, AUTO, T-bar, overlay 1–4, instant
> replay, rekam, streaming dan snapshot, dengan status Program/Preview langsung. Mati secara default; dikunci PIN yang
> disimpan di Keychain, perangkat dikunci sementara setelah 5 PIN salah, ada QR code untuk masuk cepat (Settings ›
> Remote). Server diuji otomatis di CI (Linux dan macOS); menunggu tes T-119..T-126. 0.29.0 menambah input NDI®: sumber NDI di jaringan (HP dengan aplikasi
> kamera NDI, OBS/vMix di komputer lain, kamera NDI) bisa ditambahkan sebagai input, lengkap dengan audionya di mixer,
> pilihan bandwidth rendah, dan info sinyal — diuji di CI (input LiveCore menerima sumber NDI dari proses lain), menunggu
> tes T-116..T-118. 0.28.0 menambah bagian "Lanjutan" di pengaturan capture card: format video
> perangkat (mis. YUY2/NV12 uncompressed atau MJPEG/H.264), perbaikan rentang warna (limited ↔ full), deinterlace,
> buffer frame, info sinyal (format aktif, fps terukur, frame terbuang) dan tombol mulai ulang perangkat — menunggu tes
> T-112..T-115. 0.27.0 memperbaiki crash instant replay (macOS 27), menghapus tombol
> Terapkan/Batalkan Layer Designer — edit layer tetap hanya di Preview dan baru masuk Program saat transisi (CUT, AUTO,
> T-bar) —, mengganti T-bar menjadi horizontal dengan angka persen saja, dan menambah Repeat One, "Berhenti setelah item
> ini", bar waktu dengan seek (berjalan/sisa), serta "Putar berikutnya" di playlist — menunggu tes T-107..T-111. 0.26.0: edit di Layer Designer kini berupa draft yang hanya tampil di Preview
> sampai Terapkan / tutup / CUT / AUTO / T-bar, geser & ubah ukuran layer lebih halus, label FULLSCREEN satu baris, kamera
> dan capture yang sudah dipakai tidak bisa ditambahkan dua kali, tombol Repeat/Shuffle playlist menyala saat aktif (video
> playlist juga bisa diacak), T-bar baru bergaya tuas broadcast, dan Settings › Canvas (Horizontal 16:9, Portrait 9:16,
> Custom) dengan monitor yang mengikuti bentuk canvas — menunggu tes T-101..T-106. 0.25.0 menambah Layer Designer di monitor Preview (geser/ubah ukuran
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
