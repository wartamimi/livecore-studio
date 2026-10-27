# Known Issues & Batasan (Milestone 1 & 2)

1. **Fitur M2 belum diuji di perangkat** (T-17..T-22). Kompilasi & unit test lulus di CI; perilaku nyata menunggu laporan.
2. **Audio file video (M2):** latensi ±85–300 ms jitter buffer (AVPlayer menyerahkan audio dalam blok besar); sinkronisasi
   bibir terhadap video file belum diukur. Resampler linear (bukan kualitas mastering). Jika file tidak punya trek audio,
   kanal tidak dibuat. Format sampel non-float diabaikan (senyap) dan dicatat di log.
3. **Koreksi drift clock (0.3.0)** memakai interpolasi linear dengan rasio adaptif (maks ±0,5 %). Teruji dalam simulasi,
   belum diukur di perangkat untuk sesi > 1 jam (T-25). Batas keras (buang kelebihan) tetap ada sebagai jaring pengaman.
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
13. ~~Overlay/scene tidak disimpan~~ — M2: disimpan di file proyek `.livecore`.
14. **Keyboard shortcut tanpa modifier** (Space/Return/angka) aktif saat jendela utama fokus; saat mengetik di dialog,
    dialog yang menangkap input.
15. **Capture card non-UVC** (DeckLink, AJA, Magewell Pro) tidak didukung di M1.
16. **Tidak di-sandbox** (App Sandbox) agar folder rekaman bebas dipilih tanpa security-scoped bookmarks; hardened runtime aktif.
17. **GPU utilisation** tidak tersedia lewat API publik; yang ditampilkan adalah waktu GPU per frame.
18. **Chroma key** bekerja per input dengan satu warna kunci; belum ada pemilih warna dari gambar (eyedropper), garbage matte,
    atau light wrap. Hasil sangat bergantung pada pencahayaan green screen.
19. **Multiview** memakai thumbnail 10 fps 384×216 untuk tile input (Preview/Program tetap penuh). Tidak ada meter audio
    atau jam di Multiview dan bukan output SDI/HDMI terpisah (gunakan jendela di monitor kedua).
20. **File proyek** menyimpan path absolut + relatif. Kamera/perangkat audio dicocokkan via uniqueID macOS; perangkat yang
    tidak terpasang dilewati dengan peringatan. Overlay dimuat dalam keadaan OFF. Gaya teks (ukuran font) memakai default.
21. **Editor scene** menggambar layer dari thumbnail 10 fps dengan skala "fit"; hasil persis (fill/crop) terlihat di Preview.
    Belum ada crop per layer, rotasi, atau border/bayangan.
22. **Lower third** belum punya animasi slide/wipe sendiri (masuk/keluar memakai fade overlay) dan belum ada pilihan font.
23. **Capture card UVC generik** kadang melaporkan rentang frame rate yang tidak benar-benar diterima driver. Sejak 0.3.1
    app tidak crash lagi; bila driver menolak, kartu berjalan pada frame rate bawaannya (mis. 60 fps) dan render loop
    mengambil frame terbaru. Detailnya tercatat di log (Console.app, subsystem `studio.livecore.LiveCoreStudio`, kategori `devices`).
24. **Multi-destination** memakai satu encode, jadi semua tujuan menerima resolusi/bitrate yang sama (tidak ada encode
    terpisah per platform). Upload yang dibutuhkan = jumlah tujuan × (bitrate video + audio). Jika upload kurang, semua tujuan
    ikut terpengaruh karena encoder dibagi. Maksimal 3 tujuan. Setelan stream dikunci selama siaran.
25. **Transisi Push/Slide/Iris** belum punya pengaturan arah/lebar tepi sendiri; tepi wipe/iris memakai kelembutan tetap.
26. **Stinger** memakai pemutar file video biasa: mulai klip bisa terlambat beberapa frame setelah AUTO (waktu seek), dan
    titik potong mengikuti jam transisi, bukan frame klip. T-bar tidak bisa menggeser klip, jadi T-bar memakai dissolve.
    Klip tanpa alpha (mis. H.264 biasa) menutupi seluruh layar selama transisi. Klip stinger tidak berulang (loop dimatikan).
27. **Aux bus** hanya 2 (A dan B) dan selalu post-fader. Bus tidak ikut ke stream/rekaman (itu tetap Master). Bila perangkat
    output aux dicabut, bus berhenti diputar; pilih ulang perangkatnya. Latensi output aux ≈ 45–60 ms (buffer koreksi drift).
