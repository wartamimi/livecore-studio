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

## AH. Tes manual build 0.33.1
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-140 | Dock tidak terpotong | Jendela penuh di layar 13"; perkecil jendela pelan-pelan sampai lebar minimum; jalankan RECORD, ISOCORDER, STREAM, EXTERNAL | Tidak ada teks berakhiran "…" di dock pada lebar mana pun; di jendela sempit status singkat muncul di dalam tombol; arahkan kursor ke tombol → status lengkap muncul; tombol bernama ISOCORDER |

## AG. Tes manual build 0.33.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-134 | ISOCORDER terpisah | ISOCORDER ⚙ › centang 2 kamera; tekan ISOCORDER (tanpa RECORD); 1 menit kemudian RECORD; hentikan ISOCORDER dulu, lalu RECORD | ISO mulai tanpa RECORD; menghentikan ISOCORDER minta konfirmasi dan tidak menghentikan RECORD; file ISO memakai profil MultiCorder; ISOCORDER tanpa input → pesan "Pilih dulu input" |
| T-135 | Profil MultiCorder | Settings › ISOCorder: ProRes 422, folder lain; Settings › Record: H.264 MP4; rekam keduanya | File Program H.264 .mp4 di folder Record, file ISO ProRes .mov di folder MultiCorder (cek di QuickTime › Show Movie Inspector) |
| T-136 | Setelan lanjutan | Recorder: HEVC 40 Mbps, keyframe 1 s, PCM; rekam 1 menit | File .mov HEVC, audio Linear PCM 24-bit; perkiraan GB/jam di Settings mendekati ukuran file × 60 |
| T-137 | 4 ISO tanpa drop | 1080p30, 4 kamera/capture, ISOCORDER HEVC 25 Mbps + RECORD, 10 menit; ulangi dengan ProRes 422 | Angka drop di dock 0 atau sangat kecil; Program tetap mulus. Catat model Mac, codec dan angka drop |
| T-138 | Label warna & grup | Klik kanan 2 input › Label warna › Biru, 1 input › Merah; ganti nama grup Biru jadi "Kamera"; klik chip Merah | Panel menampilkan grup "Kamera" (2) dan Merah (1), input tanpa label paling bawah; chip Merah hanya menampilkan grup merah; judul grup bisa dilipat |
| T-139 | Minimize | Klik − pada 2 tile; klik baris ringkas, klik ganda; simpan & buka lagi proyek | Tile jadi baris ringkas; klik = Preview, klik ganda = CUT; + membuka lagi; label, minimize dan nama grup kembali setelah proyek dibuka |

## AF. Tes manual build 0.32.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-131 | Rekaman ISO | RECORD ⚙ › MultiCorder (ISO) › centang 2 kamera; RECORD 2 menit sambil CUT antar kamera; stop | Di folder rekaman ada 3 file dengan waktu sama: Program dan "… - ISO <n> <nama>" per kamera; tiap ISO berisi kamera itu saja sepanjang rekaman (tidak ikut CUT) dengan suara Program |
| T-132 | Batas & proyek | Coba centang input ke-5; simpan proyek, buka lagi | Input ke-5 tidak bisa dicentang; pilihan ISO kembali setelah proyek dibuka |
| T-133 | Beban & status | 1080p30, 4 ISO, rekam 10 menit; lihat RECORD ⚙ dan Performance | Ukuran tiap file ISO bertambah; tidak ada/ sedikit "drop"; Program tetap mulus. Catat model Mac dan angka drop |

## AE. Tes manual build 0.31.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-127 | Panel di HP & tablet | Buka remote di HP (tegak) dan tablet/iPad (mendatar); masuk dengan keypad PIN | HP: satu kolom, T-bar mendatar; tablet: dua kolom, T-bar tegak; tombol bus Preview hijau / Program merah menyala sesuai Mac; tombol terasa "turun" saat ditekan |
| T-128 | Gambar monitor | Biarkan halaman terbuka 1 menit sambil ganti input di Mac | Gambar PVW/PGM di HP ikut berubah (±3 fps); setelah halaman ditutup beban CPU Mac kembali seperti sebelumnya |
| T-129 | Transisi dari HP | Pilih Wipe dan 2 s di HP, tekan AUTO | Pilihan transisi & durasi di Mac ikut berubah; AUTO menyala selama transisi |
| T-130 | Mixer dari HP | Geser fader mic & master di HP, tekan MUTE | Fader di Mac bergerak sama (angka dB sama); mute menyala di Mac; meter di HP bergerak saat ada suara |

