# Test Plan — Milestone 1 & 2

## A. Tes otomatis (dapat dijalankan di Linux dan macOS)
| ID | Tes | Perintah |
|---|---|---|
| A-01 | Unit test LiveCoreCore (73 tes; 0.3.0 menambah drift compensator, EQ/biquad, editor layer, kompatibilitas proyek 0.2.0; M2 menambah resampler, noise gate, chroma key, file proyek; M1: switcher, transisi, overlay, layout, DSP, ring buffer lock-free, clock anchor, AMF0, AVC/AAC, FLV, RTMP URL/chunk/sesi, antrean kongesti, settings) | `swift test` |
| A-02 | E2E RTMP: publish H.264 High 720p30 + AAC 48k selama 10 s ke server RTMP ffmpeg, verifikasi ffprobe + decode semua frame | `scripts/rtmp_e2e_test.sh` |
| A-03 | E2E FLV writer → ffprobe | (bagian dari A-02) |
| A-04 | Kegagalan koneksi: server tidak ada, server memutus di tengah stream; stream key tidak bocor di log | (bagian dari A-02) |
| A-06 | Kompilasi shader Metal offline (sintaks/tipe semua fungsi shader, termasuk `key_fragment`) | `scripts/check_shaders.sh` (Mac) |
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
