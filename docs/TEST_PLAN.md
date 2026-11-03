# Test Plan — Milestone 1 & 2

## A. Tes otomatis (dapat dijalankan di Linux dan macOS)
| ID | Tes | Perintah |
|---|---|---|
| A-01 | Unit test LiveCoreCore (73 tes; 0.3.0 menambah drift compensator, EQ/biquad, editor layer, kompatibilitas proyek 0.2.0; M2 menambah resampler, noise gate, chroma key, file proyek; M1: switcher, transisi, overlay, layout, DSP, ring buffer lock-free, clock anchor, AMF0, AVC/AAC, FLV, RTMP URL/chunk/sesi, antrean kongesti, settings) | `swift test` |
| A-02 | E2E RTMP: publish H.264 High 720p30 + AAC 48k selama 10 s ke server RTMP ffmpeg, verifikasi ffprobe + decode semua frame | `scripts/rtmp_e2e_test.sh` |
| A-03 | E2E FLV writer → ffprobe | (bagian dari A-02) |
| A-04 | Kegagalan koneksi: server tidak ada, server memutus di tengah stream; stream key tidak bocor di log | (bagian dari A-02) |
| A-06 | Kompilasi shader Metal offline (sintaks/tipe semua fungsi shader, termasuk `key_fragment`) | `scripts/check_shaders.sh` (Mac) |
| A-08 | NDI: proses lain menemukan sumber NDI LiveCore dan menerima frame 1280×720 merah (runtime NDI dipasang di CI) | `scripts/install_ndi_runtime.sh && LIVECORE_NDI_REQUIRED=1 swift run livecore-ndi-check` (Mac, di CI) |
| A-07 | Render Lottie offscreen (fixture: kotak merah kiri-atas, kotak biru kanan-bawah mulai 1 s): terlihat, orientasi benar, beranimasi | `swift run livecore-lottie-check` (Mac, di CI) |
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


## C. Tes manual Milestone 2 (build 0.2.0)
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-17 | Audio file video masuk mixer | + → File Video (file dengan suara). Tunggu kanal baru (ikon film) di mixer | Meter kanal bergerak; fader/mute/PGM bekerja; suara **tidak** terdengar dua kali; hapus input → kanal ikut hilang |
| T-17b | Sinkronisasi audio file | Putar klip dengan ucapan, rekam 30 s | Bibir vs suara di rekaman ≤ 2 frame (catat selisih; offset A/V global bisa dipakai) |
| T-17c | Sample rate 44.1 kHz | Pakai klip AAC 44.1 kHz | Nada/kecepatan normal, tanpa klik berkala |
| T-18 | Noise gate | Kanal mikrofon › DSP › Noise Gate Enabled, threshold −45 dB | Saat diam, meter turun & status "Closed"; saat bicara terbuka tanpa terpotong di awal kata |
| T-19 | Multiview | Klik ikon grid di top bar; seret jendela ke monitor kedua | Preview, Program dan semua input tampil, tally merah/hijau benar, klik = Preview, klik ganda = Cut |
| T-20 | Chroma key | Kamera di depan green screen (atau klip green screen) › klik kanan › Chroma Key… › Enable; atur Similarity/Smoothness; tambahkan sebagai layer/overlay di atas latar | Latar hijau hilang di Preview/Program/rekaman, tepi halus, kulit dan baju tidak ikut hilang; GPU ms/frame tetap < 80% budget |
| T-21 | Simpan & buka proyek | Susun 4+ input, layer PiP, overlay, chroma key, setelan mixer; File › Save Project; quit; buka lagi › File › Open Project | Semua input, layer, overlay, key, fader/mute/gate kembali; stream key tidak ada di file `.livecore` |
| T-21b | Proyek dengan perangkat/file hilang | Buka proyek setelah mencabut kamera / memindah file | Muncul peringatan yang menyebut perangkat/file; sisanya tetap termuat; app tidak crash |
| T-22 | Beban M2 | 1080p30, 2 kamera (1 dengan chroma key) + 1 klip video + Multiview terbuka, stream + rekam 30 menit | Catat seperti T-13; FPS stabil, tanpa dropped frame bertambah terus |