## AD. Tes manual build 0.30.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-119 | Nyalakan Web Controller | Settings › Remote › nyalakan; HP di Wi-Fi yang sama buka alamat yang tertulis (mis. http://192.168.1.20:8088) | Halaman "LiveCore Remote" terbuka; PIN salah → "PIN salah"; PIN benar → nama proyek, Program/Preview dan daftar input tampil. Bila macOS menanyakan koneksi masuk, pilih Allow |
| T-120 | Preview, CUT, AUTO | Ketuk input (mode "Ketuk = Preview"), CUT, lalu AUTO; ganti ke "Ketuk = Program" dan ketuk input | Preview/Program di Mac berubah dalam <1 detik; warna merah/hijau di HP sama dengan Mac; mode Program langsung memotong ke input itu |
| T-121 | T-bar dari HP | Geser T-bar HP pelan-pelan sampai ujung | Transisi di Mac ikut bergerak; persen sama; di ujung Program berganti dan T-bar berikutnya berjalan ke arah sebaliknya |
| T-122 | Overlay & replay | Atur overlay 1 dengan input; ketuk 1 di HP; rekam replay ≥10 detik lalu ketuk 10 s | Overlay nyala/mati di Program; tombol replay aktif sesuai detik yang tersedia dan replay diputar |
| T-123 | Rekam & stream | Rekam dan Stream dari HP; hentikan (konfirmasi muncul di HP); kunci RECORD/STREAM di Mac lalu coba lagi | Mulai/berhenti sesuai; saat dikunci HP menampilkan pesan terkunci dan tidak ada yang berubah |
| T-124 | Lockout | Masukkan PIN salah 5 kali | Pesan "Terlalu banyak PIN salah… 60 detik"; perangkat lain tetap bisa memakai remote |
| T-125 | PIN baru | Settings › Remote › PIN baru | HP yang sudah masuk keluar ke layar PIN; PIN baru bisa dipakai; PIN tidak ada di preferences/proyek (hanya Keychain "remote-pin") |
| T-126 | QR code | Buka "QR code", pindai dengan kamera HP | Halaman remote terbuka dan langsung masuk tanpa mengetik PIN; jumlah "Perangkat tersambung" naik |

## AC. Tes manual build 0.29.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-116 | Input NDI | NDI Tools terpasang; di HP pasang aplikasi kamera NDI (mis. NDI HX Camera) atau jalankan OBS+NDI di komputer lain; LiveCore › + › Sumber NDI… | Sumber muncul dalam beberapa detik; Tambah → gambar tampil di input dan bisa CUT ke Program; output LiveCore sendiri bertanda "Output LiveCore"; sumber yang sudah dipakai tidak bisa dipilih lagi |
| T-117 | Audio NDI | Sumber NDI dengan audio | Kanal mixer baru bernama input itu bergerak; AFV bekerja; matikan "Audio ke mixer" → tidak ada audio |
| T-118 | Putus & sambung | Matikan aplikasi pengirim 10 detik lalu nyalakan lagi; coba "Bandwidth rendah" | Status "menunggu…" lalu gambar kembali sendiri; bandwidth rendah menampilkan resolusi lebih kecil di info sinyal |

## AB. Tes manual build 0.28.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-112 | Format perangkat | Edit input capture card › Lanjutan › Format video perangkat: pilih YUY2 (uncompressed), lalu MJPEG | Info Sinyal menampilkan format yang dipilih; gambar tetap tampil; dengan MJPEG resolusi/fps tinggi tersedia |
| T-113 | Rentang & deinterlace | Sumber HDMI dengan hitam pucat: pilih Limited → full; sumber 1080i: nyalakan Deinterlace | Hitam menjadi hitam; garis sisir hilang saat gerakan; reset koreksi warna tidak menghapus pilihan ini |
| T-114 | Buffer frame | Nyalakan Buffer frame, lihat gerakan cepat | Gerakan lebih mulus; latensi naik sedikit; mati → seperti sebelumnya |
| T-115 | Info sinyal & mulai ulang | Buka pengaturan input capture card yang sedang jalan; tekan Mulai ulang perangkat | fps terukur mendekati fps sumber; frame terbuang bertambah hanya saat beban berat; gambar kembali dalam beberapa detik |

## AA. Tes manual build 0.27.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-107 | Instant replay | Buka app, biarkan 20 detik, tekan replay di bawah T-bar | App tidak crash; replay diputar |
| T-108 | Edit layer sampai transisi | Input Scene di Preview; LAYER; geser layer; tutup designer; pilih input lain di Preview lalu kembali; tekan CUT | Tidak ada tombol Terapkan/Batalkan; Program tidak berubah sampai CUT; perubahan masih ada setelah Preview dipindah; setelah CUT Program menampilkan susunan baru |
| T-109 | T-bar horizontal | Tarik T-bar kiri ↔ kanan, lepas di tengah | Tuas horizontal halus; hanya angka persen yang tampil; selesai di ujung lain menjadi posisi diam baru |
| T-110 | Repeat One | Playlist musik 3 lagu; tekan tombol Ulangi dua kali (tampil "1"); biarkan lagu selesai; lakukan juga di playlist video | Lagu/klip yang sama diputar lagi; tekan sekali lagi → mati |
| T-111 | Fitur playlist | Tekan ⏹ (berhenti setelah item ini); biarkan lagu selesai; klik bar waktu di tengah; klik kanan lagu lain → Putar berikutnya | Pemutaran berhenti dan lagu berikutnya siap; ⏹ mati sendiri; klik bar melompat ke tengah; lagu yang dipilih menjadi berikutnya di daftar |

