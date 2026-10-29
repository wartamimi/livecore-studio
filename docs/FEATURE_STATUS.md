# Status Fitur

Definisi status:
- **Implemented** — kode lengkap untuk fungsi tersebut ada di repo. Kolom *Verifikasi* menyatakan apakah sudah dibuktikan.
- **Partially implemented** — sebagian fungsi ada; batasannya disebut.
- **Planned** — belum ada kode; dijadwalkan pada milestone yang disebut.
- **Blocked** — tidak dapat dikerjakan tanpa sesuatu di luar kendali (SDK, lisensi, perangkat).

Verifikasi: **L** = lulus tes otomatis di Linux (unit/E2E), **M** = perlu diuji di Mac (belum), **—** = n/a.

Tambahan: **U** = dilaporkan berfungsi oleh pengguna di Mac miliknya (build 0.1.0).

> Status per 2026-10-27: M1 dikompilasi di CI macOS dan fungsi inti (kamera, CUT/AUTO, meter, rekam, stream) dilaporkan
> berfungsi oleh pengguna. Reconnect, cabut-colok, beban jangka panjang belum diuji. Fitur M2 (0.2.0) dikompilasi dan diuji
> unit, tetapi **belum diverifikasi di perangkat** (T-17..T-22).

## Video
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Penemuan kamera USB/UVC & built-in, hot-plug | Implemented | M | `DeviceManager` |
| Input kamera (pemilihan format sesuai output) | Implemented | U | `CameraSource` |
| Pengaturan capture card (resolusi, frame rate, cermin, audio perangkat) saat menambah & sesudahnya | Implemented (0.15.0), belum dites | L (pemilihan format, proyek) + kompilasi CI | Disimpan di proyek |
| Input file video (loop, play/pause/restart) | Implemented | U (video) + M (audio) | M2: audio file masuk kanal mixer sendiri via MTAudioProcessingTap, resample ke 48 kHz |
| Input gambar (PNG alpha, JPEG, HEIC…) | Implemented | M | |
| Input warna | Implemented | M | |
| Text / lower third (CoreText) | Implemented | M | 0.3.0: 3 layout (kotak, bar penuh, caption tengah), ukuran font, warna teks & bar; animasi masuk = fade overlay. Sejak 0.34.0 diganti Title Designer (lihat bagian Title Designer 0.34.0); title lama tetap tampil sama sampai diedit |
| Preview/Program terpisah | Implemented | L (logika) + M (render) | `Switcher`, `FramePlanner` teruji |
| CUT | Implemented | L + U | |
| AUTO: Dissolve, Fade (dip to black), Wipe | Implemented | L + U | |
| Transisi Wipe 4 arah, Push ←/→, Slide ←/→, Iris | Implemented (0.4.0) | L (`TransitionMath`, 8 unit test) + shader dikompilasi CI | Bekerja dengan AUTO dan T-bar; belum dites di Mac (T-29) |
| T-bar manual | Implemented | L + M | |
| Overlay 4 kanal dengan fade | Implemented | L + M | 0.20.0: animasi masuk/keluar per kanal (fade, geser dari kiri/kanan/bawah/atas, zoom) + durasi 0,25–2 s, disimpan di proyek; belum dites (T-77) |
| Overlay ke Preview (klik, oranye) / ke Program (klik dua jari / kanan, hijau) | Implemented (0.13.0), belum dites | L (planner + take, unit test) + kompilasi CI | Overlay di Preview ikut ke Program saat CUT/AUTO/T-bar. MIDI dan shortcut overlay tetap langsung ke Program. Belum dites (T-55) |
| Gaya layer: crop 4 sisi, sudut bulat, elips/lingkaran, border + warna | Implemented (0.13.0), belum dites | L (geometri crop/mask, 5 unit test) + kompilasi shader CI | Di editor scene › Gaya. Crop juga berlaku untuk layer chroma key; sudut/elips/border tidak (dilewati bila chroma key aktif). Belum dites (T-54) |
| Bentuk (kotak, kotak bulat, lingkaran) di editor scene | Dihapus (0.14.0) | — | Atas permintaan pengguna. Gaya layer (crop, sudut bulat, elips, border) tetap ada |
| Input Lottie (.json / .lottie) | Dihapus (0.15.0) | — | Atas permintaan pengguna: tidak tampil di Mac pengguna. Proyek lama tetap terbuka (input dilewati) |
| Input Scene (kanvas kosong) + 7 template tata letak (penuh, PiP, berdampingan, grid 2×2, 1+2, tiga, wawancara) | Implemented (0.15.0), belum dites | L (template, proyek, thumbnail scene) + kompilasi CI | Seperti scene vMix: isi dengan layer di editor scene; thumbnail menampilkan isi scene |
| Input Colour Bars (SMPTE) | Implemented (0.15.0), belum dites | L (proyek) + kompilasi CI | Gambar saja, tanpa nada audio |
| Koreksi warna per input (kecerahan, kontras, saturasi, gamma) + balik horizontal/vertikal (putar 180°) | Implemented (0.16.0), belum dites | L (rumus warna, proyek; 3 unit test) + kompilasi shader CI | Satu pass GPU per input yang diatur; hasilnya dipakai di Program, Preview, layer scene, overlay, thumbnail. Disimpan di proyek |
| Putar input 0° / 90° / 180° / 270° | Implemented (0.17.0), belum dites | L (sudut tekstur & ukuran; 1 unit test) + kompilasi CI | Di Warna & Orientasi. 90°/270° menukar lebar dan tinggi (kamera / video potret tampil tegak, fit dengan pillarbox) |
| Input teks berjalan (ticker): teks, kecepatan, ukuran, warna, bar latar, tinggi pita | Implemented (0.17.0), belum dites | L (posisi gulir, proyek; 2 unit test) + kompilasi CI | Pita di bawah gambar saat jadi overlay/layer; 60 fps dari CPU (satu blit per frame). Jeda / mulai lagi / ubah dari klik kanan. 0.18.0: teks dari file .txt (diperbarui ±2 s setelah disimpan; T-74); teks sangat panjang dipecah per 4096 px. 0.19.0: arah kanan → kiri / kiri → kanan, judul berita dari feed RSS/Atom (https, refresh 1–120 menit; T-76) |
| Input slideshow foto (folder atau pilih foto, durasi per foto, crossfade, loop) | Implemented (0.17.0), belum dites | L (urutan & crossfade, proyek; 1 unit test) + kompilasi CI | Fit di atas hitam pada resolusi output, orientasi EXIF dihormati. Berikut / sebelumnya / jeda dari klik kanan. 0.18.0: Ken Burns (zoom 100↔115 % + geser) dan folder dipantau tiap 5 s untuk foto baru/terhapus (T-75) |
| Tombol fullscreen per input (penampil source) | Implemented (0.15.0), belum dites | L (plan detail) + kompilasi CI | Jendela besar resolusi output, papan catur untuk transparansi, tombol layar penuh / Preview / Cut |
| Transparansi & tepi halus | Implemented (0.15.0), belum dites | kompilasi shader CI | Tile & editor scene transparan (papan catur); sampling 4-tap saat gambar diperkecil; video ber-alpha di-premultiply di semua layer (sebelumnya hanya stinger) |
| Picture-in-Picture (layer pada input / overlay preset PiP) | Implemented | L + M | Preset posisi + editor scene (drag, resize). 0.13.0: tombol "Tambah Layer" diperbaiki (dulu menu tidak terbuka) |
| Scene composition / editor layer visual | Implemented (0.3.0) | L (geometri) + M | Seret untuk pindah, sudut untuk resize (kunci rasio), snap ke tengah/safe area, urutan, opasitas, skala, preset |
| Scaling fit/fill/stretch & aspect ratio | Implemented | L + M | `LayoutMath` teruji |
| Resolusi/frame rate output (720p30/60, 1080p25/30/60) | Implemented | M | Terkunci saat output aktif |
| Thumbnail input live (≈5 fps) | Implemented | M | |
| Jendela Program untuk monitor eksternal | Implemented | M | Seret ke layar lain + full screen |
| Multiview | Implemented (M2) | M | Jendela terpisah: Preview, Program, semua input + tally; input 10 fps 384×216 |
| Chroma key | Implemented (M2) | L (matematika) + M (shader) | Per input (kamera/file/gambar), warna kunci, similarity, smoothness, spill; GPU. 0.20.0: eyedropper (klik pada gambar, rata-rata 9×9 px; 1 unit test; T-78) |
| Browser source (halaman web / HTML lokal) | Implemented (0.6.0) | L (kebijakan URL, 2 unit test) + kompilasi CI | WKWebView di jendela offscreen, snapshot 5–30 fps, latar transparan; data store non-persisten, tanpa bridge JS→app, tanpa pop-up, hanya http/https/file. Audio halaman tidak masuk mixer. Belum dites di Mac (T-32) |
| Jam / hitung mundur / stopwatch | Implemented (0.6.0) | L (`TimerMath`, 5 unit test) + kompilasi CI | Input generator, keterangan opsional, merah saat hitung mundur habis; kontrol lewat klik kanan. Belum dites (T-33) |
| Transisi stinger (klip video, idealnya dengan alpha) | Implemented (0.5.0) | L (`Switcher`/`FramePlanner`, 6 unit test) + kompilasi CI | Klip = input file video; titik potong diatur; durasi = panjang klip; audio klip lewat mixer. T-bar memakai dissolve. Belum dites di Mac (T-30) |
| Transisi custom (shader pengguna) | Implemented (0.12.0), belum dites | L (validasi, pembungkus, ID file, 5 unit test) + kompilasi offline 6 contoh bawaan & template di CI Mac | Satu fungsi Metal `transition(uv, progress, ratio, from, to, s)` per file `.metal`; 6 contoh bawaan (Wipe Diagonal, Clock Wipe, Doors Open, Blinds, Zoom Dissolve, Pixelate); Baru/Impor/Muat Ulang/Folder di panel transisi; dikompilasi saat dipilih, error kompilasi ditampilkan dan AUTO/T-bar memakai Dissolve sampai shader berhasil. Belum dites (T-52, T-53) |