## AZ. Tes manual build 0.48.0

| ID | Langkah | Hasil yang diharapkan |
|---|---|---|
| T-250 | Buka panel OUTPUTS | Hanya FULLSCREEN (atas) dan EXTERNAL |
| T-251 | Lihat bar bawah | Tombol MULTICORDER; tidak ada EXTERNAL dan OUT1–OUT4 |
| T-252 | Lihat bar atas | Ada RUNDOWN, 9:16, ikon Multiview; tidak ada menu Tools / Fullscreen. Ikon Multiview membuka jendela Multiview |
| T-253 | Mixer › + › Tambah AUX / BUS sampai 4, kirim channel ke C dan D, pilih device output untuk AUX C | Strip AUX C/D muncul, meter bergerak, suara keluar di device; simpan & buka proyek: routing tetap |
| T-254 | Playlist video: tahan dan seret item ke atas/bawah | Urutan berubah dan tersimpan |
| T-255 | Tambah playlist video baru | Loop mati |
| T-256 | Tambah input Browser (mis. YouTube), Edit, Done, lalu Edit lagi | Halaman tidak reload, posisi video tetap; jendela Edit bisa digeser/diubah ukurannya; output tetap jalan |
| T-257 | Saat live, buka menu + Input dan submenu Warna selama 1 menit | Menu tidak berkedip; FPS di bar atas stabil |
| T-258 | Properti input › Warna › Muat .cube (LUT dari Resolve/kamera), atur Kekuatan | Warna berubah sesuai LUT, 0% = asli; simpan & buka proyek: LUT tetap |
| T-259 | Warna › Generator LUT: pilih preset, geser slider, Simpan & Terapkan; lalu Batal di sesi lain | Input berubah live; Simpan menaruh .cube di pustaka; Batal mengembalikan LUT sebelumnya |
| T-260 | Generator LUT › Ekspor .cube, buka di DaVinci Resolve | Resolve menerima file, tampilan sama |
| T-261 | Help › Bantuan LiveCore Studio (⌘?) dengan bahasa Indonesia, lalu Inggris | Topik dan isi mengikuti bahasa; pencarian jalan |
| T-262 | Menu LiveCore Studio › Tentang | Ikon, versi 0.52.0 (69), deskripsi singkat, "Dibuat oleh Munawar Tamimi" |
| T-263 | Drop saat buka app (0.49.0) | Buka app tanpa input, tunggu 30 dtk | Drop tetap 0 (pemanasan 5 dtk pertama tidak dihitung, dicatat di log); klik angka Drop → kembali 0 |
| T-264 | Loop default off | Tambah 1 video dan 1 playlist | Repeat/Loop mati untuk keduanya |
| T-265 | Menu Program | Klik 2 jari di monitor Program | Menu Screenshot (PNG + banner) dan Grab as Still (PNG jadi input gambar baru) |
| T-266 | OUTPUTS di bawah | Lihat top bar dan dock bawah | Tombol FOTO tidak ada; OUTPUTS ada di dock bawah (bekas FOTO), tidak di atas; ⇧⌘O tetap membuka |

## AZ. Tes manual build 0.50.0