## Z. Tes manual build 0.26.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-101 | Draft Layer Designer | Input Scene di Preview dan juga di Program (atau sebagai overlay); buka LAYER, geser & ubah ukuran layer dengan cepat | Gerakan halus, tidak bergetar; perubahan hanya tampil di Preview; badge DRAFT muncul; Batalkan mengembalikan; Terapkan / tutup / CUT membawa perubahan ke Program |
| T-102 | FULLSCREEN satu baris | Lihat bar atas pada lebar jendela kecil dan besar, bahasa ID dan EN | Teks FULLSCREEN selalu satu baris |
| T-103 | Tanpa duplikat | Tambah kamera A; buka menu tambah lagi; tambah capture jendela Zoom lalu buka lembar capture lagi | Kamera A tampil "sudah dipakai (input N)" dan tidak bisa dipilih; jendela Zoom yang sama ditandai dan tombol Tambah mati; mengedit capture yang sudah ada tetap bisa |
| T-104 | Repeat / Shuffle | Playlist musik 5 lagu dan video playlist 3 klip; nyalakan Repeat dan Shuffle; tekan berikutnya beberapa kali dan biarkan lagu selesai | Tombol menyala biru dengan "ON"; urutan acak tanpa memutar lagu/klip yang sama dua kali berturut-turut; Repeat mati → berhenti di akhir |
| T-105 | T-bar | Tarik T-bar perlahan dari ujung ke ujung, lepas di tengah, lalu tekan AUTO | Pegangan mengikuti mouse tanpa melompat; jalur biru dan angka persen sesuai posisi; selesai di ujung lain menjadi posisi diam baru; saat AUTO tertulis AUTO |
| T-106 | Canvas | Settings › Canvas: Portrait 1080p, Terapkan; rekam 10 detik; lalu Custom 1080×1080; lalu kembali Horizontal | Monitor Preview/Program berbentuk 9:16 lalu 1:1; file rekaman 1080×1920; NDI dan fullscreen ikut ukuran baru; saat merekam/stream pengaturan terkunci |

## Y. Tes manual build 0.25.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-96 | Layer Designer: geser, ukuran, snapping, crop | Buat Scene dengan 2 kamera; taruh di Preview; klik LAYER; tarik layer ke tengah dan ke tepi layer lain; tarik sudut dan sisi; mode Crop: tarik tepi kiri, lalu Shift + tepi atas | Kotak mengikuti mouse; garis bantu biru muncul dan layer menempel; Preview menampilkan hasilnya langsung; crop memotong tanpa menggeser gambar; Shift memotong dua sisi sama besar |
| T-97 | Bingkai, sudut, hide/lock, template | Tombol bingkai: lebar, warna, sudut; ikon mata dan gembok; Simpan tata letak sebagai template; buka Scene lain dan terapkan | Bingkai/sudut tampil di Preview & Program; layer tersembunyi hilang dari gambar; layer terkunci tidak bisa digeser; template menerapkan posisi & gaya |
| T-98 | Flatten Layers | Scene A (2 layer) dengan Flatten; jadikan Scene A layer PiP di input B (Layer Designer di B) beri crop & bingkai; juga pakai Scene A sebagai overlay | Seluruh isi Scene A ikut terpotong/berbingkai sebagai satu gambar; tanpa Flatten hanya kanvas kosongnya yang tampil |
| T-99 | FULLSCREEN | Sambungkan layar kedua (dan ketiga bila ada); ⚙ FULLSCREEN: Output 1 = Program di layar 2, Output 2 = satu kamera di layar 3, centang keduanya; tekan FULLSCREEN, lalu tekan lagi | Kedua layar menampilkan gambarnya penuh tanpa bingkai; tombol menyala merah; tekan lagi menutup semuanya; layar utama tetap bisa dipakai |
| T-100 | Tata letak kecil | Buka app baru tanpa input musik/video; tambah input video; lihat tombol FOTO; lihat jenis transisi | Dock Playlist baru muncul setelah input video/musik ditambahkan; FOTO sebesar tombol RECORD; transisi = Dissolve |

## X. Tes manual build 0.24.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-93 | Sumber NDI | NDI Tools terpasang; buka LiveCore, EXTERNAL ⚙ (centang NDI Output 1 bila belum), nyalakan EXTERNAL; izinkan "Jaringan Lokal" bila diminta; buka NDI Studio Monitor / NDI Video Monitor | Sumber "<Mac> (LiveCore Output 1)" ada dan gambarnya tampil bergerak dengan audio Program; EXTERNAL ⚙ menampilkan "NDI: 1 penerima"; matikan EXTERNAL → sumber hilang |
| T-94 | Zoom tanpa OBS | NDI Virtual Input (ikon NDI di menu bar) › pilih "<Mac> (LiveCore Output 1)"; di Zoom › Video pilih "NDI Virtual Camera" | Zoom menampilkan Program LiveCore, tidak terbalik, tanpa jeda besar; CUT di LiveCore terlihat di Zoom |
| T-95 | Tanpa runtime NDI | Di Mac tanpa NDI Tools buka EXTERNAL ⚙ | Pesan "Runtime NDI tidak ditemukan" + link unduh; kotak NDI tidak bisa dicentang; Syphon tetap bekerja; app tidak crash |

