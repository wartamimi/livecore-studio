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
| Text / lower third (CoreText) | Implemented | M | 0.3.0: 3 layout (kotak, bar penuh, caption tengah), ukuran font, warna teks & bar; animasi masuk = fade overlay |
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
| Audio NDI | Planned (M3) | — | |

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
| NDI | Blocked → Planned M3 | Perlu NDI SDK + kepatuhan lisensi |
| Virtual camera (seperti OBS) | **Blocked** | Butuh CoreMediaIO Camera Extension yang ditandatangani dengan akun Apple Developer; build ad-hoc tidak bisa memasangnya. Lihat KNOWN_ISSUES 44 |

## Kontrol
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Shortcut keyboard yang bisa diatur | Implemented | M | |
| Kontrol MIDI dengan Learn (CUT, AUTO, T-bar, preview/cut 1–8, overlay 1–4, stream, rekam, snapshot) | Implemented (0.7.0) | L (parser MIDI 1.0/UMP, pemetaan, 6 unit test) + kompilasi CI | Semua sumber CoreMIDI tersambung otomatis; pemetaan disimpan di Mac (bukan proyek). Belum dites dengan controller (T-35) |
| Input tangkap jendela / layar (Zoom, Teams, Meet, slide) | Implemented (0.10.0) | L (pencocokan jendela, 5 unit test) + kompilasi CI | ScreenCaptureKit; audio aplikasi (jendela) atau sistem (layar) ke channel mixer sendiri; audio & jendela LiveCore sendiri dikecualikan; jendela ditemukan lagi lewat aplikasi + judul saat proyek dibuka. Perlu izin Perekaman Layar. Belum dites (T-46) |
| Input Zoom via Zoom Meeting SDK (peserta terpisah, seperti vMix) | Ditunda (dihapus dari build publik di 0.10.1) | — | Pernah dibuat di 0.11.x dan dikompilasi dengan SDK, lalu ditarik dari repo & rilis publik atas keputusan pemilik; diarsipkan secara privat. Join meeting akun lain gagal (kode 63) sampai aplikasi SDK lolos review Zoom Marketplace. Untuk sekarang pakai input tangkap jendela |
| Program sebagai kamera virtual (untuk Zoom) | Blocked | — | Perlu CoreMediaIO Camera Extension yang ditandatangani Developer ID; build saat ini unsigned |
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