| ID | Area | Langkah | Hasil yang diharapkan |
|---|---|---|---|
| T-267 | Bacaan di kanan bawah | Lihat bar atas dan dock bawah | CPU, GPU, RAM, FPS, Drop, status STREAM dan REC ada di kanan bawah dock, tidak lagi di bar atas; klik Drop = reset |
| T-268 | Realtime Transcription | + Input › Grafis › Realtime Transcription (Live subtitles (AI) sudah tidak ada di menu), isi API key, Apply, bicara ke mic yang masuk Program | Status "Live (ElevenLabs)"; satu kalimat per tampilan (tidak bertumpuk), baris tidak melompat, kalimat panjang ganti halaman; hilang setelah 4 dtk diam |
| T-269 | Transcription error | Isi API key salah | Input menampilkan pesan "ElevenLabs refused the API key"; app tidak macet |
| T-270 | Transcription koneksi | Saat transkripsi jalan, matikan Wi-Fi 10 dtk lalu nyalakan | Tersambung lagi sendiri; teks muncul lagi |
| T-271 | Audio advanced | Properti audio channel › EQ: geser Low freq / Mid Q / High freq, nyalakan LPF 4 kHz | Kurva EQ berubah; suara mengikuti tanpa klik |
| T-272 | Gate & kompresor | Gate: Attack/Hold/Release; Kompresor: Knee | Perilaku gate/kompresor berubah sesuai |
| T-273 | Limiter channel | Tab Limiter: nyalakan, Ceiling −6 dB, teriak ke mic | Meter channel tidak lewat −6 dB; GR terlihat |
| T-274 | Simpan proyek | Ubah semua setelan advanced, simpan, buka lagi | Semua nilai kembali |
| T-275 | Audio Monitor web | Web Controller di HP › Mixer audio › 🎧 Dengar, pilih Master lalu Bus A | Suara mix terdengar di HP (≈0,3–0,5 dtk terlambat), tanpa putus di Wi-Fi yang sama; volume slider bekerja |
| T-276 | Audio Monitor tunnel | Sama, lewat Cloudflare tunnel (4G) | Terdengar; boleh sesekali patah jika sinyal lemah |
| T-277 | Keychain sekali | Pasang build 0.51.0 di atas versi lama, buka app, mulai stream/transcription | Password diminta paling banyak SATU kali (klik Always Allow); tidak diminta lagi selama build ini |
| T-278 | Keychain tanpa prompt | Settings › Security › "Keychain, never ask" atau "Local file"; tutup & buka app | Tidak ada prompt password; stream key, PIN, API key ElevenLabs masih ada |
| T-279 | Bendera | Input + › Bendera…, cari Indonesia, Animate on, Add | Input "Flag – Indonesia", proporsi 2:3 benar, berkibar halus di Preview/Program tanpa drop |
| T-280 | Atur kibaran | Properties › Warna, Orientasi & Mask › Wave: ubah tinggi/kecepatan, matikan | Berubah langsung; mati = bendera diam |
| T-281 | Mask bentuk | Kamera › Mask Circle, soft edge 0,05; lalu Rectangle radius 0,2; Invert | Gambar terpotong lingkaran/kotak membulat dengan tepi halus di semua output dan layer |
| T-282 | Mask gambar | Mask Image (white = visible) dengan PNG hitam-putih | Area putih terlihat, hitam transparan |
| T-283 | Transcription Advanced | Realtime Transcription › Advanced: vocabulary nama mempelai, ElevenLabs keyterms, silence 0,8 s, clear 2 s, UPPERCASE | Nama dikenali lebih baik, kalimat berganti lebih cepat, teks huruf besar, hilang 2 dtk setelah diam |
| T-284 | LCS Live lokal | + Input › LCS Live › Uji di Mac ini › Buka (Safari/Chrome di Mac yang sama), isi nama, Gabung, izinkan kamera/mic | Status di sheet "<nama> sedang terhubung"; input menampilkan kamera tamu; kanal mixer "LCS Live" bergerak saat bicara |
| T-285 | Return feed | Saat T-284 berjalan, masukkan input lain ke Program dan putar musik | Halaman tamu menampilkan Program (≈12 fps) dan memutar suara acara TANPA suara tamu sendiri (mix-minus); matikan toggle return → gambar hitam/suara berhenti |
| T-286 | Link online | `brew install cloudflared`, sheet › Buat link online, buka link di HP (4G) | Halaman https terbuka, kamera HP masuk ke input, HP mendengar mix-minus; catat jenis jaringan bila gagal tersambung |
| T-287 | Putus & sambung | Matikan Wi-Fi HP 10 dtk lalu nyalakan | Halaman tamu "menyambung ulang…" lalu terhubung lagi tanpa operator berbuat apa-apa |
| T-288 | Tutup / Link baru | Tutup panggilan dari sheet; lalu Link baru | Tamu terputus; link lama menampilkan "Link panggilan tidak aktif" |
| T-289 | Dua tamu | Tambah 2 input LCS Live, dua perangkat bergabung | Dua input & dua kanal terpisah; masing-masing tidak mendengar suaranya sendiri |
| T-290 | TURN | Isi server TURN di Advanced, uji dari jaringan kantor/4G yang sebelumnya gagal | Tersambung lewat relay |
| T-291 | Optimasi 0.53.0 | Proyek yang sama di 0.52.0 lalu 0.53.0 (browser input + LCS Live + ticker), catat CPU/RAM Activity Monitor 5 menit | CPU/RAM 0.53.0 sama atau lebih rendah, tidak ada drop baru |
| T-292 | LCS Live 0.53.0 | Tamu tersambung, dengarkan return audio di sisi tamu 5 menit | Audio balik mulus tanpa putus-putus, video Program ≈12 fps |
| T-293 | Audio Monitor 0.53.0 | Web Controller › 🎧 Dengar, ganti bus, kunci layar HP lalu buka lagi | Suara jalan, ganti bus langsung pindah, tidak macet
| T-294 | Input SRT Dengar (0.54.0) | Tambah input › Stream SRT, mode Dengar port 9000. Di OBS (Mac/PC lain di LAN): Stream › Custom, Server = alamat yang ditampilkan LiveCore (srt://IP:9000?mode=caller…), Start Streaming | Input LIVE dalam ±2 dtk, gambar & suara benar, kanal mixer "SRT :9000" bergerak; Stop di OBS → "No signal", Start lagi → kembali LIVE sendiri |
| T-295 | Input SRT Panggil | Larix Broadcaster/encoder hardware dalam mode listener; di LiveCore mode Panggil + alamat encoder | LIVE; matikan encoder 10 dtk lalu nyalakan → menyambung lagi sendiri |
| T-296 | SRT di internet / sinkron | Encoder lewat 4G/internet, latensi 1000 ms; tepuk tangan di depan kamera encoder | Gambar mulus (statistik "hilang" naik tapi "dibuang" tetap 0 atau kecil), suara tepuk pas dengan gambar (selisih ≤ 1 frame); catat RTT/hilang/pulih dari jendela input |
| T-297 | DeckLink terdeteksi | Pasang Blackmagic Desktop Video, colok DeckLink/UltraStudio, Tambah input › Blackmagic | Kartu muncul di daftar dengan konektor & format; tanpa Desktop Video muncul pesan + link unduh |
| T-298 | DeckLink SDI/HDMI | Kamera SDI (atau HDMI) 1080p25/1080i50/1080p59.94, format "Deteksi otomatis" | Input LIVE, gambar & warna benar (tidak hijau/ungu, hitam pekat), fps sesuai sumber; ganti format di kamera → menyesuaikan sendiri |
| T-299 | DeckLink audio | Audio tertanam SDI/HDMI | Kanal mixer "DeckLink …" bergerak, suara jernih tanpa klik, sinkron dengan gambar |
| T-300 | DeckLink cabut / app lain | Cabut kabel SDI, colok lagi; lalu buka OBS memakai kartu yang sama | Cabut → "No signal", colok → LIVE lagi; bila dipakai app lain muncul pesan, dan input pulih setelah app lain ditutup |
| T-301 | Web Controller mulus (0.54.1) | HP di Wi-Fi yang sama lalu lewat link online: buka Web Controller 5 menit, nyalakan 🎧 Dengar Master | Gambar Program/Preview lancar tanpa macet berkala, suara tidak putus-putus; Activity Monitor: CPU app tidak naik dibanding tanpa HP |
| T-302 | Koneksi lemah (0.54.2) | Web Controller lewat link online di sinyal lemah (atau Network Link Conditioner "3G" di Mac), 🎧 Dengar Master, tekan CUT beberapa kali | Lampu oranye + "Koneksi lemah"; gambar lebih kecil tapi tetap jalan (Program ±5 fps), suara mono tidak putus (tunda naik maks 1,5 dtk); CUT tidak pernah dobel; sinyal pulih → normal lagi dalam ±15 dtk |