## Proteksi operator (0.14.0)
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Tutup source dengan tombol "x" (dengan konfirmasi) | Implemented (0.14.0), belum dites | kompilasi CI | Muncul saat kursor di atas tile; juga menu klik kanan › Hapus |
| Kunci (gembok) per source + kunci/buka semua | Implemented (0.14.0), belum dites | L (model proyek) + kompilasi CI | Source terkunci tidak bisa ditutup, diganti nama, atau diedit (scene, key, judul, browser, timer, kontrol putar). Preview/CUT tetap bisa. Disimpan di proyek |
| Tutup kanal audio di mixer (x + konfirmasi) + gembok per kanal / kunci semua | Implemented (0.21.0), belum dites | L (proyek) + kompilasi CI | Perangkat & nada tes: kanal dihapus; musik: input musik dihapus; audio milik video/tangkapan layar: input pemiliknya ikut dihapus (dengan peringatan). Gembok disimpan di proyek (T-80) |
| Dock Playlist di samping mixer (lagu musik & klip video) | Implemented (0.21.0), belum dites | L (edit urutan, M3U; 2 unit test) + kompilasi CI | 0.22.0: klik = pilih (latar biru), klik dua kali atau ▶ = putar (T-86). Sebelumnya klik = putar; seret = urutkan; klik kanan = naik/turun/hapus; cari; tambah file; impor/simpan M3U/M3U8; ulangi/acak. Bisa diperkecil seperti panel lain (T-81) |
| Kunci streaming dan kunci rekaman | Implemented (0.14.0), belum dites | kompilasi CI | Saat terkunci, mulai/stop tidak berfungsi dari tombol, menu, shortcut, maupun MIDI. Tidak disimpan (kembali terbuka saat app dibuka ulang) |
| Konfirmasi sebelum Stop Streaming / Stop Rekam | Implemented (0.14.0), belum dites | kompilasi CI | Berlaku untuk tombol, menu, shortcut dan MIDI; quit tetap memakai konfirmasi quit yang sudah ada |
| Rekam otomatis saat streaming | Implemented (0.14.0), belum dites | kompilasi CI | Opsi di panel Rekam; rekaman yang dimulai otomatis ikut berhenti saat stream dihentikan |

## Audio
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Pemilihan input (semua perangkat input macOS) | Implemented | M | |
| Kanal multi-input, fader, trim, pan | Implemented | L (DSP) + M | |
| Properti audio per kanal (nama, mode kanal, balik fase, delay 0–1000 ms, attack/release/makeup kompresor, range gate, routing, AFV) | Implemented (0.15.0), belum dites | L (mode kanal, delay, fase) + kompilasi CI | Jendela Properti Audio ala vMix; disimpan di proyek. 0.18.0: perubahan delay di-crossfade 20 ms (tanpa klik; T-72) |
| Nada tes (sine 1 kHz, -18 dBFS; 100 Hz–10 kHz, level -60…0 dBFS) | Implemented (0.16.0), belum dites | L (generator, proyek; 2 unit test) + kompilasi CI | Kanal mixer sendiri (Tambah Audio › Nada Tes); bisa dipadukan dengan Colour Bars. Disimpan di proyek |
| Mute | Implemented | L + M | |
| Solo (ke bus monitor) | Implemented | M | |
| Routing ke Program on/off | Implemented | M | |
| Peak meter + peak hold | Implemented | L + U | |
| Compressor per kanal | Implemented | L + M | Feed-forward, stereo-linked |
| Limiter master | Implemented | L + M | Tanpa look-ahead (lihat known issues) |
| Noise gate | Implemented (M2) | L + M | Per kanal: threshold, range, hysteresis 4 dB, hold 60 ms |
| High-pass filter + EQ 3-band | Implemented (0.3.0) | L + M | HPF 40–300 Hz; low shelf 120 Hz, mid peak 200–6000 Hz, high shelf 8 kHz, ±12 dB |
| Monitoring + pemilihan perangkat output | Implemented | M | |
| Sinkronisasi A/V (host clock + offset manual) | Implemented | L (anchor) + M | Butuh kalibrasi per kamera |
| Koreksi drift clock (resampling adaptif) | Implemented (0.3.0) | L (simulasi ±300 ppm, 10 menit) + M | Per kanal, maks ±0,5 %; ppm & underrun tampil di popover DSP |
| Audio dari file video | Implemented (M2) | M | Lihat Known issue: sinkronisasi audio file belum diukur |
| Aux bus A/B (send post-fader per channel, fader/mute/meter bus) | Implemented (0.5.0) | L (model proyek) + kompilasi CI | Belum dites di Mac (T-31) |
| Audio follow video (AFV) | Implemented (0.10.0) | L (on-air + gate DSP, 5 unit test) + kompilasi CI | Tombol AFV di tiap channel: audio file/tangkapan mengikuti inputnya sendiri, channel lain memilih input yang diikuti. Terbuka saat input tampil di Program, transisi, layer scene, atau overlay aktif. Tersimpan di proyek. 0.18.0: audio crossfade selama durasi transisi AUTO (masuk/keluar bersamaan), T-bar pindah di tengah. Belum dites (T-45, T-73) |
| Output aux ke perangkat terpisah + mix-minus | Implemented (0.5.0) | kompilasi CI | Tiap bus bisa diputar di perangkat output lain (koreksi drift clock); menu kanal "Mix-minus" mengirim semua kanal kecuali kanal itu. Belum dites (T-31b) |
| Input musik (playlist file audio: MP3/AAC/M4A/WAV/AIFF...) | Implemented (0.7.0) | L (urutan playlist/acak, model proyek) + kompilasi CI | Channel mixer sendiri; play/pause/next/previous di strip; ulangi & acak; tersimpan di proyek. 0.20.0: fade antarlagu 1–8 s (fade-out akhir + fade-in awal, tidak tumpang tindih; T-79). Belum dites di Mac (T-36) |
| Audio NDI | Implemented: keluar (0.24.0) dan masuk (0.29.0) | CI `livecore-ndi-check` (video) | Output NDI mengirim audio Program stereo; input NDI membawa audionya ke kanal mixer sendiri (48 kHz, sampel lain di-resample) |

## Streaming
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| RTMP (handshake, perintah, chunking, FLV/AMF0) | Implemented | **L (E2E ke server ffmpeg)** | |
| RTMPS (TLS) | Implemented | M | Network.framework TLS |
| URL + stream key (Keychain, tidak dilog) | Implemented | L (redaksi) + M (Keychain) | |
| H.264 VideoToolbox HW, bitrate/profile/GOP | Implemented | M | |
| AAC-LC 48 kHz | Implemented | M | |
| Start/Stop, status koneksi | Implemented | L (protokol) + M | |
| Error handling (URL salah, ditolak server, putus) | Implemented | L + M | |
| Reconnect otomatis (backoff) | Implemented | L (jadwal) + M | |
| Statistik bitrate, dropped frames, antrean, durasi, HW/SW | Implemented | M | |
| Multi-destination (hingga 3 tujuan, mis. YouTube + Facebook) | Implemented (0.4.0) | L (validasi setelan) + kompilasi CI | Satu encode H.264/AAC dibagi ke semua tujuan; reconnect per tujuan; key tiap tujuan di Keychain. Belum dites di Mac (T-28) |

| Bus audio per tujuan stream (Master / Bus A / Bus B) | Implemented (0.9.0) | L (model) + kompilasi CI | Pengaturan › Stream, per tujuan. Satu encode H.264 tetap dibagi; satu encode AAC per bus yang dipakai. Belum dites (T-42) |

## Recording
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Rekam Program (MP4/MOV, H.264+AAC) | Implemented | U | AVAssetWriter |
| Pilih folder, pola nama file, nama unik | Implemented | L (penamaan) + M | |
| Status, durasi, ukuran file, ruang kosong | Implemented | M | |
| Penanganan disk penuh / gagal tulis | Implemented | M | Berhenti & finalisasi |
| Finalisasi benar saat stop / quit | Implemented | M | Konfirmasi quit saat aktif |
| Rekam + stream bersamaan dari satu pipeline | Implemented | M | |
| MOV tahan crash (movie fragments 10 s) | Implemented | M | |
| Pilih bus audio untuk rekaman (Master / Bus A / Bus B) | Implemented (0.9.0) | L (model, kompatibel setelan lama) + kompilasi CI | Pengaturan › Rekam › Bus audio. Ring encoder bus A/B ditulis bersamaan dengan Program sehingga sinkron sampel. Belum dites (T-42) |
| Snapshot Program ke PNG | Implemented (0.6.0) | kompilasi CI | Tombol kamera di panel Rekam; disimpan di folder rekaman. Belum dites (T-34) |