## W. Tes manual build 0.23.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-88 | Kedip NOT RECORDING | Buka app tanpa merekam | Tulisan berkedip pelan (±1,2 s tampil, 0,8 s redup) |
| T-89 | Syphon terdeteksi OBS | Nyalakan EXTERNAL (Output 1 otomatis Syphon); di OBS tambah "Syphon Client"; buka EXTERNAL ⚙ | "LiveCore Studio – Output 1" ada di daftar OBS dan gambarnya tampil; EXTERNAL ⚙ menampilkan "Aplikasi tersambung"; Start Virtual Camera di OBS lalu Zoom/Meet menerima gambar |
| T-90 | Foto Program & gembok | Klik "Foto Program" di bawah monitor Program; klik gembok di dock bawah lalu RECORD dan STREAM | PNG tersimpan di folder rekaman; selama terkunci RECORD dan STREAM tidak bereaksi |
| T-91 | Nomor overlay di input | Di bawah input logo klik 1 (oranye di Preview), CUT; klik kanan 2 pada input lain (hijau, langsung Program); klik lagi | Overlay muncul/hilang dengan fade, layar penuh; warna nomor sesuai status; dock Overlay lama tidak ada |
| T-92 | Replay di bawah T-bar | Nyalakan buffer replay di bawah T-bar, tunggu 20 s, klik 10s, ubah kecepatan | Replay dimuat ke Preview seperti sebelumnya |

## V. Tes manual build 0.22.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-82 | Pengingat NOT RECORDING | Buka app tanpa merekam; RECORD ⚙ › Pengingat: "Setiap kali", lalu "Hanya saat streaming" (stream ke server lokal), lalu "Mati"; mulai rekam | Tulisan merah berkedip ±1×/detik di monitor Program saja (tidak di output/rekaman); mengikuti setelan; hilang saat merekam |
| T-83 | Dock bawah | Periksa dock bawah: RECORD, STREAM, EXTERNAL dengan ⚙; klik tiap ⚙; "Setelan lainnya…"; kunci RECORD lalu klik RECORD; perkecil panel lain | Dock selalu tampil & tidak punya tombol perkecil; ⚙ membuka detail (folder/opsi rekam, tujuan & statistik stream, output); "Setelan lainnya…" membuka tab yang tepat; kunci mencegah start/stop |
| T-84 | 4 output | EXTERNAL ⚙: Output 2 = Preview, Output 3 = input kamera, Output 4 = input video; buka jendela Output 2–4 dan layar penuh Output 3 di monitor kedua; CUT; simpan & buka proyek; hapus input kamera | Tiap jendela menampilkan sumbernya pada resolusi output; layar penuh di monitor terpilih; setelah proyek dibuka sumber kembali; input dihapus → output kembali ke Program; FPS render tetap stabil |
| T-85 | Syphon ke OBS | EXTERNAL ⚙: centang Syphon di Output 1; nyalakan EXTERNAL; di OBS tambah "Syphon Client" › LiveCore Studio – Output 1; Start Virtual Camera di OBS; pilih "OBS Virtual Camera" di Zoom/Meet/QuickTime | OBS menampilkan output tanpa jeda besar dan tidak terbalik; Zoom/Meet menerima gambar; matikan EXTERNAL → sumber hilang di OBS |
| T-86 | Playlist pilih vs putar | Dock Playlist: klik lagu ke-3 (tidak berbunyi, latar biru), tekan ▶; klik dua kali lagu ke-5 | Klik sekali hanya memilih; ▶ memutar lagu terpilih; klik dua kali langsung memutar |
| T-87 | (dihapus di 0.23.0) Kamera virtual Camera Extension | App di /Applications; EXTERNAL ⚙ › Aktifkan kamera virtual | Build unsigned: pesan jelas bahwa perlu Developer ID (bukan crash). Build bertanda tangan: izin di System Settings, lalu "LiveCore Virtual Camera" muncul di Zoom/QuickTime saat EXTERNAL nyala |

## U. Tes manual build 0.21.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-80 | Tutup & kunci audio | Arahkan kursor ke strip mixer mikrofon › x › Tutup; ulangi pada musik dan pada audio video (input video ikut terhapus setelah konfirmasi); kunci satu kanal lalu coba tutup; simpan & buka proyek | Konfirmasi selalu muncul; kanal hilang sesuai pesan; kanal terkunci tidak punya x dan menolak ditutup; gembok kembali setelah proyek dibuka |
| T-81 | Dock playlist | Input musik 5 lagu + playlist video 3 klip; di dock Playlist pilih musik, klik lagu ke-3, seret lagu ke-5 ke atas, hapus satu lagu yang tidak diputar, cari judul, Simpan sebagai M3U lalu tambahkan lagi dari M3U; pindah ke playlist video dan klik klip 2 | Lagu yang diklik langsung diputar; menyusun ulang/menghapus tidak memutus lagu yang sedang diputar; ikon speaker menandai lagu aktif; M3U tersimpan dan bisa dibaca kembali; klip video yang diklik tampil di input |

