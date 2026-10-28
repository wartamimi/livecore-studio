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
| Virtual camera sendiri (Camera Extension seperti OBS) | Dihapus (0.23.0) | Dibuat di 0.22.0 lalu dihapus atas permintaan pemilik (butuh tanda tangan Developer ID). Pakai Syphon → OBS → OBS Virtual Camera |
| Syphon (kirim output ke OBS, Resolume, MadMapper…) | Implemented (0.22.0), diperbaiki 0.23.0, belum dites di Mac pengguna | Server Syphon (kode BSD, di-vendor) per output; nyala saat EXTERNAL aktif (Output 1 otomatis bila belum ada yang dipilih); frame dikirim sejak server dibuat; status "aplikasi tersambung" di EXTERNAL ⚙. CI `livecore-syphon-check`: proses lain menemukan server lewat direktori Syphon dan membaca frame 1280×720 BGRA dari IOSurface (T-89) |

## Kontrol
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Shortcut keyboard yang bisa diatur | Implemented | M | |
| Kontrol MIDI dengan Learn (CUT, AUTO, T-bar, preview/cut 1–8, overlay 1–4, stream, rekam, snapshot) | Implemented (0.7.0) | L (parser MIDI 1.0/UMP, pemetaan, 6 unit test) + kompilasi CI | Semua sumber CoreMIDI tersambung otomatis; pemetaan disimpan di Mac (bukan proyek). Belum dites dengan controller (T-35) |
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