28. **Browser source** mengambil gambar halaman dengan `takeSnapshot` (bukan capture GPU langsung): maksimal 30 fps,
    memakai CPU, dan animasi halaman bisa tersendat. Jendela web ada di luar layar; jika macOS memperlambat halaman yang
    tidak terlihat, animasi bisa melambat (perlu dicek di T-32). Audio halaman diputar ke output sistem, tidak lewat mixer.
    Tidak ada interaksi mouse/keyboard ke halaman. Untuk alamat http (bukan https), app mengizinkan konten web tanpa TLS
    (`NSAllowsArbitraryLoadsInWebContent`).
29. **Timer** memakai jam sistem; hitung mundur tidak tersimpan berjalan di file proyek (dimuat dalam keadaan reset).
30. **MIDI**: hanya note dan control change (MIDI 1.0) yang dipakai; tidak ada feedback lampu ke controller, tidak ada
    pemetaan per perangkat (pesan yang sama dari dua controller dianggap sama). Fader T-bar mengikuti nilai CC langsung.
31. **Input musik** tidak punya crossfade antarlagu (posisi lagu tampil sebagai seekbar sejak 0.8.0); pindah lagu bisa memberi jeda
    singkat (~100 ms) saat file baru dibuka.
32. **Playlist video**: perpindahan antarklip butuh beberapa frame (klip baru dibuka saat klip lama selesai), tidak ada
    transisi otomatis antarklip. Seekbar hanya untuk klip yang sedang dimuat.
33. **Fullscreen output**: di layar eksternal jendela tidak mengambil fokus keyboard (agar shortcut di jendela utama tetap
    jalan), jadi Esc hanya menutup bila fullscreen ada di layar utama; untuk layar eksternal pakai tombol Fullscreen atau ⌘⇧F.
    Output mengikuti resolusi layar dengan skala aspect-fit (bilah hitam bila rasio berbeda); tidak ada pengaturan refresh rate.
34. **Bus audio per output**: bus A/B dikirim post-fader seperti di mixer; bila bus A/B kosong, rekaman/stream di bus itu
    akan senyap. Tiap bus berbeda pada stream menambah satu encode AAC (ringan).
35. **Playlist media campuran**: klip audio di dalam playlist video tampil hitam (belum ada gambar sampul/visualizer).
    Pilihan "Tambah Media" memisahkan audio vs video menurut jenis file; file .mp4 berisi audio saja dianggap video.
36. **AFV** membuka/menutup audio dengan ramp pendek (bukan crossfade mengikuti durasi transisi); selama transisi kedua
    sisi terdengar penuh.
37. **Tangkap jendela**: jendela yang diminimalkan atau di Space lain bisa berhenti mengirim frame (perilaku macOS);
    bila Zoom membuka jendela baru (mis. pindah ke breakout room) pilih ulang lewat "Ganti Jendela". Audio tangkapan
    tidak dikoreksi drift clock (selisih kecil dalam sesi sangat panjang bisa memberi klik). Tidak ada input per peserta
    (butuh Zoom SDK).
38. **Instant replay**: video saja (tanpa audio); buffer 30 detik tetap; satu klip replay sekaligus; mengganti resolusi
    output menghapus buffer. Buffer memakai satu encode H.264 tambahan (hardware) dan ~40 MB disk sementara pada 1080p30.
39. **Transisi custom**: shader berjalan di GPU tanpa batas waktu; shader yang sangat berat bisa menurunkan FPS Program
    selama transisi. Kompilasi terjadi di thread utama saat shader dipilih (sekitar sepersekian detik). Bila file
    transisi yang dipakai proyek tidak ada di Mac lain, transisi jatuh ke Dissolve dan muncul peringatan. Belum ada
    pratinjau transisi di luar Program, dan tidak ada parameter yang bisa diatur dari UI.
40. **Lottie**: dirender oleh mesin main-thread Lottie di CPU, maks. 30 fps dan sisi terpanjang 1920 px; animasi sangat
    kompleks bisa membebani thread UI. Ekspresi After Effects dan sebagian efek tidak didukung Lottie. Belum ada
    seekbar. Bila animasi tampil terbalik (belum bisa diverifikasi tanpa Mac), laporkan; perbaikannya satu baris.
41. **Gaya layer**: sudut bulat / elips / border tidak diterapkan pada layer yang memakai chroma key (crop tetap).
    Kanvas editor scene menampilkan sudut & border secara perkiraan dan tidak menampilkan crop; monitor Preview
    menampilkan hasil sebenarnya. Bentuk dibuat sebagai input warna terpisah.
42. **Overlay ke Preview**: overlay yang sedang tampil di Preview tidak ikut stinger kecuali stinger dijalankan lewat
    AUTO (ikut seperti transisi lain). Shortcut keyboard dan MIDI overlay tetap langsung ke Program.