## T. Tes manual build 0.20.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-77 | Animasi overlay | Overlay 1 = judul, preset lowerThird; tombol tongkat › Geser dari kiri, 1 s; nyalakan/matikan ke Program; ulangi dengan Geser dari bawah dan Zoom; simpan & buka proyek | Judul meluncur masuk dari kiri dan keluar ke kiri dengan halus (melambat di ujung); bawah/zoom sesuai; setelan kembali setelah proyek dibuka |
| T-78 | Eyedropper chroma key | Kamera di depan green screen › Chroma Key… › tombol pipet › klik latar hijau di gambar | Warna kunci berubah ke hijau latar; kunci otomatis aktif; latar hilang lebih bersih dibanding preset Hijau; Ambil gambar baru memperbarui gambar |
| T-79 | Fade antarlagu | Input musik 2 lagu › menu strip › Fade antarlagu 3 s; putar, geser seekbar ke 10 s sebelum akhir | Lagu pertama mengecil pelan 3 s terakhir, lagu berikut mulai pelan dan naik dalam 3 s, tanpa klik; Mati = langsung seperti sebelumnya |

## S. Tes manual build 0.19.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-76 | Ticker arah & RSS | Ubah teks berjalan › Arah Kiri → kanan; lalu isi Feed RSS dengan feed berita https (mis. feed RSS portal berita), refresh 1 menit; buka lagi Ubah teks berjalan | Teks bergerak kiri → kanan; dalam beberapa detik judul berita feed tampil dipisah •; status "N items, jam" tampil di jendela; feed salah / tanpa internet menampilkan pesan error tanpa app tersendat, teks lama tetap jalan |

## R. Tes manual build 0.18.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-72 | Delay audio tanpa klik | Mikrofon atau musik di mixer › Properti Audio › geser Delay 0 → 300 ms → 0 sambil mendengarkan headphone | Tidak ada bunyi klik/pop saat delay berubah; setelah berubah, audio tertunda sesuai nilai |
| T-73 | AFV crossfade | Dua video ber-audio, keduanya AFV; durasi transisi 2 s; AUTO dari video A ke B; ulangi dengan CUT dan T-bar | AUTO: audio A turun dan B naik bersamaan selama 2 s; CUT: pindah cepat tanpa klik; T-bar: audio pindah di tengah bar |
| T-74 | Teks berjalan dari file | Buat news.txt (3 baris); Tambah › Teks berjalan › Dari file .txt…; jalankan; ubah & simpan file di TextEdit | Ketiga baris tampil dipisah •; ±2 s setelah disimpan teks berganti tanpa app tersendat; teks sangat panjang (tempel 2 halaman) tetap tampil penuh |
| T-75 | Slideshow Ken Burns & folder dipantau | Slideshow dari folder, centang Ken Burns; tunggu 2 foto; salin foto baru ke folder; hapus satu foto | Foto bergerak pelan (zoom + geser) tanpa patah saat crossfade; foto baru muncul dalam urutan ±5 s kemudian; foto yang dihapus tidak muncul lagi; Program tetap 30/60 fps |

## Q. Tes manual build 0.17.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-69 | Putar input | Klik kanan kamera atau video › Warna & Orientasi… › Putar 90°, lalu 270°, lalu 180°; pakai juga sebagai layer di Scene; simpan & buka proyek | Gambar berputar searah jarum jam 90°; tampil tegak penuh (pillarbox), tidak gepeng; 180° = terbalik; setelan kembali setelah proyek dibuka |
| T-70 | Teks berjalan | Tambah › Teks berjalan…; isi 2 baris; tambah; pasang sebagai overlay 1 ke Program; klik kanan › Jeda / Lanjutkan / Mulai lagi; ubah kecepatan & warna; streaming/rekam 1 menit | Pita di bawah gambar, teks bergerak halus kanan → kiri tanpa patah-patah, baris dipisah •; jeda berhenti; perubahan langsung terlihat; rekaman sama dengan Program |
| T-71 | Slideshow foto | Tambah › Slideshow foto… › Pilih folder (campur JPG potret/lanskap, PNG, HEIC); durasi 3 s, crossfade 1 s; tambah; klik kanan › Berikut / Sebelumnya / Jeda; simpan & buka proyek | Foto berganti tiap 3 s dengan crossfade halus; foto potret tegak (fit dengan bar hitam); Berikut/Sebelumnya langsung pindah; urutan sama dengan Finder; proyek membuka slideshow yang sama |

