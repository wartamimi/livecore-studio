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
| T-303 | Preview input mulus (0.55.0) | Tambah kamera + video, putar video | Thumbnail input bergerak halus (±25–30 fps), tidak patah-patah; CPU/GPU tidak naik jauh |
| T-304 | Meter audio di tile (0.55.0) | Input video ber-audio dan kamera dengan audio terhubung (AFV) | Meter kecil di kanan gembok bergerak sesuai suara; input tanpa audio tidak punya meter |
| T-305 | Label warna (0.55.0) | Klik kanan input › Label warna › Tambah Label…, pilih warna + nama; lalu Tanpa label | Input masuk grup berwarna dengan nama itu; chip "Semua" abu-abu; Tanpa label mengeluarkan input dari grup |
| T-306 | Sinkron playlist (0.55.0) | Klik play/pause di tile video lalu lihat dock Playlist (dan sebaliknya) | Ikon play/pause di Playlist ikut berubah dalam ±0,25 dtk |
| T-307 | Menu baru (0.55.0) | LiveCore Studio › Pengaturan… (⌘,), View › Mode Multiview (⌥⌘M), Production › Buat Rundown… (⇧⌘R) | Settings, jendela Multiview dan Rundown terbuka; tombol 9:16 sudah tidak ada |
| T-308 | Bottom bar & panel (0.55.0) | Klik TAMBAH INPUT di pojok kiri bawah, coba semua jenis; cari tombol minimise di Transition/Audio Mixer | Menu input sama dengan + di panel Inputs (dengan ikon), sheet terbuka walau panel Inputs diminimalkan; Transition/Mixer tanpa tombol minimise; Rundown jadi ikon di kanan atas |
| T-309 | Import Media 1 file (0.55.0) | Tambah Media, coba pilih 2 file; lalu Tambah Media Playlist pilih 3 file | Tambah Media hanya bisa pilih 1 file; playlist tetap boleh banyak |
| T-310 | Controller Program (0.55.0) | Video di Program: pakai ⏮ ◀◀ ▶/❚❚ ▶▶ dan seek; presentasi di Program; kamera di Program; perkecil jendela | Video/presentasi bisa dikontrol dari bawah Program; kamera → tombol abu-abu; di jendela sempit sisa waktu dan AUTO/↺ disembunyikan |
| T-311 | Follow-up UI (0.55.1) | Kamera di Program; arahkan kursor ke ikon Multiview/Settings atas; Tambah Media 1 video; Tambah Media Playlist; perkecil jendela | Controller di bawah Program hilang untuk kamera; tombol atas ber-hover dan bisa ditekan; dock Playlist tidak muncul untuk 1 video, muncul terbuka untuk playlist baru; status Offline/REC tetap satu baris (jadi ikon saat sempit) |
| T-312 | Hemat RAM/CPU (0.56.0) | 10+ input (kamera, gambar/logo, judul, video); buka Activity Monitor; catat %CPU dan Memory LiveCore saat jendela tampil, saat di-minimize, dan saat Multiview ditutup; geser daftar input; mixer audio dengan beberapa channel diam; tambah lalu hapus 5 video/browser/slideshow, tunggu 15 detik, Export Logs | Thumbnail & Preview tetap bergerak lancar saat tampil; CPU/GPU turun saat jendela di-minimize/tertutup dan untuk input statis; meter audio tetap bergerak normal; Program, stream dan rekaman tidak terpengaruh; setelah menutup viewer/MultiCorder memori turun dalam beberapa detik; setelah input dihapus RAM/CPU kembali turun dan log tidak berisi "still in memory" |
| T-313 | ~~Groq transcription (0.57.0)~~ dihapus di 0.66.0 | Buat API key di console.groq.com; Add Input › Realtime Transcription; Model = Groq, isi key, bahasa Indonesia; pasang di overlay; bicara 1 menit dengan jeda; ulangi dengan model turbo; coba key salah | Teks muncul ±2–6 detik setelah kalimat selesai; saat hening tidak muncul "Terima kasih"; key salah → pesan "Groq refused the API key"; batas rate → menunggu lalu lanjut |
| T-314 | Jendela Transkrip (0.57.0) | Klik kanan input Realtime Transcription › Open Transcript Window; bicara beberapa kalimat (Apple, ElevenLabs, Groq); pilih sebagian teks ⌘C; Copy All; Save as Text…; Timestamps; Clear | Kalimat bertambah di bawah dan otomatis menggulir; seleksi tidak hilang saat teks baru masuk; teks tersalin/tersimpan utuh; Clear mengosongkan jendela tanpa menghentikan caption |
| T-315 | QR Code – isi & gaya (0.58.0) | ADD INPUT › Grafis › QR Code; template Angpao digital; Baca dari gambar QR… (QRIS bank); ganti titik Bulat, warna, logo, posisi kanan bawah; tambah item ke-2 jenis Link (materi) dan ke-3 Wi-Fi; scan tiap item dari layar Program dengan HP | Kode terbaca HP (QRIS membuka aplikasi pembayaran yang benar, Link membuka halaman, Wi-Fi menawarkan bergabung); logo tidak membuat kode gagal; judul/keterangan tidak terpotong |
| T-316 | QR Code – tampil (0.58.0) | Klik nomor overlay di bawah tile QR (Preview), CUT; klik kanan input › Show / hide on Program; set Sembunyikan setelah 15 s; Web Controller: tombol QR, ◀ ▶ | QR masuk/keluar dengan animasinya; turun sendiri setelah 15 s; ganti item saat tayang langsung berubah; Web Controller menampilkan status merah saat on air |
| T-317 | Tanda highlight (0.58.0) | REC; tekan ⇧⌘H, ★ MARK di Web Controller, dan tombol MIDI yang di-map ke "★ Highlight mark" di momen berbeda; buka Production › Highlights… (⇧⌘J) | Semua tanda muncul dengan waktu yang benar; file `.highlights.json` ada di sebelah rekaman; menghapus / mengganti keterangan tersimpan |
| T-318 | Video highlight (0.58.0) | STOP REC; Highlights › Sebelum 15, Sesudah 10, crossfade 0,75, 16:9 › Buat video highlight…; ulangi 9:16 dan "Simpan juga tiap momen"; tutup app, buka lagi, Open recording… | Satu MP4 berisi semua momen berurutan dengan crossfade gambar & suara, fade awal/akhir; 9:16 = crop tengah 1080×1920; klip terpisah di folder sebelah; setelah app dibuka ulang tanda dibaca dari .highlights.json |
| T-319 | Virtual Set – susun (0.59.0) | Kamera di depan green screen (pinggang ke atas, di tengah); ADD INPUT › Grafis › Virtual Set…; pilih Meja berita, Talent 1 = kamera; Add; coba tiap template (klik kanan › Edit virtual set…) termasuk Panggung debat / Studio podcast dengan 2 talent | Green screen hilang (key otomatis), talent berdiri di studio, bagian bawah tertutup meja/podium; tile input menampilkan studio + talent; set tidak menyisakan area kosong |
| T-320 | Virtual Set – layar & shot (0.59.0) | Layar studio = input slide/video; Shot Wide → Medium → Close; geser ukuran/posisi talent; ubah teks & warna aksen; simpan proyek, buka lagi | Input tampil di layar studio; shot memperbesar studio dan talent bersama; pengaturan & talent kembali sama setelah proyek dibuka |
| T-321 | Title 3D (0.59.0) | Title Designer › Lower third: 3D krom, 3D emas; Title: 3D headline, 3D sinematik; Try animation; pasang di overlay, klik nomor overlay masuk lalu keluar; tab 3D: ubah kedalaman, arah, warna sisi, miring, gerak, matikan 3D | Teks dan kotak tampak tebal (sisi gelap) dan berkilau; gerak 3D halus ±30 fps; saat keluar overlay menunggu gerak selesai; mematikan 3D → title datar dan tetap datar setelah proyek dibuka ulang |
| T-322 | Running text 3D (0.59.0) | Title Designer › Running text: 3D krom / 3D emas / 3D neon / 3D kubus berita; pasang di overlay, masuk & keluar; ubah gerak 3D | Pita tampak tebal dengan tepi terang/gelap, teks ber-extrusion tetap bergulir halus; pita berputar masuk/keluar; CPU tidak naik mencolok dibanding running text biasa |
| T-323 | Plugin Audio Unit di channel (0.60.0) | Mixer › tombol FX di channel mic › Tambah Plugin › Audio Units › Apple › AUDelay (atau plugin AU milik Anda); bicara ke mic; Edit; ubah parameter; bypass; urutkan 2 plugin | Efek terdengar di Program & monitor; label TERPISAH; jendela editor plugin terbuka; bypass langsung mematikan efek tanpa klik; CPU % tampil |
| T-324 | Plugin di master (0.60.0) | Master › FX › tambah AUPeakLimiter / plugin loudness; stream/rekam 1 menit | Efek ada di rekaman & stream; LUFS master mengikuti; tidak ada dropout |
| T-325 | Plugin VST3 (0.60.0) | Pasang plugin VST3 gratis (mis. efek dari vendor yang menyediakan build macOS universal); FX › Pindai ulang › Tambah Plugin › VST3; Edit, ubah knob | Plugin muncul di daftar (yang gagal dimuat tercantum "gagal" beserta alasan); editor tampil dan bisa di-resize bila plugin mendukung; perubahan knob terdengar |
| T-326 | Simpan & crash (0.60.0) | Simpan project dengan plugin + setelan, tutup, buka lagi; lalu matikan paksa LiveCore (Activity Monitor › Force Quit) saat plugin VST3 aktif, buka lagi | Plugin & setelan kembali sama; setelah force quit muncul pesan mode aman dan plugin VST3 dimulai bypass; plugin yang tidak terpasang tetap tersimpan sebagai "Not installed" |
| T-327 | Tutup aplikasi (0.61.0) | Tambah input video (play), musik, Browser, buka Program Output; klik tombol merah jendela utama. Ulangi saat streaming/rekam | Aplikasi keluar dan semua suara berhenti seketika, tidak ada LiveCore di Dock/Activity Monitor; saat live muncul konfirmasi dan Batal membiarkan semua tetap jalan |
| T-328 | Media controller Preview & Play di akhir (0.61.0) | Taruh input video di Preview; pakai play/pause/seek/loop di bawah Preview; biarkan klip habis lalu tekan Play (Preview, Program, tile input, musik) | Kontrol bekerja di Preview; Play di akhir klip memutar ulang dari awal tanpa menggeser seek bar |
| T-329 | Gambar semua format (0.61.0) | Tambah gambar HEIC, WebP, AVIF, TIFF, PSD, PDF, SVG, foto iPhone portrait | Semua tampil, orientasi benar; PDF halaman pertama; SVG tampil (macOS yang mendukung) atau pesan "Cannot decode image" |
| T-330 | Pixabay (0.61.0) | Add Input › Online Library by Pixabay; isi API key; cari "wedding" Foto lalu Video; pilih 2, Tambah | Hasil & thumbnail tampil; 2 input baru (gambar/video) setelah unduhan; key salah memberi pesan jelas |
| T-331 | Tailscale (0.61.0) | Settings › Web Controller › Online: pilih Tailscale, Mulai; buka alamat .ts.net di HP yang login tailnet yang sama; coba Funnel dari HP tanpa Tailscale | Alamat https .ts.net + QR tampil, controller jalan dengan PIN; bila belum diizinkan, link persetujuan tampil; Stop menghapus serve |
| T-332 | Web Controller baru (0.62.0) | Buka Web Controller di HP, tablet dan laptop; nyalakan LISTEN; biarkan 10 menit lewat Wi-Fi lalu lewat tunnel | Tata letak pas di tiap layar tanpa geser ke samping; gambar lancar; suara tidak putus-putus; angka Ping/FPS tampil |
| T-333 | Shortcut keyboard (0.62.0) | Settings › Shortcuts: pastikan kosong; pilih preset Classic; tekan 1, ⇧2, Space, Return; ketik di kolom teks | Shortcut jalan; saat mengetik di kolom teks tidak ada yang terpicu; Clear All mengosongkan |
| T-334 | Layer edit klik 2x (0.62.0) | Mode edit layer; beri nama layer panjang; klik 2x satu layer | Nama terpotong tanpa menimpa ikon; popover opsi muncul dan tiap opsi bekerja |
| T-335 | Animation (0.62.0) | Properties input › Animation; coba tiap Motion, Mask/Wave, LUT | Gerak terlihat di Preview/Program, tidak ada layar hitam |
| T-336 | Template & Recent (0.62.0) | File › Save as Template…; File › New from My Template; File › Open Recent | Template tersimpan dan terbuka sebagai proyek tanpa judul; daftar recent benar |
| T-337 | Appearance (0.62.0) | Settings › Appearance: ganti tema, aksen, tally aman, tiap susunan dock | Warna dan susunan berubah langsung dan tetap setelah aplikasi dibuka ulang |
| T-338 | Playlist (0.63.1) | Klik 1x lalu klik 2x satu klip di dock Playlist | Seperti 0.62.0: klik 1x memilih baris, klik 2x memutar klip; Preview tidak dibuat hitam |
| T-339 | Dock minimize (0.63.0) | Tiap susunan dock: minimize Inputs, Playlist, lipat strip input mixer, lalu kembalikan | Panel lain mengisi ruang, mixer tidak terpotong |
| T-340 | Fullscreen dari Program (0.63.0) | Klik kanan Program › Layar Penuh › pilih layar | Program tampil penuh di layar itu; Tutup Layar Penuh menutupnya |
| T-341 | Transisi .metal & Multiview (0.63.0) | Pilih 9 transisi baru; buka Multiview dan coba 6 tata letak | Semua transisi jalan; tata letak berganti dan tersimpan |
| T-342 | Drop frame saat merekam (0.63.3) | Rekam HEVC 1080p25 ke SSD eksternal ≥ 5 menit, lalu Help › Export Logs | Log tidak menunjukkan "render drops … failed" berulang tiap 30 s; penghitung drop Program tetap 0 |
| T-343 | Template .lctitle (0.64.0) | Title Designer: pilih 3D emas, ubah warna & font (font non-bawaan, mis. dari Google Fonts); Template › Simpan ke Template Saya…; buka tab Milikku; Template › Ekspor sebagai .lctitle…; salin file ke Mac lain (atau hapus font & template), Template › Impor .lctitle…; ulangi untuk running text | Template muncul di Milikku dengan gambar mini yang benar; klik memakai tampilan tanpa menimpa teks yang sudah diketik; setelah impor di Mac lain tampilannya sama dan font ikut terpasang; Hapus memindahkan file ke Trash |
| T-344 | Macro (0.65.0) | Production › Macros…: buat macro "Buka": Transisi ke input 2, Overlay 1 nyala, Tunggu 3 s, Overlay 1 mati, Audio nyala (mic). Jalankan dari ▶, lalu pasang shortcut (Settings › Keyboard › Macros), MIDI (Learn "Macro 1") dan tombol M1 di Web Controller; simpan & buka ulang project | Langkah jalan berurutan, overlay keluar setelah transisi selesai lalu hilang setelah 3 s, mic unmute; ketiga cara memicu macro; macro tetap ada setelah buka ulang |
| T-345 | Trigger (0.65.0) | Macro A: trigger "Video selesai diputar" pada input video → langkah Transisi ke kamera. Macro B: trigger "Input masuk Program" kamera → Audio nyala mic. Putar video sampai habis. Lalu buat loop sengaja (A: masuk Program X → cut ke Y; B: masuk Program Y → cut ke X) | Saat video habis Program pindah ke kamera dan mic menyala; loop berhenti sendiri dengan pesan "Trigger dijeda", Aktifkan lagi berfungsi |
| T-346 | Auto mixer (0.65.0) | 3–4 mic panel, aktifkan Auto Mix di semua; bicara bergantian, lalu dua orang bersamaan, lalu semua diam; ubah Bobot satu mic ke +6 dB | Mic yang bicara penuh, yang diam turun (tab Auto Mix menunjukkan gain), dua pembicara ±−3 dB, saat diam semua rata rendah tanpa suara terputus; tidak ada klik/pumping yang mengganggu; bobot + membuat mic itu lebih mudah menang |
| T-347 | AI Assistant (0.66.0) | Production › AI Assistant…; isi API key Anthropic; 3 kamera + lower third di overlay 1. Ketik "naikkan kamera 2 pakai transisi lalu tampilkan lower third 5 detik", lalu "mute musik", lalu "mulai streaming" (izin stream mati) | Kamera 2 masuk Program dengan transisi, overlay 1 tampil ±5 s lalu hilang, baris aksi biru terlihat; musik mute; perintah streaming ditolak dengan penjelasan. Stop menghentikan langkah yang berjalan |
| T-348 | Perapian UI (0.66.0) | Lihat bar bawah; buka Add Input › Title / Lower Third…; buka Realtime Transcription | Tidak ada tombol MACROS; jendela title tidak terpotong di kiri (judul & tombol kategori terlihat penuh); pilihan model hanya Apple dan ElevenLabs |
| T-349 | AI Assistant penyedia lain (0.66.1) | Ganti Penyedia ke OpenAI / Gemini (isi key) dan Ollama (`ollama pull qwen2.5:7b`, Ollama berjalan); ulangi perintah T-347 di tiap penyedia | Aksi sama berjalan dan tampil sebagai baris biru; key salah → pesan "refused the API key"; Ollama mati → "Cannot reach Ollama… (is Ollama running?)" |
| T-350 | AI membuat konten (0.67.0) | Di AI Assistant: "buat lower third wedding warna emas untuk Budi & Ani di overlay 1", "ganti nama di input itu jadi Andi & Sari", "buat running text ucapan selamat datang", "buat macro opening: kamera 1 transisi, tampilkan overlay 1 5 detik", "tuliskan naskah MC pembukaan 2 menit"; ganti penyedia lalu cek label API key | Input title & running text baru muncul di daftar input dengan teks/warna yang diminta, overlay 1 berisi title (belum tampil); teks title berubah; macro baru ada di Production › Macros dan berjalan benar; naskah MC muncul di jendela; label API key sesuai penyedia |
| T-351 | AI ubah pengaturan + panel baru (0.68.0) | Buka AI Assistant: cek tampilan (sapaan, chip, bubble, titik berpikir, ⚙︎ melipat pengaturan, jendela dikecilkan tetap rapi). Perintah: "besarkan teks title input 2 jadi 70 dan kotaknya merah", "kecilkan musik setengah dan nyalakan kompresor mic", "ganti transisi ke wipe 2 detik", "hapus input 4", "ganti nama input 1 jadi Kamera Utama" | Setiap perubahan terlihat di input/mixer/transisi dan tampil sebagai pill ⚡; input di Program tidak bisa dihapus; Undo mengembalikan input yang dihapus |
| T-352 | Server cadangan (0.71.0) | Settings › Stream: isi server utama + server cadangan (YouTube `rtmp://b.rtmp.youtube.com/live2?backup=1`). Mulai stream; putus internet ±30 dt; sambung lagi. Ulangi dengan server utama salah | Setelah 2 kali gagal reconnect stream pindah ke server cadangan dan YouTube tetap menerima; server utama salah → langsung tersambung ke cadangan |
| T-353 | Safe slate (0.71.0) | Production › Show Automation: aktifkan, pilih input gambar "Kami akan segera kembali". Kamera USB di Program, cabut kabelnya, tunggu, colok lagi | ±2 dt setelah dicabut slate tampil di Program + pesan; ±3 dt setelah kamera kembali Program kembali ke kamera; jika operator memilih input lain saat slate tayang, tidak kembali otomatis |
| T-354 | Auto-director (0.71.0) | Pasangkan Mic 1 → Kamera 1, Mic 2 → Kamera 2, wide = Kamera 3. Bicara bergantian, bicara bersamaan, diam 10 dt, putar video di Program | Kamera mengikuti pembicara setelah ±0,8 dt dan tidak pindah lebih cepat dari 4 dt; bersamaan/diam → wide; selama video di Program tidak ada perpindahan |
| T-355 | Makro baru (0.71.0) | Buat makro A: Fade audio Musik ke -90 dB 3 dt, Jalankan makro B; makro B: CUT dengan kondisi "Program adalah Kamera 1". Tambah trigger jam 1 menit dari sekarang | Musik turun halus 3 dt; CUT hanya terjadi bila Kamera 1 di Program; makro berjalan sendiri pada jam yang diatur |
| T-356 | Teleprompter (0.71.0) | Production › Teleprompter: Edit, tempel naskah, Play, ubah kecepatan/ukuran/cermin, pindahkan jendela ke layar kedua dan fullscreen. Di HP buka Web Controller › Teleprompter ⛶ | Teks bergulir halus sesuai kata/menit; spasi/panah bekerja; HP menampilkan posisi yang sama dan tombolnya mengendalikan Mac |
| T-357 | Ringkasan AI (0.71.0) | Jalankan Realtime Transcription beberapa menit, buka Transcript › AI › Ringkas / Notulen / Chapter YouTube | AI Assistant terbuka dan menulis ringkasan, notulen, atau daftar chapter "00:00:00 Judul" dalam bahasa transkrip |
| T-358 | Multitrack (0.71.0) | Settings › Record: nyalakan Audio multitrack. Rekam 1 menit dengan 3 mic + musik, stop | Folder "… Tracks" berisi satu WAV per channel, panjang sama, bisa dibuka di DAW dan sejajar; rekaman utama tetap normal |
| T-359 | Splash (0.72.2) | Buka app; buka lagi dan klik/tekan tombol saat splash; matikan di Appearance lalu buka app; nyalakan Reduce Motion di macOS | Animasi logo ±3,8 dt lalu fade; klik/tombol langsung melewati tanpa memindah input; tidak muncul bila dimatikan; tanpa gerakan dengan Reduce Motion; Welcome/template muncul setelah splash |
