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
18. **Chroma key** bekerja per input dengan satu warna kunci; eyedropper ada sejak 0.20.0 (mengambil dari gambar sebelum koreksi warna input); belum ada garbage matte,
    atau light wrap. Hasil sangat bergantung pada pencahayaan green screen.
19. **Multiview** memakai thumbnail 10 fps 384×216 untuk tile input (Preview/Program tetap penuh). Tidak ada meter audio
    atau jam di Multiview dan bukan output SDI/HDMI terpisah (gunakan jendela di monitor kedua).
20. **File proyek** menyimpan path absolut + relatif. Kamera/perangkat audio dicocokkan via uniqueID macOS; perangkat yang
    tidak terpasang dilewati dengan peringatan. Overlay dimuat dalam keadaan OFF. Gaya teks (ukuran font) memakai default.
21. **Editor scene** menggambar layer dari thumbnail 10 fps dengan skala "fit"; hasil persis (fill/crop) terlihat di Preview.
    Belum ada crop per layer, rotasi, atau border/bayangan.
22. **Lower third**: animasi overlay (geser/zoom/fade) sejak 0.20.0 berlaku per kanal overlay, bukan per judul; belum ada
    wipe dan pilihan font.
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
31. **Input musik**: fade antarlagu sejak 0.20.0 berupa fade-out lalu fade-in (lagu tidak tumpang tindih, bukan crossfade
    DJ). Pindah lagu bisa memberi jeda singkat (~100 ms) saat file baru dibuka.
32. **Playlist video**: perpindahan antarklip butuh beberapa frame (klip baru dibuka saat klip lama selesai), tidak ada
    transisi otomatis antarklip. Seekbar hanya untuk klip yang sedang dimuat.
33. **Fullscreen output**: di layar eksternal jendela tidak mengambil fokus keyboard (agar shortcut di jendela utama tetap
    jalan), jadi Esc hanya menutup bila fullscreen ada di layar utama; untuk layar eksternal pakai tombol Fullscreen atau ⌘⇧F.
    Output mengikuti resolusi layar dengan skala aspect-fit (bilah hitam bila rasio berbeda); tidak ada pengaturan refresh rate.
34. **Bus audio per output**: bus A/B dikirim post-fader seperti di mixer; bila bus A/B kosong, rekaman/stream di bus itu
    akan senyap. Tiap bus berbeda pada stream menambah satu encode AAC (ringan).
35. **Playlist media campuran**: klip audio di dalam playlist video tampil hitam (belum ada gambar sampul/visualizer).
    Pilihan "Tambah Media" memisahkan audio vs video menurut jenis file; file .mp4 berisi audio saja dianggap video.
36. **AFV**: sejak 0.18.0 audio crossfade (linear) selama durasi transisi AUTO. Dengan T-bar audio pindah di tengah bar
    (ramp 50 ms), tidak mengikuti posisi bar secara bertahap. Stinger memakai durasi transisinya.
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
40. **Lottie**: dihapus di 0.15.0 atas permintaan pengguna (tetap tidak tampil di Mac pengguna pada 0.14.0, padahal
    uji render di CI lulus). Proyek lama berisi input Lottie tetap bisa dibuka; input itu dilewati dengan peringatan.
41. **Gaya layer**: sudut bulat / elips / border tidak diterapkan pada layer yang memakai chroma key (crop tetap).
    Kanvas editor scene menampilkan sudut & border secara perkiraan dan tidak menampilkan crop; monitor Preview
    menampilkan hasil sebenarnya. (Menu Tambah Bentuk dihapus di 0.14.0.)
42. **Overlay ke Preview**: overlay yang sedang tampil di Preview tidak ikut stinger kecuali stinger dijalankan lewat
    AUTO (ikut seperti transisi lain). Shortcut keyboard dan MIDI overlay tetap langsung ke Program.
43. **Kunci**: kunci stream/rekam hanya berlaku selama app terbuka (tidak disimpan). Kunci source tidak menghalangi
    perubahan lewat file proyek yang dibuka, dan tidak mencegah source berganti status (mis. kamera dicabut).
    Menutup app tetap mungkin walau stream terkunci (konfirmasi quit tetap muncul saat output aktif).