## Perangkat broadcast
| Fitur | Status | Catatan |
|---|---|---|
| Capture card HDMI/SDI yang tampil sebagai UVC/AVFoundation | Implemented (via jalur kamera) | Lihat `CAPTURE_DEVICES.md` |
| Blackmagic DeckLink (Desktop Video SDK) | Blocked → Planned M3 | Perlu SDK (EULA, registrasi) + perangkat uji |
| AJA / Magewell Pro | Planned M3 | Perlu SDK vendor |
| NDI | Implemented: output (0.24.0) dan input (0.29.0) | Runtime NDI dimuat saat jalan (tidak disertakan); lihat bagian Input NDI 0.29.0 |
| Virtual camera sendiri (Camera Extension seperti OBS) | Dihapus (0.23.0) | Dibuat di 0.22.0 lalu dihapus atas permintaan pemilik (butuh tanda tangan Developer ID). Pakai Syphon → OBS → OBS Virtual Camera |
| Syphon (kirim output ke OBS, Resolume, MadMapper…) | Implemented (0.22.0), diperbaiki 0.23.0, belum dites di Mac pengguna | Server Syphon (kode BSD, di-vendor) per output; nyala saat EXTERNAL aktif (Output 1 otomatis bila belum ada yang dipilih); frame dikirim sejak server dibuat; status "aplikasi tersambung" di EXTERNAL ⚙. CI `livecore-syphon-check`: proses lain menemukan server lewat direktori Syphon dan membaca frame 1280×720 BGRA dari IOSurface (T-89) |

## Kontrol
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Shortcut keyboard yang bisa diatur | Implemented | M | |
| Kontrol MIDI dengan Learn (CUT, AUTO, T-bar, preview/cut 1–8, overlay 1–4, stream, rekam, snapshot) | Implemented (0.7.0) | L (parser MIDI 1.0/UMP, pemetaan, 6 unit test) + kompilasi CI | Semua sumber CoreMIDI tersambung otomatis; pemetaan disimpan di Mac (bukan proyek). Belum dites dengan controller (T-35) |
| MultiCorder: rekaman ISO per input (maks 4) | Implemented (0.32.0), terpisah sejak 0.33.0 | lihat bagian MultiCorder terpisah 0.33.0 | Tombol ISOCORDER sendiri, profil sendiri |
| Web Controller (remote dari browser HP/tablet di jaringan yang sama) | Implemented (0.30.0) | lihat bagian Web Controller 0.30.0 | PIN, mati secara default |
| Input tangkap jendela / layar (Zoom, Teams, Meet, slide) | Implemented (0.10.0) | L (pencocokan jendela, 5 unit test) + kompilasi CI | ScreenCaptureKit; audio aplikasi (jendela) atau sistem (layar) ke channel mixer sendiri; audio & jendela LiveCore sendiri dikecualikan; jendela ditemukan lagi lewat aplikasi + judul saat proyek dibuka. Perlu izin Perekaman Layar. Belum dites (T-46) |
| Input Zoom via Zoom Meeting SDK (peserta terpisah, seperti vMix) | Ditunda (dihapus dari build publik di 0.10.1) | — | Pernah dibuat di 0.11.x dan dikompilasi dengan SDK, lalu ditarik dari repo & rilis publik atas keputusan pemilik; diarsipkan secara privat. Join meeting akun lain gagal (kode 63) sampai aplikasi SDK lolos review Zoom Marketplace. Untuk sekarang pakai input tangkap jendela |
| Program sebagai kamera virtual (untuk Zoom) | Lewat NDI Tools (0.24.0) atau OBS | CI `livecore-ndi-check` | EXTERNAL › NDI → di NDI Tools pilih "LiveCore Output 1" → di Zoom pilih "NDI Virtual Camera" (tanpa OBS). Atau Syphon → OBS Virtual Camera. Kamera bernama "LiveCore" sendiri butuh Camera Extension bertanda tangan Developer ID (dihapus di 0.23.0) |
| Dock bawah RECORD / STREAM / EXTERNAL dengan ⚙ | Implemented (0.22.0), belum dites | kompilasi CI | Selalu tampil (tidak bisa diperkecil); ⚙ membuka detail & setelan masing-masing; status singkat di sebelahnya; tombol OUT 1–4 (T-83). 0.23.0: satu gembok untuk RECORD + STREAM; tombol foto pindah ke bawah monitor Program (T-90) |
| 4 output dengan sumber sendiri (Program / Preview / satu input) | Implemented (0.22.0), belum dites | L (routing, render ekstra, proyek; 4 unit test) + kompilasi CI | Tiap output: jendela, layar penuh di monitor pilihan, Syphon. Input dirender penuh resolusi output hanya bila output-nya dipakai. Disimpan di proyek (T-84) |
| Pengingat NOT RECORDING berkedip (vMix-style) | Implemented (0.22.0), belum dites | L (2 unit test) + kompilasi CI | Di monitor Program saja (bukan di output). Setelan: mati / setiap kali tidak merekam / hanya saat streaming (RECORD ⚙) (T-82). 0.23.0: kedip lebih pelan, siklus 2 detik (T-88) |
| Instant replay (5/10/20 dtk terakhir, 100/50/25%) | Implemented (0.10.0) | L (indeks segmen, 5 unit test) + kompilasi CI | Program direkam terus ke segmen H.264 2 dtk di folder sementara (30 dtk terakhir); replay digabung tanpa encode ulang dan dimuat ke input "Replay" di Preview; mulai putar saat masuk Program. Video saja. Belum dites (T-47) |
| Input playlist video | Implemented (0.8.0) | L (urutan, model proyek) + kompilasi CI | Satu input memutar beberapa klip berurutan; next/previous/pilih klip; ulangi playlist; tersimpan di proyek. Belum dites (T-38) |
| Auto play saat masuk Program (vMix-style) | Implemented (0.8.0) | kompilasi CI | Mati / putar-jeda / mulai dari awal-jeda; berlaku juga untuk layer scene, overlay aktif, dan transisi. Belum dites (T-39) |
| Transport media: seekbar, play/pause, prev/next; media dimuat dalam keadaan jeda | Implemented (0.8.0) | kompilasi CI | Di tile input video dan strip musik. Belum dites (T-40) |
| Perbaikan T-bar di ujung (glitch) | Fixed (0.9.0) | L (3 unit test regresi) | Bar tetap di ujung setelah transisi selesai dan transisi berikutnya berjalan ke arah sebaliknya (vMix); getaran ±0,5% di ujung diabaikan; T-bar tidak lagi mengambil alih AUTO yang sedang berjalan. Belum dites (T-44) |
| Tombol Fullscreen output (vMix-style) | Implemented (0.9.0) | L (pemilihan layar, 4 unit test) + kompilasi CI | Tombol di bilah atas, ⌘⇧F, atau aksi MIDI. Klik kanan memilih layar (diingat). Program penuh layar tanpa UI; tutup otomatis bila layar dicabut. Belum dites (T-41) |
| Satu menu "Tambah Media" dan "Tambah Media Playlist" | Implemented (0.9.0) | kompilasi CI | File audio jadi input musik (mixer), file video jadi input video; playlist campuran audio+video jadi playlist video (klip audio tampil hitam). Belum dites (T-43) |
| Panel dock yang bisa dikecilkan (Input, Preview/Program, Mixer, Kontrol) | Implemented (0.7.0) | kompilasi CI | Pegangan "–" di atas panel mengecilkan jadi bilah tipis; klik bilah untuk membuka; diingat antar peluncuran. Belum dites (T-37) |

## Sistem
| Fitur | Status | Verifikasi |
|---|---|---|
| CPU/RAM proses, waktu GPU per frame, FPS render, dropped, thermal | Implemented | M |
| Logging os.Logger per kategori, tanpa stream key | Implemented | L (redaksi) + M |
| Shortcut keyboard dapat diubah | Implemented | M |
| UI EN + ID | Implemented | M |
| Simpan/muat proyek (.livecore JSON) | Implemented (M2) | L (model) + M |

## Fitur 0.46.0
Paket 8 permintaan. Verifikasi: L = unit test Linux, M = kompilasi CI macOS. Belum ada yang dites di Mac (TEST_PLAN bagian AV).

| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Tombol PHOTO dipindah | Implemented | M | Dari bawah monitor Program ke dock output, di samping RECORD / STREAM / EXTERNAL, sehingga monitor Preview dan Program kembali sama besar. Konfirmasi "foto tersimpan" tetap muncul di atas Program. |
| Input: Video Capture Device | Implemented | M | Daftar kamera di menu + diganti satu item "Video Capture Device…" yang membuka dialog pilih perangkat (kamera, capture card USB/HDMI, iPhone Continuity) dengan tombol muat ulang; perangkat yang belum dipakai dipilih otomatis. |
| Bug menu AI (on this Mac) berkedip | Implemented | M | Submenu diganti satu item yang membuka jendela kecil (hapus latar, auto-framing, zoom). Penyebab diduga: submenu dibangun ulang tiap thumbnail di-refresh. Belum dikonfirmasi di Mac. |
| Layout scene editor | Implemented | L, M | 10 layout baru (17 total): PiP kiri bawah, 2 PiP, belah dua tinggi, grid 3×3, 1 atas + 3 bawah, sidebar, meja berita, bentuk L, panel 3, panel 4. |
| Scene editor lebih advance | Implemented | L, M | X/Y/W/H dalam persen bisa diketik, rata kiri/tengah/kanan/atas/bawah, penuhi kanvas, geser 1 %, duplikat layer, ratakan jarak mendatar / menurun. (Snap, crop, rotasi tidak berubah dari sebelumnya.) |
| Vertical output lebih advance | Implemented | L, M | Mode isi: potong (ikuti orang) / gambar utuh + latar blur / gambar utuh di hitam; zoom 1–2,5× dan ruang kepala; ketenangan (dead zone); posisi gambar dan kekuatan blur; bitrate audio dan interval keyframe stream vertikal; ukuran baru 1080×1350 (4:5) dan 1080×1080. Setting lama tetap terbaca. |
| Template nama pengantin | Implemented | L, M | Title: Nama pengantin (tengah), Save the date. Lower third: rose gold (huruf naik satu per satu), kartu ivory (huruf memantul). Pojok: hashtag pernikahan. Running text: Pernikahan emas, Pernikahan pink. Font script/Didot bawaan macOS. |
| Frame meeting & conference | Implemented | L, M | 4 frame baru: Konferensi (kamera besar + panel pembicara + strip aksen), Meeting (terang, sudut membulat, bayangan), Webinar (judul kiri, presenter kanan dengan glow), Keynote (kamera tengah, garis aksen). |

