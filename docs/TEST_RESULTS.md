# Hasil Pengujian Aktual

Tanggal: 2026-10-27. Lingkungan: container Linux (Ubuntu 24.04, x86_64), Swift 6.0.3, ffmpeg 6.1.1.
**Tidak ada Mac, Xcode, kamera, mikrofon, GPU Metal, atau akun platform streaming di lingkungan ini.**
Hasil di bawah tidak dipalsukan; log mentah: `docs/unit_tests_linux.log`, `docs/rtmp_e2e_linux.log`.

## Passed (dijalankan di lingkungan ini)
| ID | Tes | Bukti |
|---|---|---|
| A-01 | 47/47 unit test LiveCoreCore lulus (0 failure) | `unit_tests_linux.log` |
| A-02 | RTMP E2E: client LiveCore → server RTMP ffmpeg, 10 s real-time. Handshake → connect → createStream → publish → `NetStream.Publish.Start`; 772 paket, 3,29 MB terkirim. ffprobe hasil: **h264 High 1280×720 + aac LC 48 kHz stereo, durasi 10,03 s, 300/300 frame video & 470 frame audio ter-decode, 0 error decode** | `rtmp_e2e_linux.log` |
| A-03 | FLV writer: 300 frame video, 470 frame audio, 0 error decode | `rtmp_e2e_linux.log` |
| A-04 | Kegagalan koneksi: "cannot connect … (errno 111)" saat server tidak ada; "connection closed by server" saat server memutus di detik ke-2; stream key tidak muncul di log | `rtmp_e2e_linux.log` |
| — | Syntax parse seluruh 34 file Swift khusus macOS (4.394 baris) dengan `swiftc -parse` | 0 error (bukan type-check) |

Selama pengujian ditemukan dan diperbaiki 2 bug nyata: (1) kebijakan antrean kongesti mempertahankan keyframe lama sehingga
antrean tidak pernah turun di bawah batas; (2) tes ring buffer memiliki logika wrap yang salah. Keduanya kini teruji.

## Passed di Mac sungguhan (GitHub Actions, runner macos-15, Xcode 16)
Run: https://github.com/wartamimi/livecore-studio/actions/runs/40437817495 (commit f1b73a7, 2026-10-27).
| ID | Tes | Hasil |
|---|---|---|
| M-01 | `swift build --build-tests` seluruh target (termasuk LiveCoreEngine/LiveCoreUI khusus macOS) | Lulus, 0 error |
| M-02 | `swift test` di macOS | 47/47 lulus |
| M-03 | RTMP E2E (`scripts/rtmp_e2e_test.sh`) di macOS dengan ffmpeg | Lulus |
| A-05 / T-01 | Build app Release via XcodeGen + xcodebuild | Lulus, `LiveCoreStudio.app` terbentuk |
| M-04 | Pembuatan DMG (`scripts/make_dmg.sh`) | Lulus, `LiveCoreStudio-0.1.0-unsigned.dmg` ±2,1 MB |

Catatan: runner CI tidak punya kamera, mikrofon, atau layar interaktif, jadi T-02..T-16 tetap harus dijalankan manual di Mac.
Putaran CI sebelumnya menemukan dan memperbaiki: initializer `DrawCommand`/`Stats` yang tidak `public`, dan format project
XcodeGen yang butuh Xcode 16 (Xcode 15.4 gagal membaca project).

## Passed di Mac pengguna (laporan manual, build-5 / 0.1.0, 2026-10-27)
Dilaporkan oleh pengguna di MacBook miliknya (model/chip belum dicatat). Bukti: laporan tertulis pengguna, belum ada log/screenshot.
| ID | Tes | Hasil |
|---|---|---|
| T-02 | App dapat dibuka | Passed |
| T-03 | Input kamera tampil | Passed ("muncul") |
| T-05 / T-06 | CUT dan AUTO mengubah Program | Passed |
| T-07 (sebagian) | Meter audio mikrofon bergerak | Passed; sinkronisasi A/V belum diukur |
| T-09 | Rekaman dapat diputar | Passed |
| T-08 | Streaming ke platform | Passed |

