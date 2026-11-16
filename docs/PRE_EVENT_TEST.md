# Tes Pra-Acara (±15 menit)

Jalankan di Mac dan jaringan yang dipakai saat acara, setelah semua kamera dan mikrofon tersambung.
Satu langkah gagal = jangan siaran sebelum diperbaiki. Tes lengkap per fitur ada di [TEST_PLAN.md](TEST_PLAN.md).

| # | Langkah | Lulus bila |
|---|---|---|
| 1 | Buka proyek acara (atau template). Tunggu 1 menit. | FPS di bar atas ≈ setelan, angka Drop 0, CPU tidak merah. |
| 2 | Klik tiap input ke Preview, lalu CUT dan AUTO beberapa kali. | Gambar semua input bergerak, tidak ada input berstatus kuning/merah. |
| 3 | Bicara ke tiap mikrofon, putar musik/video bersuara. | Meter tiap kanal dan master bergerak; master di bawah 0 dB (tidak merah terus). |
| 4 | Tekan STREAM. Panel Siap Siaran berjalan sendiri. | Hasilnya "Ready" (atau peringatan yang Anda pahami). Klik Go Live. |
| 5 | Biarkan live 2 menit ke tujuan tes (unlisted/private), cek di HP. | Gambar dan suara sampai, tidak patah; bitrate di bar atas stabil. |
| 6 | Cabut kabel LAN / matikan Wi-Fi 10 detik, sambungkan lagi. | Status "Reconnecting", lalu LIVE lagi sendiri. |
| 7 | Tekan RECORD 1 menit, lalu stop. | Bar atas menunjukkan sisa waktu rekam; file terbuka di QuickTime dengan suara. |
| 8 | Stop stream. Matikan sleep layar atau biarkan app yang menjaga layar tetap menyala. | Tidak ada pesan error tersisa di atas layar. |