## Fitur 0.45.0
Paket 16 permintaan. Verifikasi: L = unit test Linux, M = kompilasi CI macOS. Belum ada yang dites di Mac (TEST_PLAN bagian AU).

| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Template slideshow | Implemented | L, M | 7 template (Pernikahan, Photo booth, Galeri, Layar penuh, Kenangan, Pesta, Korporat): penempatan foto (utuh / penuh / utuh + latar blur), transisi (cross-fade, geser, zoom fade, celup ke latar), bingkai (polaroid, membulat), warna latar. Disimpan di project. |
| Tombol Program Output di sebelah Settings dihapus | Implemented | M | Jendela Program Output masih bisa dibuka dari menu. |
| Pre-flight minta konfirmasi | Implemented | M | Tidak lagi jalan otomatis saat tab dibuka. |
| Bahasa aplikasi | Partial | M | Pilihan bahasa di Settings › Bahasa (berlaku setelah restart). Indonesia dan Inggris lengkap; Melayu, Spanyol, Mandarin hanya layar utama (±100 teks), sisanya Inggris. |
| Animasi overlay di Preview | Implemented | L, M | Nomor overlay ke Preview memakai animasi masuk/keluar yang sama seperti di Program. |
| FPS turun tiba-tiba | Partial | M | Render loop menahan App Nap macOS (penyebab umum FPS turun saat jendela di belakang/tertutup); UI menggambar ulang lebih jarang (0.44). Penyebab lain belum terbukti; log penyebab drop tetap ada. |
| Repeat playlist default mati | Implemented | M | Playlist musik dan playlist video baru tidak mengulang; satu klip video tetap loop. Project lama tetap memakai setelan tersimpan. |
| Mixer: detail bisa dikecilkan | Implemented | M | Tombol di kepala mixer: kecilkan detail strip (sisa nama, meter, fader, M/S/PGM) dan sembunyikan bus A/B. Panel mixer sendiri tetap bisa diminimize. |
| Subtitle AI online | Partial | M | Saat "server Apple" diizinkan, server selalu dipakai (sebelumnya model on-device yang belum terunduh dipilih dan gagal terus). Error ditampilkan dengan kode; dicoba ulang dengan jeda. Butuh internet dan izin Speech Recognition. |
| Jam / countdown lebih lengkap | Implemented | L, M | Mode "sampai jam", jam 12-jam, tanggal, persepuluh detik, warna peringatan, teks saat nol, kedip, overtime; grafis: plat, kapsul, bar aksen, bar progres, cincin progres, 5 font, 4 warna, 6 gaya siap pakai. |
| Animasi title lebih halus + template | Partial | L, M | Kurva ease-in-out cubic; 5 gerak baru (naik+fade, pop, zoom keluar, geser pendek kiri/kanan); 2 animasi huruf baru; 12 template baru (33 total). Belum setara keyframe vMix GT. |
| Settings Canvas | Implemented | M | Panduan monitor: area aman, sepertiga, tanda tengah, bingkai potong 9:16 / 4:3 / 1:1 (hanya di monitor). |
| Settings Output | Implemented | M | Rate control (standar / CBR / VBR), preset encoder (cepat / seimbang / kualitas), keyframe 0,5–10 s, sample rate 44,1/48 kHz. |
| Bitrate stream terpisah | Implemented | L, M | Settings › Stream › Kualitas: sama dengan Output, sama dengan Rekaman, atau bitrate sendiri. |
| Web Controller online | Partial | M | Lewat Cloudflare quick tunnel (butuh `brew install cloudflared`), alamat https + QR, dengan konfirmasi; PIN tetap wajib. Alternatif Tailscale. Tanpa akun/server LiveCore. |
| Settings Audio Mixer | Implemented | M | Limiter (on/off, ceiling, release), volume monitor, tampilan mixer, LUFS dan ducking lengkap di Settings › Audio. |

## Fitur 0.44.0 (0.44.1: perbaikan crash editor rundown saat segmen dihapus/diganti)
Kelancaran dan capture card. Verifikasi: L = unit test Linux, M = kompilasi CI macOS.
Belum ada yang dites di Mac (TEST_PLAN bagian AT).

| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Capture card: mode uncompressed (kelas USB 3) dipilih lebih dulu | Partial | L, M | Tanpa codec yang dipilih manual, YUY2/NV12 menang atas MJPEG/H.264 pada ukuran dan fps yang sama. Format dipasang dengan perangkat terkunci sampai sesi capture berjalan, supaya tidak diganti preset saat start. Kecepatan port USB fisik tidak bisa dibaca aplikasi. |
| Web Controller responsif | Partial | L (sintaks JS) | Breakpoint untuk HP kecil, HP landscape, tablet portrait, tablet landscape, dan desktop (3 kolom). Belum dicoba di perangkat sungguhan. |
| Gambar Program/Preview di Web Controller lebih lancar | Partial | M | Hingga ±15 fps per monitor (sebelumnya ±3); request berikutnya menunggu gambar selesai, jadi jaringan lambat menurunkan fps, tidak menumpuk. Masih JPEG, bukan video, dan ada jeda jaringan. |
| Fader audio mulus | Partial | M | App: geser relatif (tidak lompat ke posisi kursor) dan meter tidak lagi menggambar ulang strip. Web: bug nilai fader tertimpa strip lain diperbaiki; nilai lama dari server diabaikan sebentar. |
| CPU UI lebih rendah | Partial | M | Meter 30 Hz hanya menggambar ulang meter; update switcher selama transisi dibatasi 30/detik. Belum diukur di Mac. |

## Fitur 0.43.0
AI di Mac, kamera iPhone, paket klien, UI responsif. Verifikasi: L = unit test Linux, M = kompilasi CI macOS.
Belum ada yang dites di Mac (TEST_PLAN bagian AS).

| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Hapus background tanpa green screen (per input: klik kanan › AI) | Implemented, belum dites | M | Vision person segmentation (kualitas "balanced"), hasil transparan untuk ditumpuk di layer/scene. Tepi rambut tidak sehalus green screen. Hanya Apple Silicon; di Intel menu AI nonaktif |
| Auto-framing (zoom + mengikuti wajah) | Implemented, belum dites | L (perhitungan) + M | Lebar/Sedang/Dekat; gerak halus dengan dead zone. Diproses di antrean sendiri: tambah 1 frame jeda, frame dilewati bila Mac sibuk (Program tidak turun FPS) |
| Subtitle live (input baru) | Partial, belum dites | L (pemotongan teks) + M | Apple Speech. Bahasa Indonesia **di perangkat tergantung Mac/macOS** (model dikte); bila tidak ada, subtitle tidak jalan kecuali "izinkan server Apple" dicentang (butuh internet). Butuh izin Speech Recognition |
| iPhone sebagai kamera nirkabel | Implemented (Continuity Camera), belum dites | M | macOS 13+, satu iPhone per Mac (batas Apple), Apple ID sama. Beberapa iPhone sekaligus: pakai aplikasi NDI di iPhone + input NDI LiveCore. Aplikasi pendamping LiveCore: belum (butuh akun Apple Developer) |
| Paket klien (Rundown › Paket klien, menu Production) | Implemented, belum dites | L (bab + rentang) + M | Folder berisi: Rekaman (Program, ISO, Vertikal; hard link bila satu disk), "Bab (chapters YouTube).txt" dari segmen rundown, "Highlight 9x16" (20 dtk sebelum s/d 10 dtk sesudah tiap ★ HIGHLIGHT ⇧⌘H), BACA SAYA.txt. Bab belum disematkan ke dalam file video |
| UI responsif | Partial | M | Jendela utama bisa sampai 900×600; bar atas berubah jadi ikon bila sempit; panel input, monitor, mixer dan playlist bisa lebih kecil. Belum: tata letak khusus layar kecil/portrait |

## Fitur 0.42.0
Dua fitur pembeda (usulan yang disetujui pengguna): output vertikal 9:16 bersamaan dengan 16:9, dan rundown acara.
Verifikasi: L = unit test Linux, M = kompilasi CI macOS. Belum ada yang dites di Mac (TEST_PLAN bagian AR).

| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Output vertikal 9:16 (720×1280 / 1080×1920) dari Program | Implemented, belum dites | L (crop) + M | Crop dari Program di GPU (Core Image). Tombol "9:16" di bar atas membuka monitor + setelan |
| Crop mengikuti wajah | Implemented, belum dites | L (pelacak) + M | Vision di Mac, ±6 deteksi/detik, badan atas sebagai cadangan, gerak halus + dead zone; mode Tengah dan Manual |
| Stream vertikal terpisah (1 tujuan RTMP/RTMPS) | Implemented, belum dites | M | Encoder H.264 + AAC sendiri; key di Keychain (akun "vertical"). Belum: SRT, multi-tujuan vertikal |
| Rekaman vertikal bersama RECORD | Implemented, belum dites | M | File "… - Vertical" di folder rekaman, setelan codec sama dengan Recorder |
| Title/overlay khusus vertikal | Planned | – | Sekarang title ikut ter-crop dari Program; title di tepi kiri/kanan terpotong |
| Rundown acara: segmen, GO / BERIKUTNYA (⌘↩), hitung mundur | Implemented, belum dites | L (aksi) + M | Tombol RUNDOWN di bar atas; template Pernikahan dan Seminar; disimpan di proyek |
| Per segmen: input ke Program (CUT/AUTO), title di overlay 1–4, musik putar/stop, lanjut otomatis saat waktu habis | Implemented, belum dites | L + M | Title dari segmen sebelumnya dimatikan otomatis; musik dari input Musik di mixer |