## P. Tes manual build 0.16.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-67 | Warna & orientasi input | Klik kanan kamera › Warna & Orientasi…; geser kecerahan, kontras, saturasi 0, gamma; centang kedua balik; pakai kamera itu juga sebagai layer di Scene; simpan & buka proyek | Perubahan langsung di tile, Preview, Program dan Scene; saturasi 0 = hitam putih; kedua balik = terbalik 180°; logo PNG transparan tetap transparan; setelan kembali setelah proyek dibuka |
| T-68 | Nada tes | Mixer › + › Nada Tes (1 kHz); rekam 10 s; ganti frekuensi/level di Properti Audio; hapus kanal | Meter kanal ≈ -18 dBFS; rekaman berisi nada 1 kHz bersih tanpa putus-putus; perubahan langsung terdengar |

## O. Tes manual build 0.15.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-61 | Scene + template | Tambah Input › Scene Baru; di editor: Tambah Layer 3 input; Tata letak › Grid 2 × 2, lalu 1 besar + 2 kecil; geser satu layer; CUT ke Program | Layer pindah ke posisi template; tile Scene menampilkan isinya; Program sama dengan editor |
| T-62 | Media transparan | Tambah PNG logo transparan dan video ProRes 4444 / HEVC alpha; lihat tile, editor scene, overlay di Program; perkecil logo 4K jadi PiP | Tile/editor: latar papan catur (bukan hitam); Program: hanya logo di atas gambar, tepi halus tanpa garis gelap/bergerigi |
| T-63 | Penampil source | Arahkan kursor ke tile › ikon panah (kiri atas tombol x); Layar Penuh; Esc; buka input lain | Gambar besar dan tajam, transparansi papan catur; layar penuh di monitor tempat jendela berada; ganti input mengganti isi |
| T-64 | Capture card | Tambah Input › Kamera / Capture Card dengan pengaturan…; pilih 1920 × 1080 59,94 dan audio perangkat; lalu klik kanan › Pengaturan Capture… ganti ke 1280 × 720; centang Cermin | Input tampil dengan format terpilih; kanal audio perangkat muncul di mixer; perubahan langsung berlaku; tersimpan di proyek |
| T-65 | Properti audio | Klik tombol DSP/Properti di kanal mic; Umum: mono dari kiri, delay 100 ms, balik fase; Kompresor: attack/release; simpan & buka proyek | Suara mono di kedua sisi; terlambat ±100 ms; pengaturan kembali setelah proyek dibuka |
| T-66 | Colour Bars & Lottie lama | Tambah Input › Colour Bars; buka proyek 0.14.0 yang berisi Lottie | Bars SMPTE tampil; proyek terbuka dengan peringatan bahwa input Lottie dilewati |

## N. Tes manual build 0.14.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-57 | Lottie .json tampil | Tambah Input › Lottie… › file .json (dan .lottie) yang di 0.13.x tidak tampil; lihat tile, Preview, Program | Animasi terlihat utuh (tidak terpotong), tidak terbalik, bergerak, latar transparan |
| T-58 | Tutup source dengan "x" | Arahkan kursor ke tile; klik "x"; pilih Batal, lalu ulangi dan pilih Tutup | Batal: tidak ada perubahan. Tutup: source hilang dari daftar, scene dan overlay; app tidak crash bila source sedang di Program |
| T-59 | Kunci source | Klik gembok di tile (jadi kuning, tertutup); coba "x", klik kanan › Ganti Nama / Edit Scene / Hapus; simpan proyek, buka lagi; gembok di header panel Input (kunci/buka semua) | Saat terkunci: "x" tidak muncul, menu edit nonaktif; Preview/CUT tetap bisa. Kunci tersimpan di proyek |
| T-60 | Kunci & konfirmasi stream/rekam | Klik gembok di samping Mulai Streaming dan Rekam; coba tombol, menu Production, shortcut ⌘; buka gembok lalu Stop; centang "Rekam otomatis saat streaming" lalu mulai/stop stream | Saat terkunci tidak ada yang mulai/berhenti (muncul pesan). Stop meminta konfirmasi. Rekaman ikut mulai/berhenti bersama stream |

## M. Tes manual build 0.13.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-54 | Editor scene: tambah layer & gaya | Klik kanan input › Edit Scene; "Tambah Layer" › pilih input; "Tambah Layer" › Tambah Bentuk › Lingkaran; Gaya: crop kiri 20 %, sudut bulat 30 %, border 1 % merah | Menu terbuka dan layer muncul; Preview menampilkan crop, sudut bulat halus, border; lingkaran benar-benar bulat; simpan & buka proyek mempertahankan gaya |
| T-55 | Overlay ke Preview / Program | Isi overlay 1 dengan logo; klik tombol "1" (oranye) lalu CUT; klik dua jari tombol "2" (hijau); klik lagi tombol hijau | Klik: logo hanya di Preview, CUT membawanya ke Program dan tombol jadi hijau; klik dua jari langsung ke Program; klik tombol hijau menghilangkan dari Program |
| T-56 | Input Lottie | Tambah Input › Lottie… › pilih .json dan .lottie (mis. dari LottieFiles); jadikan overlay lower third; Auto play = Restart | Animasi bergerak halus dengan latar transparan dan posisi tidak terbalik; masuk Program diputar dari awal; Loop off berhenti di frame terakhir |

