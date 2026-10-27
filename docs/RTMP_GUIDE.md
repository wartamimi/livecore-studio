# Panduan Konfigurasi RTMP / RTMPS

Buka **Settings › Stream**. Isi **Server URL** dan **Stream key**. Key disimpan di Keychain macOS
(Keychain Access › cari "LiveCore Studio stream key"), tidak pernah di file pengaturan atau log.

| Platform | Server URL | Catatan |
|---|---|---|
| YouTube Live | `rtmp://a.rtmp.youtube.com/live2` atau `rtmps://a.rtmps.youtube.com:443/live2` | Key dari YouTube Studio › Go Live › Stream |
| Facebook Live | `rtmps://live-api-s.facebook.com:443/rtmp/` | Wajib RTMPS |
| Twitch | `rtmp://live.twitch.tv/app` (atau ingest terdekat) | |
| Instagram Live (via Live Producer) | URL & key dari Live Producer (RTMPS) | Key berubah tiap sesi |
| nginx-rtmp / SRS / MediaMTX lokal | `rtmp://<ip>:1935/live` | Key = nama stream |
| Wowza / custom | `rtmp://host:port/app/instance` | App boleh berisi beberapa segmen & query `?token=` |

Jika key dimasukkan di URL (mis. `rtmp://host/live/kunci`) dan kolom key kosong, segmen terakhir dipakai sebagai key.

## Rekomendasi setelan
| Output | Video | Audio | Keyframe |
|---|---|---|---|
| 720p30 | 2500–4000 kbps | 128–160 kbps AAC | 2 s |
| 1080p30 | 4500–6000 kbps | 160 kbps | 2 s |
| 1080p60 | 6000–9000 kbps | 160–192 kbps | 2 s |

Profil High, encoder hardware. Upload internet minimal **1,5× bitrate total**. Untuk wedding/event di venue, gunakan kabel LAN.

## Status & statistik
LIVE (merah), Connecting/Reconnecting (kuning), Failed (pesan alasan). Panel Stream menampilkan bitrate aktual,
frame drop jaringan & encoder, antrean (ms), jumlah reconnect, encoder HW/SW. Antrean yang terus naik = upload kurang;
turunkan bitrate.

## Uji tanpa platform (server lokal)
```bash
brew install ffmpeg
ffmpeg -listen 1 -i rtmp://127.0.0.1:1935/live/test -c copy test.flv
# di app: URL rtmp://127.0.0.1:1935/live , key test → Start, lalu Stop
ffprobe test.flv
```
Atau server permanen: MediaMTX (`brew install mediamtx`) lalu tonton dengan `ffplay rtmp://127.0.0.1/live/test`.

## Pemecahan masalah
| Pesan | Penyebab |
|---|---|
| Unsupported URL scheme | URL bukan `rtmp://`/`rtmps://` |
| Server rejected connect | Nama app salah (mis. `live2`) atau server menolak |
| NetStream.Publish.BadName / Rejected | Key salah/kedaluwarsa atau stream dengan key sama masih aktif |
| Timed out waiting for the server | Firewall/port diblokir; coba RTMPS port 443 |
| Network: … | Koneksi gagal/putus; reconnect otomatis jika sebelumnya sudah LIVE |