## Fitur 0.41.0
Permintaan pengguna: animasi GT sehalus vMix, animasi keluar mengikuti template, pasang font dari folder (TEST_PLAN bagian AQ).

| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Animasi GT 60 fps, tiap elemen dirender sekali (sprite), easing in-out | Implemented, belum dites | L (kurva) + M | Sebelumnya 30 fps dan seluruh title digambar ulang tiap frame. Kehalusan di Program juga bergantung pada frame rate output |
| Animasi keluar | Implemented, belum dites | L (parser + fase) | Storyboard "Out" dari template bila ada; bila tidak, animasi masuk diputar terbalik (seperti vMix). Diputar saat overlay title dimatikan; CUT langsung dari Program tetap memotong tanpa animasi keluar |
| Pasang font dari folder (sub-folder ikut), font yang sudah terpasang dilewati | Implemented, belum dites | M | Juga ditawarkan saat impor; unduhan Google Fonts juga melewati font yang sudah ada |

Belum diketahui pasti: nama elemen XML untuk storyboard "Out" di vMix GT (sampel tidak memilikinya). Parser mengenali storyboard yang nama/atributnya memuat "Out"; bila template Anda punya animasi keluar tapi tidak terbaca, kirim contohnya.

## Fitur 0.40.0
Editor title GT lanjutan dan font otomatis. Verifikasi: L = unit test Linux, M = kompilasi CI macOS (TEST_PLAN bagian AP).

| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Editor GT: daftar elemen, tampil/sembunyi, pratinjau dengan kotak pilihan yang bisa diseret | Implemented, belum dites | M | Klik kanan input › Editor title GT |
| Properti per elemen: teks, font, ukuran, tebal/miring, rata, warna, garis tepi, sudut, posisi/ukuran, kemiringan, opasitas, ganti gambar | Implemented, belum dites | L (override) + M | Disimpan di proyek sebagai perubahan atas template; file .gtzip tidak diubah. Memilih warna isi mengganti gradasi menjadi warna polos |
| Animasi per elemen (jenis, arah, jeda, durasi) + kecepatan semua animasi + tombol Putar animasi | Implemented, belum dites | L + M | Hanya animasi masuk |
| Font tidak terpasang: ditanyakan saat impor, unduh otomatis dari Google Fonts | Implemented, belum dites | L (URL/CSS) + M | Hanya font yang ada di Google Fonts (gratis). Font berbayar/pribadi (mis. "Motion Picture Personal Use", "SerpentineEF") tidak bisa diunduh otomatis: pasang lewat "Pasang file font…" |
| Font dipasang hanya untuk LiveCore | Implemented | M | Disimpan di Application Support/LiveCore Studio/Fonts, tanpa hak admin |

## Fitur 0.39.0
Impor template title vMix GT (.gtzip). Diuji dengan sampel "Blue news.gtzip" dari pengguna: 14 elemen, logo dan
14 animasi terbaca (uji parser di Linux); gambar hasil render belum dilihat di Mac (TEST_PLAN bagian AO).

| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Impor .gtzip (Graphics › Title vMix GT) | Implemented, belum dites | L (5 tes) + M (kompilasi) | Membaca document.xml + resources.xml; layer diratakan dan dipotong sesuai kotak layer |
| Elemen: Rectangle, Ellipse, TextBlock, Image | Implemented, belum dites | M (kompilasi) | Warna solid, gradasi linear/radial, sudut tumpul, garis tepi, skew, bayangan sederhana |
| Text3D | Partial | M (kompilasi) | Digambar sebagai teks datar + bayangan; efek 3D/ekstrusi tidak ada |
| Animasi masuk saat On Air (Reveal, Expand, Zoom, Fade) | Implemented, belum dites | L (perhitungan frame) | Diputar tiap input masuk Program; di Preview tampil versi selesai. Animasi keluar dan jenis lain belum |
| Ubah teks per field | Implemented, belum dites | M (kompilasi) | Klik kanan input › Ubah teks title GT; tersimpan di proyek (file .gtzip dirujuk, tidak disalin) |
| Data source GT, Feather/crop gambar, efek lain (Blur, Glow, dll.), font tidak terpasang | Planned / tidak didukung | – | Font yang tidak ada di Mac diganti font sistem; pasang font template dulu |

Lisensi: template bawaan vMix tidak boleh dibagikan bersama LiveCore; impor hanya untuk template milik pengguna.

## Fitur 0.38.0
Perbaikan dari laporan pengguna setelah 0.37.0, plus input radio online. Kolom Verifikasi: L = unit test Linux,
M = dikompilasi/diuji di CI macOS; "belum dites" = belum dicoba pengguna di Mac (TEST_PLAN bagian AN).

| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Jendela edit Web: halaman diperkecil pas ke jendela | Implemented, belum dites | M (kompilasi) | Tata letak sama dengan output (lebar CSS sama), letterbox hitam; scroll halaman sendiri jalan; tombol hijau memperbesar (T-182) |
| Fullscreen di halaman: ukuran "layar" = ukuran input | Implemented, belum dites di WebKit | Uji skrip di Chromium (Playwright) | `screen.width/height` halaman = ukuran input, sehingga player tidak tampak nge-zoom/terpotong (T-183) |
| PRE-FLIGHT pindah ke Pengaturan | Implemented | M (kompilasi) | Tab "Pre-flight" di Pengaturan; menu Production › Pre-flight (⇧⌘P) membuka tab itu |
| Switch Operator/Lanjutan dihapus | Implemented | M (kompilasi) | Selalu tampilan lengkap; yang sempat memilih Operator di 0.37.0 otomatis kembali |
| Animasi title per huruf di antrean sendiri | Implemented, belum dites | M (kompilasi) | Tidak lagi tersendat saat menu/lembar dibuka (T-184) |
| 3 frame GPU dalam antrean (sebelumnya 2) | Implemented, belum dites | M (soak check) | Menahan hentakan GPU singkat; latensi maks +1 frame |
| Log penyebab drop & thread UI macet | Implemented | L (watchdog) + M | Di log (Bantuan › Ekspor Log & Diagnostik): "render drops +N (late tick, GPU busy, failed)" dan "main thread did not answer for X ms" (T-185) |
| Meter & statistik tetap jalan saat menu terbuka | Implemented | M (kompilasi) | Timer statistik di run loop mode common |
| CI lebih cepat | Implemented | M | DMG dibuat paralel dengan cek mesin; DMG terbit setelah build app + unit test |
| Input Radio Online (Radio Browser) | Implemented, belum dites | L (6 unit test) + M (livecore-radio-check: MP3 mono 44,1 kHz dan AAC stereo, judul lagu ICY) | Gratis tanpa API key. Hanya stasiun HTTPS MP3/AAC (bukan HLS/Ogg). Channel mixer sendiri, play/stop, judul lagu, sambung ulang otomatis (T-186..T-189) |
| Radio: hak siar | Catatan | — | Memutar radio di siaran/rekaman umumnya butuh izin; YouTube/Facebook bisa membisukan stream. Peringatan tampil di jendela cari |
| Musik bebas royalti (Jamendo dsb.) | Planned | — | Butuh client ID gratis dari pengguna; lebih aman untuk siaran |
| Uji disk penuh di soak check | Known issue | M (gagal) | Rekaman ke disk 160 MB berakhir "Disk Full" alih-alih ditutup rapi; pemakaian normal berhenti di sisa 1 GB |

## Fitur 0.37.0
Rilis stabilisasi + fitur dari evaluasi 0.36.0. Semua dikompilasi di CI macOS; kolom Verifikasi menyebut uji otomatis.
"Belum dites" = belum dicoba di Mac oleh pengguna (lihat TEST_PLAN bagian AM).

| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Perbaikan: sisa ruang disk di drive eksternal/disk image (HFS+, exFAT) | Fixed | M (CI soak check: rekam ke disk image 64 MB sampai penuh) | Sebelumnya bisa terbaca "0 KB free" sehingga rekaman ke drive eksternal menolak mulai. Sisa ruang kini dicek tiap detik dengan cadangan 4 dtk tulis, jadi file ditutup rapi sebelum disk penuh |
| Autosave tiap 30 dtk + tawaran pemulihan setelah crash | Implemented, belum dites | L (3 unit test: crash, keluar normal, tanpa autosave) | Simpanan di `~/Library/Application Support/LiveCore Studio/Autosave`; tidak ada stream key di dalamnya (T-170) |
| Log file + Ekspor Log & Diagnostik | Implemented, belum dites | L (rotasi, sensor rahasia, isi bundel) | `~/Library/Logs/LiveCore Studio`; zip berisi ringkasan, setelan, proyek, log sistem app, laporan crash. Stream key, Stream ID SRT dan PIN dihapus (T-172) |
| Undo/redo (⌘Z / ⇧⌘Z) | Implemented, belum dites | L (riwayat + penggabungan geser) + kompilasi CI | Tutup/tambah/ganti nama input, Layer Designer, Title Designer, editor Scene. Bidang teks memakai undo teksnya sendiri (T-171) |
| Mode Operator / Lanjutan | Implemented, belum dites | kompilasi CI | Operator menyembunyikan CPU/GPU/MEM, pengaturan, ISOCORDER & EXTERNAL (kecuali sedang jalan), capture card, NDI, layar capture, colour bars (T-176) |
| Panel Outputs | Implemented, belum dites | kompilasi CI | RECORD, STREAM (status per tujuan), ISOCORDER, EXTERNAL (Syphon/NDI), FULLSCREEN di satu panel dengan status (T-177) |
| Pre-flight check | Implemented, belum dites | L (aturan, 1 unit test) + kompilasi CI | Input, izin kamera/mic, audio 3 dtk (hening/clipping), tujuan stream + uji koneksi TCP ke server RTMP, ruang disk vs lama acara, FPS, panas, baterai (T-173) |
| Template proyek + layar sambutan | Implemented, belum dites | L (dokumen template konsisten) | Pernikahan, Seminar, Rapat dari kamera & mic yang tersambung (T-174) |
| Meter LUFS (EBU R128) | Implemented, belum dites | L (nada referensi −23 LUFS ±0,1; gating hening) | Momentary, short-term, integrated di master; reset (T-175) |
| Ducking musik | Implemented, belum dites | L (attack/hold/release, setelan) | Channel ditandai pemicu (mic) / target (musik); template Pernikahan menyalakannya (T-175) |
| Sumber data title (CSV, Excel .xlsx, Google Sheets) | Implemented, belum dites | L (CSV RFC 4180, XLSX sheet pertama, tautan Sheets) | Pilih kolom judul/subjudul, pindah baris dari menu, Web Controller atau Companion; tautan dimuat ulang berkala (T-179) |
| Kontrol kamera PTZ (VISCA over IP / UDP / TCP) | Implemented, belum dites | L (byte VISCA, paket Sony) + kompilasi CI | Panah tahan-untuk-gerak, zoom, home, auto focus, 8 preset (panggil/simpan, nama). Video tetap lewat input kamera/NDI (T-180) |
| Stream Deck / Companion | Implemented (API), belum dites | L (rute API) | Lewat modul Generic HTTP; panduan di docs/COMPANION.md; perintah baru PTZ & baris data (T-178) |
| Output SRT (caller, MPEG-TS) | Implemented, belum dites di Mac | L (E2E ke ffmpeg/libsrt: semua frame diterima, termasuk 4% paket hilang yang dikirim ulang) + uji engine di CI macOS | Isi tujuan stream dengan `srt://host:port`; kolom key = Stream ID. Tanpa enkripsi passphrase (T-181) |
| Uji soak & kegagalan di CI | Implemented | CI macOS (engine asli) | Rekam + stream 90 dtk, server RTMP dimatikan di tengah (stream reconnect, rekaman tidak putus), cek kebocoran memori, SRT dari engine, disk 64 MB penuh (rekaman berhenti sendiri dan file tetap bisa diputar) |
| ProductionEngine & AppModel dipecah per domain | Implemented | kompilasi CI + semua tes | Tidak ada perubahan perilaku |
| Label Eksperimental | Implemented | — | PowerPoint Live, RSS teks berjalan, animasi per huruf, edit halaman web |
| Input SRT, WebRTC/WHIP tamu | Planned | — | Butuh dekoder MPEG-TS + jitter buffer (SRT input) atau stack WebRTC (ICE/DTLS/SRTP/Opus) yang belum ada; tidak dimasukkan agar tidak setengah jadi |
| NV12 capture / ticker & slideshow di GPU | Planned | — | Optimasi kinerja; ditunda karena butuh pengukuran di Mac Intel pengguna |
| Developer ID, auto-update Sparkle, HTTPS Web Controller | Blocked | — | Butuh akun Apple Developer pengguna (penandatanganan & notarisasi) |

## Fitur 0.36.1
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Fullscreen halaman di dalam input Web | Implemented, belum dites di Mac | L (skrip diuji di Chromium headless: elemen 1280×720, event, Escape, iframe embed) | Fullscreen API diganti di awal halaman: tombol fullscreen situs membuat player memenuhi gambar input; tetap setelah Selesai. Keluar: tombol situs atau Escape di jendela edit (T-166) |
| Layar hitam setelah Selesai | Fixed, belum dites di Mac | kompilasi CI | Jendela edit tidak bisa lagi masuk Space layar penuh (tombol hijau = perbesar); bila tetap layar penuh, keluar dulu sebelum ditutup (T-167) |

## Fitur 0.36.0
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Input Web: jendela edit dengan bar alamat | Implemented, belum dites | kompilasi CI | Memperbaiki bug 0.35.0 (jendela menutupi app tanpa title bar). Halaman pindah ke jendela biasa (80% layar, bisa digeser) dengan back/forward/reload/alamat dan Selesai; alamat terakhir disimpan ke input. Enter di halaman tidak lagi menekan Selesai (T-156) |
| Input Web: suara ke mixer | Implemented, belum dites | kompilasi CI | macOS 14.2+: Core Audio process tap pada proses WebKit milik app → channel "Web audio" (semua input web berbagi satu channel); suara di speaker dibisukan sehingga hanya lewat mixer. macOS meminta izin Perekaman Audio Sistem. macOS 13–14.1: suara tetap ke speaker (T-157) |
| Input Web: video saja, zoom, CSS, bisukan | Implemented, belum dites | L (skrip & escape, 2 unit test) | Video saja menyembunyikan semua elemen kecuali video dan memenuhi gambar (YouTube, Facebook, Vimeo); bisa gagal di situs yang memakai transform pada pemutar (T-158) |
| Animasi title per huruf | Implemented, belum dites | L (timing & gerak, 3 unit test) | Mesin ketik, memudar, naik, turun, membesar; jeda 10–300 ms per huruf. Diputar setiap title masuk Program/overlay; bisa dicoba di pratinjau Title Designer (T-159) |
| PowerPoint mode Live | Implemented, belum dites | L (proyek, 1 unit test) + kompilasi CI | Butuh Microsoft PowerPoint, izin Automation dan Screen Recording. Slideshow diputar di jendela PowerPoint dan ditangkap beserta suaranya; ◀ ▶ dan Page Up/Down mengendalikan PowerPoint (animasi klik ikut). Satu slideshow live sekaligus (T-160, T-161) |
| Input Frame kamera, 8 template | Implemented, belum dites | L (tata letak, round-trip, 4 unit test) + kompilasi CI | Bingkai bersih, membulat, lingkaran, polaroid, neon, broadcast (LIVE), vertikal 9:16, sinema. Kamera di layer kedua dengan sudut/lingkaran/border; tanpa kamera bisa dipakai sebagai overlay (T-162, T-163) |
| Page Down / Page Up untuk slide | Implemented, belum dites | kompilasi CI | Presentasi di Program, lalu Preview, lalu yang pertama (T-164) |
| PHOTO → input | Implemented, belum dites | kompilasi CI | Tombol "Jadikan input" pada banner foto (T-165) |

## Fitur 0.35.0
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Animasi saat nomor overlay ditekan, per template title | Implemented, belum dites | L (default & decode animasi, 1 unit test) + kompilasi CI | Tab Animasi di Title Designer: jenis animasi + durasi, atau pakai animasi kanal overlay. Seluruh title bergerak bersama (bukan per huruf/elemen); keluar = gerakan yang sama dibalik (T-145) |
| Teks berjalan di Title Designer + setelan lanjutan | Implemented, belum dites | L (config, clamp, template, teks gulir, 4 unit test) | Menu "Teks berjalan" lama dihapus; kini kategori di Title Designer dengan 6 template, label, pemisah, font, ketebalan, miring, huruf besar, posisi pita, bayangan, animasi. Proyek lama tampil sama (T-146) |
| Media: AUTO play + restart on/off | Implemented, belum dites | L (proyek, 1 unit test) + kompilasi CI | Media baru: AUTO aktif + restart ON (mulai dari awal tiap ke Program, kembali ke awal saat keluar). Restart OFF = jeda saat keluar dan lanjut dari posisi terakhir (T-147) |
| ISOCorder: bus audio per input | Implemented, belum dites | L (simpan/buka, 1 unit test) + kompilasi CI | Tiap file ISO bisa Master / Aux A / Aux B; bawaan = bus profil. Tiap bus dicampur sekali walau dipakai beberapa file (T-148) |
| Tombol minimize input di baris atas | Implemented, belum dites | kompilasi CI | Muncul saat kursor di atas tile, di antara tombol fullscreen (viewer) dan X (T-149) |
| Konfirmasi tombol PHOTO | Implemented, belum dites | kompilasi CI | Kilat putih + bunyi + banner "Foto tersimpan" 3 detik; klik banner = tampilkan di Finder (T-150) |
| Input Web: edit halaman sebelum tampil | Implemented, belum dites | kompilasi CI | Menu/ikon tangan: halaman dibuka di jendela untuk klik dan mengetik; Program menahan gambar terakhir (bisa dimatikan) sampai "Selesai — tampilkan". Login tidak tersimpan setelah app ditutup (T-151, T-152) |
| Input PowerPoint / Keynote / PDF | Implemented, belum dites | L (jenis file, navigasi, rotasi & fit halaman, proyek, 5 unit test) + kompilasi CI | PDF dibaca langsung. .pptx/.ppt/.key/.odp diekspor ke PDF (cache) oleh Keynote, PowerPoint atau LibreOffice yang terpasang; macOS meminta izin Automation sekali. Slide statis: animasi, transisi dan video di dalam slide tidak diputar (T-153..T-155) |