## L. Tes manual build 0.12.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-52 | Transisi custom bawaan | Panel transisi › pilih tiap contoh (Wipe Diagonal, Clock Wipe, Doors Open, Blinds, Zoom Dissolve, Pixelate); AUTO dan geser T-bar | Tiap transisi berjalan halus tanpa kedip di awal/akhir; FPS stabil; pilihan tetap setelah app dibuka ulang dan tersimpan di proyek |
| T-53 | Shader buatan sendiri | "Baru…" (file terbuka di editor); ubah rumus, simpan, "Muat Ulang"; lalu buat salah ketik dan "Muat Ulang"; "Impor .metal…" file lain | Perubahan terlihat setelah Muat Ulang; salah ketik menampilkan pesan error dengan nomor baris dan AUTO memakai Dissolve tanpa crash; file impor muncul di daftar dengan tanda ✎ |

## K. Tes manual build 0.10.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-45 | Audio follow video | Dua video dengan suara; tombol AFV di kedua channel; CUT bolak-balik; mic: AFV › pilih input kamera | Hanya audio input yang tampil di Program terdengar; saat transisi keduanya terdengar; mic hanya terdengar saat kamera di Program; simpan & buka proyek mempertahankan AFV |
| T-46 | Tangkap jendela Zoom | Input › Tangkap Jendela / Layar; beri izin Perekaman Layar; pilih jendela Zoom meeting, audio aktif | Jendela Zoom tampil sebagai input; suara peserta masuk channel mixer sendiri; suara LiveCore tidak ikut tertangkap; tutup Zoom → status "no signal" tanpa crash; "Coba Tangkap Lagi" menyambung kembali |
| T-47 | Instant replay | Kontrol › Instant Replay › Buffer aktif; tunggu 15 dtk; "10 dtk terakhir"; pilih 50%; AUTO ke Replay | Input Replay di Preview menampilkan frame awal; masuk Program langsung berputar lambat tanpa patah; berhenti di frame terakhir; keluar Program kembali ke awal |

## J. Tes manual build 0.9.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-41 | Fullscreen output | Sambungkan monitor/proyektor; klik kanan tombol Fullscreen › pilih layar; klik Fullscreen; CUT/AUTO; klik lagi (atau ⌘⇧F) | Program penuh layar di layar pilihan tanpa menu/Dock/UI; jendela utama tetap bisa dipakai; cabut kabel menutup output tanpa crash. Dengan satu layar, Esc menutup |
| T-42 | Bus audio per output | Kirim mic ke Bus A saja (tombol A di channel), musik ke Master saja; Pengaturan › Rekam › Bus audio = Bus A; rekam 30 dtk; stream dengan satu tujuan Bus A dan satu Master | Rekaman hanya berisi mic; tujuan Bus A hanya mic, tujuan Master berisi musik; lip-sync tetap benar |
| T-44 | T-bar sampai ujung | Geser T-bar perlahan sampai mentok kanan dan tahan; lepas; geser lagi ke kiri sampai mentok | Tidak ada kedip/bolak-balik di ujung; bar tetap di kanan setelah transisi selesai; geser ke kiri menjalankan transisi berikutnya (seperti vMix) |
| T-43 | Tambah Media | Input › Tambah Media: pilih 1 mp4 + 1 mp3; lalu Tambah Media Playlist dengan mp3 saja, dan dengan mp4+mp3 | mp4 jadi input video, mp3 jadi input musik di mixer; playlist mp3 jadi musik; playlist campuran jadi input video (klip mp3 tampil hitam, suaranya lewat mixer) |

## I. Tes manual build 0.8.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-38 | Playlist video | Input › Playlist video: pilih 3 klip; Play; tunggu klip pertama selesai; ⏭/⏮; pilih klip dari menu | Lanjut otomatis ke klip berikut; audio tiap klip lewat channel mixer yang sama; nomor klip di tile benar |
| T-39 | Auto play | Klik kanan input video › Auto play › Mulai dari awal; CUT ke input itu, lalu CUT ke input lain | Video mulai dari awal saat masuk Program dan berhenti saat keluar; juga saat AUTO/transisi |
| T-40 | Transport | Tambah video/musik baru; geser seekbar; ⏯ | Media baru tidak langsung berputar (tampil frame pertama); seekbar memindahkan posisi; waktu/durasi benar |

