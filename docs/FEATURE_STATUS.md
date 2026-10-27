# Status Fitur

Definisi status:
- **Implemented** — kode lengkap untuk fungsi tersebut ada di repo. Kolom *Verifikasi* menyatakan apakah sudah dibuktikan.
- **Partially implemented** — sebagian fungsi ada; batasannya disebut.
- **Planned** — belum ada kode; dijadwalkan pada milestone yang disebut.
- **Blocked** — tidak dapat dikerjakan tanpa sesuatu di luar kendali (SDK, lisensi, perangkat).

Verifikasi: **L** = lulus tes otomatis di Linux (unit/E2E), **M** = perlu diuji di Mac (belum), **—** = n/a.

> Penting: **Milestone 1 belum boleh dinyatakan selesai.** Seluruh kode macOS sudah ditulis dan lolos *syntax parse*,
> tetapi belum dikompilasi terhadap macOS SDK dan belum dijalankan di perangkat. Lihat `TEST_RESULTS.md`.

## Video
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Penemuan kamera USB/UVC & built-in, hot-plug | Implemented | M | `DeviceManager` |
| Input kamera (pemilihan format sesuai output) | Implemented | M | `CameraSource` |
| Input file video (loop, play/pause/restart) | Partially implemented | M | Audio file **belum** masuk mixer (player di-mute) |
| Input gambar (PNG alpha, JPEG, HEIC…) | Implemented | M | |
| Input warna | Implemented | M | |
| Text / lower third (CoreText) | Implemented | M | Editor dasar: judul, subjudul, bar |
| Preview/Program terpisah | Implemented | L (logika) + M (render) | `Switcher`, `FramePlanner` teruji |
| CUT | Implemented | L + M | |
| AUTO: Dissolve, Fade (dip to black), Wipe | Implemented | L (state) + M (shader) | |
| T-bar manual | Implemented | L + M | |
| Overlay 4 kanal dengan fade | Implemented | L + M | |
| Picture-in-Picture (layer pada input / overlay preset PiP) | Implemented | L + M | Preset posisi; belum ada drag-resize |
| Scene composition dasar (layer per input) | Partially implemented | L + M | Tambah/hapus layer via menu; editor visual M2 |
| Scaling fit/fill/stretch & aspect ratio | Implemented | L + M | `LayoutMath` teruji |
| Resolusi/frame rate output (720p30/60, 1080p25/30/60) | Implemented | M | Terkunci saat output aktif |
| Thumbnail input live (≈5 fps) | Implemented | M | |
| Jendela Program untuk monitor eksternal | Implemented | M | Seret ke layar lain + full screen |
| Multiview | Planned (M2) | — | |
| Chroma key | Planned (M2) | — | Tidak ditampilkan di UI |
| Browser source | Planned (M2) | — | Butuh evaluasi keamanan WKWebView offscreen |
| Transisi lanjutan (stinger, slide, custom) | Planned (M3) | — | |

## Audio
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Pemilihan input (semua perangkat input macOS) | Implemented | M | |
| Kanal multi-input, fader, trim, pan | Implemented | L (DSP) + M | |
| Mute | Implemented | L + M | |
| Solo (ke bus monitor) | Implemented | M | |
| Routing ke Program on/off | Implemented | M | |
| Peak meter + peak hold | Implemented | L + M | |
| Compressor per kanal | Implemented | L + M | Feed-forward, stereo-linked |
| Limiter master | Implemented | L + M | Tanpa look-ahead (lihat known issues) |
| Noise gate | Planned (M2) | — | Tidak ditampilkan |
| Monitoring + pemilihan perangkat output | Implemented | M | |
| Sinkronisasi A/V (host clock + offset manual) | Implemented | L (anchor) + M | Butuh kalibrasi per kamera |
| Koreksi drift clock (resampling adaptif) | Planned (M2) | — | M1: jitter buffer |
| Audio dari file video / NDI | Planned (M2/M3) | — | |

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
| Multi-destination | Planned (M3) | — | |

## Recording
| Fitur | Status | Verifikasi | Catatan |
|---|---|---|---|
| Rekam Program (MP4/MOV, H.264+AAC) | Implemented | M | AVAssetWriter |
| Pilih folder, pola nama file, nama unik | Implemented | L (penamaan) + M | |
| Status, durasi, ukuran file, ruang kosong | Implemented | M | |
| Penanganan disk penuh / gagal tulis | Implemented | M | Berhenti & finalisasi |
| Finalisasi benar saat stop / quit | Implemented | M | Konfirmasi quit saat aktif |
| Rekam + stream bersamaan dari satu pipeline | Implemented | M | |
| MOV tahan crash (movie fragments 10 s) | Implemented | M | |

## Perangkat broadcast
| Fitur | Status | Catatan |
|---|---|---|
| Capture card HDMI/SDI yang tampil sebagai UVC/AVFoundation | Implemented (via jalur kamera) | Lihat `CAPTURE_DEVICES.md` |
| Blackmagic DeckLink (Desktop Video SDK) | Blocked → Planned M3 | Perlu SDK (EULA, registrasi) + perangkat uji |
| AJA / Magewell Pro | Planned M3 | Perlu SDK vendor |
| NDI | Blocked → Planned M3 | Perlu NDI SDK + kepatuhan lisensi |

## Sistem
| Fitur | Status | Verifikasi |
|---|---|---|
| CPU/RAM proses, waktu GPU per frame, FPS render, dropped, thermal | Implemented | M |
| Logging os.Logger per kategori, tanpa stream key | Implemented | L (redaksi) + M |
| Shortcut keyboard dapat diubah | Implemented | M |
| UI EN + ID | Implemented | M |
| Profil proyek / simpan-muat scene | Planned (M2) | — |