44. **Virtual camera (seperti OBS)**: kode ada sejak 0.22.0 — **Blocked**. macOS modern hanya menerima kamera virtual
    sebagai CoreMediaIO Camera Extension, yaitu system extension yang wajib ditandatangani dengan Team ID Apple
    Developer, memakai entitlement `com.apple.developer.system-extension.install` + provisioning profile, dan app harus di
    /Applications. Build CI ini ad-hoc (tanpa Team ID), jadi "Aktifkan kamera virtual" ditolak macOS (app menampilkan
    alasannya). Plug-in DAL lama sudah tidak dimuat macOS 14+. Mematikan SIP + `systemextensionsctl developer on`
    tidak disarankan. Butuh akun Apple Developer Program (berbayar); langkahnya di `docs/VIRTUAL_CAMERA.md`. Sementara:
    EXTERNAL ⚙ › Syphon pada satu output, di OBS tambahkan "Syphon Client", lalu Start Virtual Camera di OBS.
    Kamera virtual (setelah aktif) selalu 1920×1080 30 fps; output lain diskalakan, dan tanpa kiriman dari LiveCore
    gambarnya hitam.
45. **Penampil source**: satu jendela untuk satu input sekaligus (membuka input lain mengganti isinya). Dirender pada
    resolusi output setiap frame selama terbuka (menambah beban GPU sedikit).
46. **Transparansi**: tile input menampilkan bagian transparan sebagai papan catur; Preview/Program tetap di atas
    hitam. Video dengan alpha yang tidak diberi tag oleh decoder dianggap straight alpha (umumnya ProRes 4444 /
    HEVC alpha); file yang sebenarnya premultiplied tanpa tag akan tampak sedikit lebih gelap di tepi.
47. **Capture card**: pilihan format sebatas yang dilaporkan driver; deinterlace dan koreksi warna per input belum ada.
    Audio perangkat ditambahkan sebagai kanal mixer terpisah (bisa diatur di Properti Audio).
48. **Properti audio**: ~~perubahan delay melompat~~ — diperbaiki 0.18.0 (crossfade 20 ms). Selama crossfade terdengar
    campuran audio lama dan baru (bisa terdengar seperti gema singkat pada delay besar).
49. **Koreksi warna**: diterapkan pada piksel 8-bit sRGB (bukan linear), tanpa LUT / kurva / white balance. Chroma key
    dihitung setelah koreksi warna. Putar hanya kelipatan 90° (sejak 0.17.0), tanpa sudut bebas.
50. **Nada tes**: dibangkitkan oleh timer 5 ms; bila app sangat sibuk dalam waktu lama bisa terjadi putus (underrun
    tercatat di Properti Audio).
51. **Teks berjalan**: digambar di CPU 60 kali per detik (satu blit selebar output); di 1080p murah, tetapi teks sangat
    panjang dipecah per 4096 px sejak 0.18.0. Arah kanan → kiri atau kiri → kanan (0.19.0); belum ada gulir vertikal.
    File .txt dicek tiap ±2 s (bukan langsung). Feed RSS/Atom (0.19.0): hanya judul item (maks. 30), alamat http biasa
    diblokir macOS (App Transport Security) jadi pakai https; feed dengan encoding selain UTF-8 bisa tampil salah huruf;
    bila feed gagal, teks terakhir tetap berjalan dan dicoba lagi tiap 60 detik.
52. **Slideshow foto**: crossfade digambar di CPU (30 fps); foto didekode satu langkah di depan, jadi melompat jauh
    dengan Berikut/Sebelumnya bisa menampilkan hitam sesaat untuk foto sangat besar. Folder dicek tiap 5 s sejak 0.18.0
    (hanya bila dipilih lewat "Pilih folder", tidak termasuk subfolder). Ken Burns digambar di CPU setiap frame (30 fps);
    pada Mac lama dengan output 1080p bisa memakai CPU cukup besar.
53. **Tutup audio**: audio video/tangkapan layar tidak bisa dilepas sendiri; menutupnya menghapus input pemiliknya
    (untuk membisukan saja, pakai M atau tarik fader). Gembok kanal hanya mencegah penutupan, bukan perubahan fader.
54. **Dock playlist**: daftar diperbarui tiap 0,5 s; seret-urutkan nonaktif saat kolom cari terisi. Impor M3U hanya
    file lokal (URL stream http di M3U dilewati), dan file yang hilang dilewati dengan pesan.
55. **4 output / EXTERNAL**: output yang memakai satu input atau Preview menambah satu render penuh resolusi output per
    frame (hanya selama output itu dipakai: jendela/layar penuh terbuka, Syphon nyala, atau kamera virtual). Pengingat
    NOT RECORDING hanya di monitor Program, tidak di Multiview atau output. Syphon: sumber di OBS bernama
    "LiveCore Studio – Output N"; bila tidak ada aplikasi yang menerima, tidak ada yang disalin. Jendela output
    dibuka kembali kosong sampai frame berikutnya. Kamera virtual: lihat 44.
56. **Dock bawah**: tidak bisa diperkecil (sesuai permintaan); di layar sempit tombol OUT 1–4 bisa terdorong ke kanan.