## H. Tes manual build 0.7.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-35 | MIDI | Sambungkan controller MIDI USB; Pengaturan › MIDI: Learn CUT (pad), AUTO (pad), T-bar (fader), Preview 1–2 | Perangkat terdeteksi; tiap pad/fader menjalankan aksinya; pemetaan tetap ada setelah app dibuka ulang |
| T-36 | Input musik | Mixer › + › Musik: pilih 3 lagu (MP3/M4A/WAV); Play, Next, Previous, Acak; geser fader | Lagu terdengar lewat mixer (meter bergerak, ikut stream/rekaman), lanjut otomatis ke lagu berikut, tidak ada suara yang lolos di luar mixer |
| T-37 | Dock | Klik pegangan "–" di atas panel Input, Mixer, Kontrol, Preview/Program; klik bilahnya lagi; tutup & buka app | Panel mengecil jadi bilah dan kembali; monitor/mixer mengisi ruang; susunan diingat setelah app dibuka ulang |
| T-36b | Musik di proyek | Simpan proyek, buka lagi | Playlist, ulangi/acak, dan setelan fader kembali |

## G. Tes manual build 0.6.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-32 | Browser source | Input › Halaman web: buka overlay HTML dengan latar transparan (mis. jam/animasi CSS), 30 fps; jadikan overlay | Halaman tampil dengan latar transparan; animasi berjalan (juga saat app di belakang); CPU wajar; tidak crash saat URL salah |
| T-32b | Keamanan | Halaman yang mencoba `window.open`, link `mailto:`/skema lain | Tidak ada jendela/app lain terbuka; app tetap jalan |
| T-33 | Hitung mundur | Input › Jam / hitung mundur: 1 menit, keterangan "Mulai dalam"; klik kanan › Mulai, Jeda, Reset | Angka berjalan per detik, berhenti di 00:00 dan berubah merah; jeda/reset bekerja |
| T-34 | Snapshot | Klik tombol kamera di panel Rekam | PNG resolusi output muncul di folder rekaman, isinya sama dengan Program |

## F. Tes manual build 0.5.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-30 | Stinger | Tambah input file video stinger (ProRes 4444 / HEVC alpha, 1–2 s); Transisi › Stinger, pilih klip, atur titik potong; AUTO beberapa kali | Klip tampil di atas Program dengan latar transparan; Program berpindah tepat saat klip menutupi layar; suara whoosh terdengar lewat mixer; tidak ada kedip di awal/akhir |
| T-30b | Stinger dalam proyek | Simpan proyek, buka lagi | Klip & titik potong stinger kembali |
| T-31 | Aux bus | Kirim mic 1 ke A, mic 2 ke B; geser fader & mute bus | Meter AUX A/B bergerak sesuai; stream/rekaman tidak berubah |
| T-31b | Mix-minus | Pilih perangkat output untuk AUX A (headphone kedua atau perangkat virtual); klik kanan DSP kanal tamu › Mix-minus di bus A | Tamu mendengar semua kecuali dirinya; 30 menit tanpa klik/putus (cek underrun) |

## E. Tes manual build 0.4.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-28 | Multi-destination | Pengaturan › Stream: isi tujuan utama (YouTube), Tambah tujuan (Facebook, URL `rtmps://…`, key); Apply; Mulai Stream | Kedua platform menerima video+audio; panel Stream menunjukkan status & kbps per tujuan; CPU tidak naik dua kali lipat |
| T-28b | Satu tujuan putus | Saat live ke 2 tujuan, buat key salah di salah satu (atau putuskan jaringan sesaat) | Tujuan lain tetap live; tujuan bermasalah menunjukkan reconnect/gagal tanpa menghentikan yang lain |
| T-28c | Setelan lama | Buka app setelah memakai 0.3.x | URL & key lama tetap ada sebagai tujuan utama; stream seperti sebelumnya |
| T-29 | Transisi baru | Pilih Wipe ↑/↓, Push ←/→, Slide ←/→, Iris; jalankan AUTO lalu T-bar perlahan | Gerakan halus ke arah yang benar, tanpa garis/kedip; hasil akhir = sumber Preview |

## D. Tes manual build 0.3.0
| ID | Tes | Langkah | Kriteria lulus |
|---|---|---|---|
| T-23 | Editor scene | Klik kanan input → Edit Scene Layers…; + tambah kamera 2; seret & ubah ukuran; ubah urutan & opasitas | Preview mengikuti setiap perubahan; Program tidak berubah sampai CUT; tersimpan di proyek |
| T-24 | Lower third | Title → layout "Bar selebar layar" dan "Teks di tengah", ubah ukuran & warna | Tampilan sesuai di Preview/Program/rekaman; teks tidak terpotong |
| T-25 | Drift jangka panjang | Mic USB + output headphone berbeda, siaran/rekam ≥ 1 jam; buka DSP › Clock | Tanpa klik berkala; ppm stabil (umumnya < ±100); underrun tidak terus bertambah |
| T-26 | EQ & HPF | Mic: HPF 100 Hz, Low −6 dB, High +3 dB | Suara berubah sesuai; tanpa distorsi/klik saat menggeser slider |
| T-27 | Proyek lama | Buka file `.livecore` dari 0.2.0 | Terbuka tanpa error; EQ default off |
