# Stream Deck / Bitfocus Companion

LiveCore Studio bisa dikendalikan dari Elgato Stream Deck lewat **Bitfocus Companion** (gratis), memakai API HTTP yang
sama dengan Web Controller. Tidak perlu plugin khusus: Companion memakai modul **Generic HTTP**.

## 1. Siapkan LiveCore Studio
1. Pengaturan › Web Controller › nyalakan. Catat **alamat** (mis. `http://192.168.1.20:8088`) dan **PIN** (6 angka).
2. Mac dan komputer Companion harus di jaringan yang sama (atau Companion berjalan di Mac yang sama: pakai
   `http://127.0.0.1:8088`).
3. Koneksi ini HTTP biasa (tidak terenkripsi). Pakai hanya di LAN/Wi-Fi yang dipercaya, jangan di Wi-Fi publik. PIN bisa
   diganti kapan saja (Pengaturan › Web Controller › PIN baru); semua perangkat harus memakai PIN baru.

## 2. Tambahkan koneksi di Companion
1. Companion › Connections › tambah **Generic: HTTP Requests**.
2. Base URL: `http://192.168.1.20:8088` (alamat Mac Anda).
3. Untuk tiap tombol: action **POST**, URL misalnya `/api/cut?pin=123456`.
   Bila versi Companion Anda bisa menambah header, lebih rapi memakai header `X-LiveCore-PIN: 123456` dan URL tanpa `?pin=`.

PIN yang salah 5 kali berturut-turut mengunci alamat IP itu sebentar (perlindungan tebak PIN).

## 3. Perintah (semua POST)
| Tombol | URL |
|---|---|
| CUT | `/api/cut` |
| AUTO | `/api/auto` |
| Input n ke Preview | `/api/preview?input=n` |
| Input n langsung ke Program | `/api/program?input=n` |
| Overlay 1–4 on/off | `/api/overlay?n=1` |
| Mulai / stop stream | `/api/stream/start`, `/api/stream/stop` |
| Mulai / stop rekam | `/api/record/start`, `/api/record/stop` |
| Foto (snapshot) | `/api/snapshot` |
| Replay n detik | `/api/replay?sec=10` |
| T-bar (0–1) | `/api/tbar?value=0.5` |
| Fader master (0–1) | `/api/audio/master?fader=0.75` |
| Mute channel | `/api/audio/mute?id=<id channel>&on=1` (id dari `GET /api/state`) |
| Kamera PTZ: panggil preset 1–8 | `/api/ptz/preset?input=n&preset=1` (0.37.0) |
| Kamera PTZ: home | `/api/ptz/home?input=n` (0.37.0) |
| Title data: baris berikut / sebelumnya | `/api/data/next?input=n`, `/api/data/previous?input=n` (0.37.0) |
| Title data: pilih baris | `/api/data/row?input=n&row=3` (baris pertama = 1) (0.37.0) |

`n` = nomor input seperti di panel Input (1, 2, 3…). Status lengkap (Program, Preview, stream, rekam, overlay,
audio) bisa dibaca dengan `GET /api/state?pin=…` untuk umpan balik tombol (modul Generic HTTP mendukung polling JSON).

## 4. Contoh profil Stream Deck 15 tombol
| | | | | |
|---|---|---|---|---|
| CAM 1 (`preview?input=1`) | CAM 2 | CAM 3 | TITLE (`overlay?n=1`) | CUT |
| PTZ 1 preset 1 | PTZ 1 preset 2 | PTZ 1 home | Nama berikut (`data/next?input=5`) | AUTO |
| REC start | REC stop | STREAM start | STREAM stop | FOTO |

## Batasan
- Belum ada umpan balik "push" (Companion harus polling `/api/state`).
- Belum ada modul Companion khusus LiveCore; Generic HTTP sudah cukup untuk semua perintah di atas.
- Diuji: format URL dan PIN (unit test). Belum diuji dengan Stream Deck fisik (T-178).