Belum dilaporkan: T-10 (stream+rekam 10 menit), T-11 reconnect, T-12 cabut-colok, T-13 beban, T-14 disk penuh, T-15 izin ditolak, T-16 bahasa.

## Laporan pengguna build 0.2.0 (dev-build-8), 2026-10-27
Pengguna melaporkan "sejauh ini belum ada bug" setelah mencoba 0.2.0. Rincian per tes T-17..T-22 belum dilaporkan, jadi
statusnya tetap Not tested per item.

## Build 0.3.0 — otomatis
| ID | Tes | Hasil |
|---|---|---|
| A-01 | 73/73 unit test di Linux (Swift 6.0.3) | Passed |
| M-01..M-04, A-06 | Kompilasi macOS, 73/73 test, shader, app, DMG (`dev-build-9`) | Passed — https://github.com/wartamimi/livecore-studio/actions/runs/40447703986 (commit 9175d5b), lulus pada percobaan pertama |

## Milestone 2 (0.2.0) — otomatis
| ID | Tes | Hasil |
|---|---|---|
| A-01 | 61/61 unit test di Linux (Swift 6.0.3), termasuk 14 tes baru M2 | Passed |

Putaran CI pertama M2 menemukan 1 error kompilasi (tipe out-parameter `MTAudioProcessingTapCreate` adalah `Unmanaged` di SDK macOS) — diperbaiki di 7c69d6a.
| M-01..M-03 | `swift build`, 61/61 `swift test`, RTMP E2E di macos-15 / Xcode 16.4 | Passed — run https://github.com/wartamimi/livecore-studio/actions/runs/40443040329 (commit 7c69d6a) |
| A-06 | Kompilasi shader Metal offline (`scripts/check_shaders.sh`) termasuk `key_fragment` | Passed (run yang sama) |
| A-05 / M-04 | Build app 0.2.0 + DMG, dipublikasikan sebagai pre-release `dev-build-8` | Passed |
| T-17..T-22 | Tes manual M2 | Not tested (butuh Mac + perangkat) |

## Failed
Tidak ada tes yang gagal pada putaran terakhir.

## Blocked by environment
| ID | Tes | Alasan |
|---|---|---|
| T-02 | App dapat dibuka | Butuh macOS |
| T-03 | Input video ditambahkan | Butuh macOS + kamera |
| T-04 | Preview menampilkan sumber | Butuh macOS + Metal (logika Preview/Program sudah lulus unit test) |
| T-05 | CUT mengubah Program | Render butuh macOS (state machine lulus unit test) |
| T-06 | AUTO transisi | Shader butuh Metal (progres & penyelesaian transisi lulus unit test) |
| T-07 | Meter audio & sinkronisasi | Butuh Core Audio + perangkat (DSP & meter lulus unit test) |
| T-08 | Streaming start/stop dari app | Butuh VideoToolbox/Network.framework (protokol lulus E2E) |
| T-09 | Rekaman valid | Butuh AVAssetWriter |
| T-10 | Stream + rekam bersamaan | Butuh macOS |
| T-11 | Reconnect di app | Butuh macOS (jadwal backoff lulus unit test; deteksi putus lulus E2E di CLI) |
| T-12 | Cabut-colok perangkat | Butuh perangkat |
| T-13 | CPU/GPU/RAM/dropped frames | Butuh perangkat |
| T-14..T-16 | Disk penuh, izin, bahasa | Butuh macOS |

## Not tested
| Item | Alasan |
|---|---|
| RTMPS ke platform publik, YouTube/Facebook/Twitch | Tidak ada akses jaringan ke platform & tidak ada stream key; uji manual T-08 |
| Performa Intel vs Apple Silicon | Tidak ada perangkat |

## Template pencatatan pengukuran (T-13)
```
Mac: MacBook Pro 14" M1 Pro / macOS 14.6       Output: 1080p30, stream 6000 kbps + rekam 12000 kbps
Input: 2× kamera USB 1080p30, 1 mic USB          Durasi: 30 menit
CPU (top bar, % mesin): __   RAM: __ MB   GPU: __ ms/frame   FPS: __   Dropped render: __
Stream dropped (net/enc): __ / __   Encoder: HW/SW   Thermal: nominal/fair/serious
```