## Title Designer 0.34.0
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| 21 template (12 lower third, 6 judul, 3 pojok) | Implemented (0.34.0), belum dites di Mac pengguna | L (katalog, tata letak tiap template di 1080p/720p/potret tetap di dalam gambar; unit test) + CI `livecore-title-check`: semua template dirender CoreText sungguhan, gagal bila ada yang kosong; lembar contoh `title-templates.png` dilampirkan di rilis | Tambah Input › Title: galeri bergambar per kategori; ganti template tanpa kehilangan teks (T-141) |
| Setelan lanjutan seperti vMix | Implemented (0.34.0), belum dites | L (batas nilai, simpan/baca, proyek lama; unit test) + kompilasi CI | Teks: font terpasang, ketebalan judul/subjudul, miring, HURUF BESAR, jarak huruf & baris, rata, warna judul/subjudul/label. Kotak: tampil/sembunyi, warna kotak/kotak kedua/aksen, sudut, pil, padding, lebar minimum. Posisi: 9 titik, geser X/Y, margin aman, ukuran 50–200%. Efek: outline, bayangan (blur, jarak, warna). Pratinjau langsung (T-142) |
| Title layar penuh di overlay | Implemented (0.34.0), belum dites | kompilasi CI | Title template menutupi seluruh output (transparan); overlay yang memakai preset Lower third otomatis jadi Full screen. Animasi masuk/keluar tetap dari overlay (fade, slide, zoom) (T-143) |
| Title lama (0.3.0–0.33) | Implemented (0.34.0) | L (konversi; unit test) | Tetap tampil sama; saat dibuka di editor menjadi template terdekat (strap klasik / bar selebar layar / headline) |
| Belum ada | Planned | — | Simpan preset sendiri, gambar/logo di dalam title, field lebih dari 3, animasi per elemen, data dari file/CSV (data source vMix) |

## Dock bawah 0.33.1
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Nama MultiCorder → ISOCorder | Implemented (0.33.1) | L (label validasi; unit test) | Tombol ISOCORDER, tab Settings › ISOCorder; file proyek & setelan lama tetap terbaca (kunci internal tidak berubah) |
| Dock menyesuaikan lebar jendela, teks tidak terpotong | Diganti (0.34.0): teks status dihapus atas permintaan, tombol diberi jarak dari ⚙; chip OUT tanpa nama sumber di jendela sempit | kompilasi CI | ≥1660 pt: status 2 baris di samping tombol + chip OUT bernama; ≥1380 pt: status lebih sempit (mengecil sedikit bila panjang), chip "OUT n" saja; lebih sempit: status singkat di dalam tombol. Status lengkap dan sumber OUT di tooltip (T-140) |

## MultiCorder terpisah & Recorder lanjutan 0.33.0
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Tombol ISOCORDER sendiri, terpisah dari RECORD | Implemented (0.33.0), belum dites di Mac pengguna | kompilasi CI | Dock: ISOCORDER + ⚙ (pilih input maks 4, status per file); mulai/berhenti tanpa memengaruhi RECORD; berhenti minta konfirmasi; ikut gembok RECORD (T-134) |
| Profil rekaman MultiCorder sendiri | Implemented (0.33.0), belum dites | L (profil terpisah, validasi, simpan/baca; unit test) | Settings › ISOCorder; bawaan HEVC 25 Mbps MOV; folder, pola nama, codec, bitrate, keyframe, audio, bus sendiri (T-135) |
| Setelan lanjutan Recorder & MultiCorder | Implemented (0.33.0), belum dites | L (default lama tetap, ProRes/PCM paksa MOV, perkiraan GB/jam; unit test) + CI `livecore-iso-check` merekam H.264, HEVC, ProRes 422 | Codec H.264/HEVC/ProRes 422 Proxy/LT/422/HQ; bitrate 2–150 Mbps; keyframe 0,5–10 s; B-frame; AAC 128–320 kbps atau PCM 24-bit; setelan yang ditolak Mac menggagalkan rekaman dengan pesan, bukan crash (T-136) |
| Optimasi 4 ISO tanpa drop | Partial (0.33.0) | CI: Program + 4 ISO 1080p30 5 detik per codec, file valid, drop dicetak per file (CI Mac virtual tanpa media engine, angka drop hanya informasi) | Encoder hardware diminta, B-frame mati bawaan, tiap file antrean tulis sendiri, frame tidak menunggu encoder (dibuang & dihitung bila encoder penuh). Tidak bisa dijamin 0 drop di semua Mac; lihat KNOWN_ISSUES 70 (T-137) |

## Grup warna & minimize input 0.33.0
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Label warna input + grup otomatis | Implemented (0.33.0), belum dites di Mac pengguna | L (pengelompokan, urutan, filter; unit test) + kompilasi CI | Klik kanan input › Label warna (8 warna); warna sama = satu grup dengan judul berwarna, bisa diganti nama dan dilipat; input tanpa label di grup terakhir; strip warna di atas tile (T-138) |
| Filter per warna | Implemented (0.33.0), belum dites | L (unit test) | Chip "Semua" + tiap warna yang dipakai dengan jumlahnya (T-138) |
| Minimize input seperti vMix | Implemented (0.33.0), belum dites | kompilasi CI | Tombol − di tile atau klik kanan; tile jadi baris ringkas (warna, nomor, nama); klik = Preview, klik ganda = CUT; minimize/buka semua atau per grup (T-139) |
| Disimpan di proyek | Implemented (0.33.0) | L (simpan/baca; unit test) | Label, status minimize dan nama grup ikut proyek; proyek lama terbuka tanpa label (T-139) |

## MultiCorder 0.32.0
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Rekam input pilihan ke file sendiri (ISO) bersama RECORD | Implemented (0.32.0), belum dites di Mac pengguna | L (pilihan, batas 4, nama file, proyek; unit test) + CI `livecore-iso-check`: rekaman Program + ISO berjalan bersamaan dan keduanya bisa diputar dengan video+audio | RECORD ⚙ › MultiCorder (ISO): centang input (maks 4). Input dirender ukuran output penuh dengan layer-nya; H.264 dengan bitrate/format rekaman; nama = file Program + " - ISO <nomor> <nama>" dengan waktu yang sama; pilihan tersimpan di proyek (T-131..T-132) |
| Status tiap file ISO | Implemented (0.32.0), belum dites | kompilasi CI | Ukuran file, frame terbuang, gagal (tidak menghentikan rekaman Program), tombol tampilkan di Finder (T-133) |

## Web Controller 0.31.0 (panel switcher)
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Tampilan panel hardware (bus Preview/Program, tombol menyala, tuas T-bar, LED + timer REC/LIVE, keypad PIN) | Implemented (0.31.0), belum dites di HP pengguna | Dites di browser ukuran iPhone 13 dan tablet 1180×820 (klik bus, transisi, T-bar sentuh & mouse, mute) | HP: satu kolom, T-bar horizontal; layar ≥900 px: dua kolom, T-bar vertikal. Getar hanya di browser yang mendukung (Android; Safari iOS tidak) (T-127) |
| Gambar Program/Preview langsung | Implemented (0.31.0), belum dites | L (rute + tes socket: JPEG butuh PIN) + kompilasi CI | JPEG 640 px kualitas 0,6, ±3 per detik per monitor; dibuat hanya saat ada halaman yang memintanya dalam 3 detik terakhir (T-128) |
| Pilih transisi + durasi dari HP | Implemented (0.31.0), belum dites | L (rute; unit test) + kompilasi CI | Daftar sama dengan aplikasi; stinger muncul bila klipnya dipilih; shader custom yang dipilih ikut tampil; durasi 0,5–3 s (T-129) |
| Mixer audio dari HP | Implemented (0.31.0), belum dites | L (rute, JSON; unit test) + kompilasi CI | Fader master & per kanal (hukum fader sama: 0,75 = 0 dB), mute per kanal, meter peak L/R; belum ada solo/EQ/bus dari HP (T-130) |

## Web Controller 0.30.0
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Remote dari browser HP/tablet (Preview, CUT, AUTO, T-bar, overlay 1–4, replay 5/10/20 s, snapshot) | Implemented (0.30.0), belum dites di Mac pengguna | L (parser HTTP, rute, JSON status; unit test) + tes socket server sungguhan di CI Linux & macOS + halaman dites di browser ukuran HP | Settings › Remote; mati secara default; port 8088 (bisa diubah); halaman satu file tanpa sumber eksternal, bahasa ikut browser (Indonesia/Inggris); status diperbarui 2× per detik (T-119..T-122) |
| Rekam / streaming dari remote | Implemented (0.30.0), belum dites | L (rute start/stop eksplisit) + kompilasi CI | Berhenti minta konfirmasi di HP; gembok RECORD/STREAM di aplikasi tetap berlaku (T-123) |
| Keamanan: PIN di Keychain, kunci setelah PIN salah, cek Host | Implemented (0.30.0) | L (unit test PIN, lockout bertingkat, Host) | PIN 6 digit acak; tiap API butuh header PIN; 5 salah → kunci 1 menit, naik 2× tiap kali (maks 1 jam); hanya Host berupa IP/localhost/.local (melawan DNS rebinding); PIN baru mengeluarkan semua perangkat. Koneksi HTTP biasa, lihat KNOWN_ISSUES 67 (T-124..T-125) |
| QR code + daftar alamat + jumlah perangkat | Implemented (0.30.0), belum dites | kompilasi CI | QR berisi alamat + PIN, tersembunyi sampai dibuka; PIN juga tersembunyi sampai tombol mata diklik (T-126) |

## Input NDI 0.29.0
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Sumber NDI® sebagai input (video) | Implemented (0.29.0), belum dites di Mac pengguna | L (nama sumber, model proyek; unit test) + CI `livecore-ndi-check`: `NDIFinder` menemukan sumber dari proses lain dan input `NDISource` menerima frame BGRA 1280×720 merah | Tambah › Sumber NDI…: daftar sumber di jaringan (diperbarui otomatis) atau ketik nama; output LiveCore sendiri ditandai; satu sumber = satu input; tersambung kembali sendiri. Sumber ber-alpha (BGRA) tetap transparan (T-116) |
| Audio input NDI ke mixer | Implemented (0.29.0), belum dites | kompilasi CI | Kanal mixer "ndi:<input>" dengan AFV, tersimpan di proyek; bisa dimatikan per input (T-117) |
| Bandwidth rendah, info sinyal, chroma key | Implemented (0.29.0), belum dites | kompilasi CI | Stream preview kecil dari pengirim; resolusi/fps/audio/alpha tampil saat mengedit; menu Key tersedia untuk input NDI (T-118) |

