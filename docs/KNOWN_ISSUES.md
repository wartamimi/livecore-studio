# Known Issues & Batasan (Milestone 1)

1. **Belum dikompilasi di macOS.** Kode macOS lolos syntax parse, belum type-check. Kemungkinan ada error kompilasi kecil
   (nama API/overload) yang perlu diperbaiki pada build pertama. Laporkan output `scripts/build_macos.sh` dan akan diperbaiki.
2. **Audio file video tidak masuk mixer.** Player di-mute agar audio tidak melewati mixer. Perlu `MTAudioProcessingTap` (M2).
3. **Tidak ada koreksi drift clock audio.** Perangkat input dan output memiliki clock berbeda; jitter buffer membatasi latensi
   (buang kelebihan > 100 ms, isi senyap saat kosong). Pada sesi sangat panjang dapat terdengar klik sesekali. M2: resampler adaptif.
4. **Limiter tanpa look-ahead.** Transien sangat cepat di-clamp keras pada −1 dBFS (bisa sedikit distorsi), bukan dihaluskan.
5. **Offset A/V manual.** Latensi kamera berbeda per perangkat; kalibrasi dengan tes tepuk tangan (T-07).
6. **Encoder AAC priming** diasumsikan 2112 sampel (encoder Apple). Jika berbeda di versi macOS tertentu, gunakan offset A/V.
7. **BGRA end-to-end.** Capture dalam BGRA (konversi oleh hardware capture) — bandwidth lebih besar dari 4:2:0. Optimasi M2.
8. **Satu encode untuk stream, satu untuk rekaman** (AVAssetWriter) — beban encoder ganda (keduanya hardware di Apple Silicon).
   Disengaja agar bitrate rekaman independen. Pipeline capture/komposisi tetap satu.
9. **Resolusi/frame rate tidak dapat diubah saat stream/rekam aktif** (by design).
10. **MP4 hanya dapat diputar setelah stop yang bersih.** Gunakan MOV (movie fragments 10 s) untuk acara penting.
11. **Reconnect hanya setelah pernah LIVE.** Kegagalan pertama (URL/key salah, ditolak) dilaporkan tanpa retry.
12. **Timestamp RTMP mulai dari 0 lagi setelah reconnect**; beberapa platform menganggapnya sesi baru (perilaku umum encoder).
13. **Overlay/scene tidak disimpan** ke file proyek (M2: profil proyek).
14. **Keyboard shortcut tanpa modifier** (Space/Return/angka) aktif saat jendela utama fokus; saat mengetik di dialog,
    dialog yang menangkap input.
15. **Capture card non-UVC** (DeckLink, AJA, Magewell Pro) tidak didukung di M1.
16. **Tidak di-sandbox** (App Sandbox) agar folder rekaman bebas dipilih tanpa security-scoped bookmarks; hardened runtime aktif.
17. **GPU utilisation** tidak tersedia lewat API publik; yang ditampilkan adalah waktu GPU per frame.
