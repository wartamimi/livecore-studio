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

## Failed
Tidak ada tes yang gagal pada putaran terakhir.

## Blocked by environment
| ID | Tes | Alasan |
|---|---|---|
| A-05 / T-01 | Build app macOS | Tidak ada macOS/Xcode/SDK di Linux |
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