## Capture card lanjutan 0.28.0
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Format video perangkat (uncompressed YUY2/UYVY/NV12/v210, MJPEG, H.264) | Implemented (0.28.0), belum dites | L (pemilihan format per codec; unit test) + kompilasi CI | Daftar diambil dari format yang dilaporkan perangkat untuk resolusi terpilih; gambar tetap diubah ke BGRA 8-bit untuk compositor (lihat KNOWN_ISSUES 65) (T-112) |
| Perbaikan rentang warna limited ↔ full | Implemented (0.28.0), belum dites | L (rumus level; unit test) + kompilasi CI (shader) | Berjalan di GPU bersama koreksi warna input; tidak ikut ter-reset oleh tombol reset koreksi warna (T-113) |
| Deinterlace (blend) | Implemented (0.28.0), belum dites | kompilasi CI (shader) | Mencampur baris tetangga; sederhana, sedikit melembutkan detail vertikal (T-113) |
| Buffer frame (mulus vs latensi rendah) | Implemented (0.28.0), belum dites | kompilasi CI | Default tetap latensi rendah (T-114) |
| Info sinyal + Mulai ulang perangkat | Implemented (0.28.0), belum dites | kompilasi CI | Ukuran, format, fps terukur, frame terbuang; diperbarui tiap detik saat mengedit input (T-115) |

## Perbaikan 0.27.0
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Instant replay tidak crash | Implemented (0.27.0), belum dites | kompilasi CI | Crash di macOS 27 saat replay mulai merekam (adaptor dibuat setelah writer mulai); kini dibuat sebelum `startWriting` (T-107) |
| Edit layer baru tampil di Program setelah transisi, tanpa tombol Terapkan | Implemented (0.27.0), belum dites | L (rencana gambar draft) + kompilasi CI | Menggantikan perilaku 0.26.0: tidak ada tombol Terapkan/Batalkan/DRAFT; menutup designer atau memindah Preview tidak mengirim ke Program; draft tiap input disimpan sampai input itu dibawa ke Program dengan CUT/AUTO/T-bar/quick play; ikut tersimpan di file proyek (T-108) |
| T-bar horizontal, hanya persen | Implemented (0.27.0), belum dites | kompilasi CI | Tuas horizontal dengan skala dan pegangan metal; di bawahnya hanya angka persen (T-109) |
| Repeat One | Implemented (0.27.0), belum dites | L (unit test) + kompilasi CI | Tombol Ulangi berputar: mati → ON (playlist) → 1 (item ini); musik & video; Repeat One musik tersimpan di proyek (T-110) |
| Berhenti setelah item ini, bar waktu + seek, Putar berikutnya | Implemented (0.27.0), belum dites | L (unit test) + kompilasi CI | Tombol ⏹ sekali pakai; bar waktu berjalan/sisa, klik untuk lompat; menu klik kanan "Putar berikutnya" (T-111) |

## Perbaikan 0.26.0
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Edit layer tidak langsung tampil di Program (draft) | Diubah di 0.27.0 (tanpa tombol Terapkan) | L (rencana gambar: draft hanya di Preview, juga untuk input yang di-flatten; unit test) + kompilasi CI | Badge DRAFT + Terapkan / Batalkan di bar Layer Designer; draft masuk Program saat Terapkan, menutup designer, CUT/AUTO/T-bar, atau memilih input lain di Preview (T-101) |
| Geser & ubah ukuran layer lebih halus | Implemented (0.26.0), belum dites | kompilasi CI | Gerakan diukur di ruang koordinat kanvas yang tetap (sebelumnya ikut bergeser bersama kotak yang sedang ditarik) (T-101) |
| Label FULLSCREEN satu baris | Implemented (0.26.0), belum dites | kompilasi CI | Tombol utama sedikit lebih lebar, label tidak pernah pindah baris (T-102) |
| Kamera / capture tidak bisa ditambahkan dua kali | Implemented (0.26.0), belum dites | L (pencocokan jendela/layar yang sama; unit test) + kompilasi CI | Di menu tambah, lembar capture card, dan lembar capture jendela/layar: item yang sudah dipakai ditandai "sudah dipakai (input N)" dan tidak bisa dipilih (T-103) |
| Repeat / Shuffle playlist dengan penanda aktif | Implemented (0.26.0), belum dites | L (shuffle tidak mengulang klip yang sama) + kompilasi CI | Tombol menyala biru + "ON" saat aktif; musik: repeat & shuffle; video playlist: repeat & shuffle (baru) (T-104) |
| T-bar profesional | Diganti di 0.27.0 (horizontal) | kompilasi CI | Tuas vertikal dengan jalur, skala, pegangan metal, isi biru sesuai posisi, angka persen / AUTO (T-105) |
| Settings › Canvas: Horizontal, Portrait, Custom | Implemented (0.26.0), belum dites | L (ukuran preset, ukuran custom genap & dibatasi 240–3840; unit test) + kompilasi CI | Tab pertama di Settings; 720p/1080p untuk Horizontal & Portrait, ukuran bebas untuk Custom; monitor Preview/Program, Multiview dan editor Scene mengikuti bentuk canvas; terkunci selama stream/rekam (T-106) |

## Layer Designer dan tata letak 0.25.0
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Layer Designer di monitor Preview: geser & ubah ukuran langsung, snapping | Implemented (0.25.0), belum dites | L (pegangan sisi, snapping ke tepi/tengah/garis aman/layer lain; unit test) + kompilasi CI | Tombol LAYER di kepala monitor Preview; 8 pegangan; sudut menjaga bentuk (Shift = bebas); tahan ⌘ untuk mematikan snapping; garis bantu tampil saat menempel (T-96) |
| Crop dengan menarik tepi, simetris dengan Shift | Implemented (0.25.0), belum dites | L (gambar tetap di tempat, batas 45 %/sisi; unit test) | Mode Crop; tepat untuk Stretch, atau Fit/Fill bila kotak seaspek gambar (KNOWN_ISSUES 59) (T-96) |
| Bingkai, warna, sudut melengkung, bentuk elips | Implemented (0.13.0), kini juga di Layer Designer | GPU sejak 0.13.0 | Tombol bingkai di bar Layer Designer (T-97) |
| Hide/show dan kunci layer | Implemented (0.25.0), belum dites | L (layer tersembunyi tidak digambar dan tidak dihitung AFV; proyek lama tetap terbaca) | Disimpan di proyek (T-97) |
| Flatten Layers | Implemented (0.25.0), belum dites | L (rencana gambar: satu gambar per input, urutan bertingkat, siklus aman) + kompilasi CI (render GPU) | Semua layer input digambar ke satu tekstur dulu; dipakai di mana pun input itu muncul sebagai satu gambar (layer input lain, overlay, output, thumbnail) (T-98) |
| Simpan tata letak sebagai template | Implemented (0.25.0), belum dites | L (cocok per urutan, sumber tetap, layer tambahan bila inputnya ada) | Disimpan di Mac ini (bukan di file proyek) (T-97) |
| Tombol FULLSCREEN + ⚙ (layar & gambar per output) | Implemented (0.25.0), belum dites | L (pemilihan layar ke-2/ke-3; unit test) + kompilasi CI | Menggantikan tombol fullscreen Program lama; output yang dicentang dibuka di layarnya; MIDI "Fullscreen" memakai tombol ini (T-99) |
| Tombol FOTO seukuran RECORD/STREAM/FULLSCREEN, transisi awal Dissolve, dock Playlist muncul setelah ada playlist | Implemented (0.25.0), belum dites | kompilasi CI | Dock Playlist muncul bila ada input musik atau video (T-100) |

## Output NDI (0.24.0)
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Kirim output 1–4 sebagai sumber NDI® | Implemented (0.24.0), belum dites di Mac pengguna | L (routing, kompatibilitas proyek lama; 4 unit test) + CI `livecore-ndi-check`: proses lain menemukan sumber "LiveCore Output 1 (check)" lewat NDI dan menerima frame 1280×720 merah | Centang NDI per output di EXTERNAL ⚙; Output 1 otomatis NDI saat EXTERNAL pertama kali nyala bila runtime NDI ada. Video BGRX, audio Program stereo. Frame dibuang (bukan menunggu) bila kompresi NDI belum selesai (T-93) |
| Zoom / Meet tanpa OBS | Implemented lewat NDI Tools, belum dites | — | Di NDI Tools (NDI Virtual Input) pilih "<Mac> (LiveCore Output 1)", di Zoom pilih "NDI Virtual Camera" (T-94) |
| Runtime NDI | Dimuat saat jalan (dlopen), tidak disertakan | build: entitlement `disable-library-validation` dicek | Dicari di `NDI_RUNTIME_DIR_V6`, `/usr/local/lib`, SDK, Homebrew, dan app NDI di /Applications. Tidak ada → pesan + link unduh NDI Runtime (T-95) |

## Perubahan tata letak 0.23.0
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Nomor overlay 1–4 di bawah tiap kotak input (vMix-style) | Implemented (0.23.0), belum dites | kompilasi CI | Klik = Preview (oranye), klik kanan / dua jari = Program (hijau); selalu layar penuh + fade. Dock Overlay (pilihan source, posisi, animasi) dihapus (T-91) |
| Instant replay di bawah T-bar | Implemented (0.23.0), belum dites | kompilasi CI | Panel kontrol kanan dihapus; mixer dan Playlist mendapat ruang lebih (T-92) |
