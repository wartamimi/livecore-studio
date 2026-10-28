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
44. **Virtual camera sendiri**: dihapus di 0.23.0 atas permintaan pemilik. macOS hanya menerima kamera virtual sebagai
    CoreMediaIO Camera Extension yang ditandatangani Apple Developer ID, jadi build unsigned tidak bisa memakainya.
    Gunakan EXTERNAL › Syphon → OBS "Syphon Client" → Start Virtual Camera di OBS.
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
    frame (hanya selama output itu dipakai: jendela/layar penuh terbuka atau Syphon nyala). Pengingat
    NOT RECORDING hanya di monitor Program, tidak di Multiview atau output. Syphon: sumber di OBS bernama
    "LiveCore Studio – Output N"; bila tidak ada aplikasi yang menerima, tidak ada yang disalin. Jendela output
    dibuka kembali kosong sampai frame berikutnya. Sejak 0.23.0 server Syphon menyalin frame setiap frame walau belum
    ada aplikasi penerima (seperti server Syphon lain), sedikit menambah kerja GPU selama EXTERNAL nyala.
    OBS 32.0.x punya bug Syphon Client (gambar kosong untuk server yang IOSurface-nya tanpa format piksel); server
    LiveCore memberi format 32BGRA, tetapi bila OBS tetap kosong, coba versi OBS lain.
56. **Dock bawah**: tidak bisa diperkecil (sesuai permintaan); di layar sempit tombol OUT 1–4 bisa terdorong ke kanan.
57. **Nomor overlay di kotak input**: overlay selalu layar penuh dengan fade (posisi diatur dari layer/scene inputnya).
    Satu kanal overlay hanya memegang satu input; menekan nomor yang sama di input lain memindahkan kanal itu.
58. **Output NDI (0.24.0)**: butuh runtime NDI 5/6 dari NDI Tools atau NDI Runtime (LiveCore tidak menyertakannya);
    bila dipasang setelah LiveCore dibuka, buka ulang LiveCore. App memakai entitlement
    `com.apple.security.cs.disable-library-validation` supaya bisa memuat pustaka NDI yang ditandatangani NDI.
    macOS meminta izin "Jaringan Lokal" saat NDI pertama kali dipakai; bila ditolak, sumber tidak terlihat
    (System Settings › Privacy & Security › Local Network). Timecode NDI disintesis saat kirim, jadi sinkron audio-video
    lewat NDI belum diukur. Frame rate sumber NDI mengikuti setelan saat output NDI dibuat (ubah frame rate → matikan dan
    nyalakan lagi NDI). Kompresi NDI memakai CPU; bila komputer berat, frame NDI dibuang (bukan memperlambat render).
    Nama kamera di Zoom tetap "NDI Virtual Camera"; kamera bernama "LiveCore" butuh Camera Extension bertanda tangan
    Developer ID.
59. **Layer Designer (0.25.0)**: crop dengan menarik tepi menjaga gambar tetap di tempat secara tepat untuk mode Stretch,
    atau Fit/Fill bila kotak layer seaspek gambar (mis. setelah "Sesuaikan dengan sumber"); di luar itu gambar bisa sedikit
    bergeser. Kotak di Layer Designer adalah garis bantu; gambar di bawahnya adalah hasil GPU yang sebenarnya. Pada input
    Scene, layer 0 (kanvas kosong) tidak bisa dipilih. Template tata letak disimpan di Mac ini, tidak ikut file proyek.
    Flatten Layers menambah satu render ukuran output per input yang di-flatten selama input itu tampil di mana pun.
60. **FULLSCREEN (0.25.0)**: tombol fullscreen Program lama diganti; FULLSCREEN memakai Output 1–4 (default Output 1 =
    Program di layar eksternal pertama). Bila hanya satu layar, fullscreen menutupi layar operator (Esc menutup).
    Transisi selalu mulai dari Dissolve setiap app dibuka (file proyek tetap membawa transisinya sendiri).
61. **Draft Layer Designer (0.26.0, diubah 0.27.0)**: hanya monitor Preview (dan output yang menampilkan Preview) yang
    menampilkan draft; overlay atau input lain yang memakai input yang sedang diedit tetap memakai versi lama sampai input itu
    dibawa ke Program dengan transisi. Tidak ada tombol batal: kembalikan posisi secara manual atau pakai template. File
    proyek menyimpan draft. Scene editor (lembar terpisah) tetap langsung berlaku seperti sebelumnya.
62. **Duplikat input (0.26.0)**: satu kamera/capture card = satu input. Capture jendela dicocokkan dari aplikasi + judul
    jendela; jendela dengan judul yang berubah (mis. judul dokumen) dianggap jendela lain. Proyek lama yang sudah berisi
    duplikat tetap dibuka apa adanya.
78. **Fullscreen halaman (0.36.1)**: ditiru dengan CSS, bukan fullscreen asli WebKit. Situs yang memeriksa fullscreen dengan
    cara lain, atau yang player-nya memakai `position: fixed` di dalam elemen ber-transform yang tidak bisa direset, bisa tampil
    tidak penuh; pakai opsi "Video saja" sebagai cadangan. Belum dites di Mac.
75. **Suara input Web (0.36.0)**: hanya macOS 14.2 ke atas, dan semua input web berbagi satu channel "Web audio"
    (WebKit memutar suara semua halaman di satu proses). Bisukan per input memakai opsi "Bisukan halaman". Bila izin
    Perekaman Audio Sistem ditolak, suara halaman tidak masuk mixer (pesan muncul sekali). Belum dites di Mac.
76. **PowerPoint mode Live (0.36.0)**: butuh Microsoft PowerPoint; Keynote dan LibreOffice tetap statis. Satu slideshow
    live sekaligus (perintah dikirim ke jendela slideshow pertama). Jendela slideshow harus tetap terbuka (boleh di
    belakang jendela lain, jangan di-minimize). Ganti slide lewat AppleScript, jadi ada jeda ±0,2 dtk. Perintah AppleScript
    PowerPoint belum dites di Mac.
77. **Animasi per huruf & Frame (0.36.0)**: animasi per huruf dirender ulang di CPU 30×/dtk selama animasi berjalan;
    animasi keluar tetap memakai animasi overlay. Frame: label nama tidak otomatis mengecil untuk nama yang sangat
    panjang (dipotong "…"); kamera mengisi jendela dengan crop.
72. **Animasi title & teks berjalan (0.35.0)**: animasi adalah satu gerakan untuk seluruh title (fade, geser, zoom) memakai
    kanal overlay; belum ada animasi per elemen/huruf atau animasi keluar yang berbeda dari animasi masuk. Animasi hanya
    diputar lewat nomor overlay (1-4), bukan saat title dipotong (CUT) sebagai input biasa.
73. **Mode edit input Web (0.35.0)**: login dan cookie hanya bertahan selama app terbuka (penyimpanan data tidak permanen).
    Selama mengedit, gambar Program ditahan (bawaan) atau mengikuti halaman langsung bila opsi itu dimatikan.
74. **Input PowerPoint (0.35.0)**: slide ditampilkan sebagai gambar statis dari PDF hasil ekspor; animasi, transisi slide,
    video dan audio di dalam presentasi tidak diputar. File .pptx/.key butuh Keynote, PowerPoint atau LibreOffice di Mac;
    tanpa itu, ekspor ke PDF dulu. PowerPoint (sandbox) bisa meminta "Grant access" untuk membuka file. Konversi pertama
    bisa memakan waktu beberapa detik sampai menit untuk dek besar; setelah file diedit pilih "Muat ulang".
71. **Title Designer (0.34.0)**: title template dirender sekali per perubahan (bukan per frame), jadi belum ada
    animasi per elemen; animasi masuk/keluar memakai animasi overlay (seluruh title bergerak bersama). Font yang tidak
    terpasang di Mac lain (proyek dibuka di Mac lain) diganti font sistem. Title template berukuran seluruh output: di
    Scene/Layer Designer letakkan full screen, bukan di kotak kecil, agar ukurannya benar. Mengedit title lama mengubahnya
    menjadi template (posisi bisa sedikit bergeser dari strip lama).
70. **MultiCorder & Recorder lanjutan (0.33.0)**: 0 frame terbuang dengan 4 ISO tidak bisa dijamin di semua Mac. Mac
    Apple silicon punya encoder hardware terbatas (M1/M2/M3 biasa satu media engine; Pro/Max dua; Ultra empat); bila
    penuh, macOS memakai encoder software dan frame bisa terbuang (terlihat sebagai "drop" di dock). Untuk 4 ISO 1080p
    disarankan HEVC 15–25 Mbps, atau ProRes 422 / LT di Mac dengan engine ProRes (M1 Pro/Max/Ultra, M2 ke atas) dan
    disk SSD cepat (4 × ProRes 422 1080p30 ±75 MB/s). B-frame sebaiknya mati saat banyak file. ProRes di Mac Intel atau
    M1 biasa di-encode software dan berat. CI hanya memeriksa bahwa file valid; angka drop di CI (Mac virtual tanpa media
    engine) bukan ukuran Mac sungguhan. Mengubah profil tidak bisa saat RECORD / ISOCORDER berjalan.
69. **MultiCorder (0.32.0)**: tiap file ISO memakai bus audio profil MultiCorder (sejak 0.33.0; bawaan Master), belum audio input itu sendiri.
    Tiap ISO menambah satu render ukuran penuh dan satu encoder H.264: di Mac Intel atau 4 ISO 1080p60 bisa membuat
    frame terbuang (lihat "drop" di RECORD ⚙); kurangi jumlah ISO atau bitrate. Sejak 0.33.0 MultiCorder punya tombol
    sendiri; pilihan input dikunci selama ISOCORDER berjalan. Ruang disk terpakai ±(1 + jumlah ISO)× rekaman biasa.
    Input yang tidak punya gambar (mis. kamera terputus) menghasilkan file ISO pendek/berhenti; rekaman Program tetap.
68. **Panel Web Controller (0.31.0)**: gambar Program/Preview adalah JPEG kecil ±3 fps (bukan video, tanpa audio) dan
    menambah sedikit beban CPU Mac selama halaman terbuka; meter audio di HP diperbarui ±4× per detik sehingga terlihat
    kasar dibanding meter di Mac. Getaran tombol tidak ada di iPhone (Safari tidak mendukung). Master tidak punya mute.
67. **Web Controller (0.30.0)**: koneksi HTTP biasa (tidak terenkripsi) — PIN dan perintah bisa dibaca orang lain di
    jaringan yang sama; pakai hanya di Wi-Fi/LAN yang dipercaya (bukan Wi-Fi publik/tamu). Hanya IPv4. Bila firewall
    macOS aktif, macOS bisa bertanya "izinkan koneksi masuk" untuk LiveCore Studio (app belum bertanda tangan Developer
    ID, jadi pertanyaan itu bisa muncul lagi setelah update). Status di HP diperbarui tiap 0,5 detik (bukan real-time);
    (0.31.0 menambah gambar Program/Preview dan mixer audio; playlist belum bisa dari remote.) Wi-Fi
    "client isolation" di sebagian router membuat HP tidak bisa menjangkau Mac.
66. **Input NDI (0.29.0)**: butuh runtime NDI (NDI Tools / NDI Runtime) di Mac; tanpanya menu memberi link unduh. Video
    disalin ke buffer BGRA (CPU) — untuk banyak sumber 4K beban CPU naik. Hanya video progresif; sumber interlaced
    diminta progresif dari NDI. Audio diambil 2 kanal pertama. Belum ada sinkron A/V otomatis antara video dan audio NDI.
65. **Capture card lanjutan (0.28.0)**: "format video perangkat" menentukan apa yang dikirim perangkat lewat USB; macOS
    tetap mengubah gambar ke BGRA 8-bit untuk compositor, jadi format 10-bit (v210/P010) tidak membuat program 10-bit.
    Deinterlace memakai metode blend sederhana (bukan motion-adaptive). Perangkat yang hanya dikenali lewat SDK vendor
    (DeckLink) tetap belum didukung.
63. **Shuffle / Repeat One video playlist (0.26.0–0.27.0)**: Shuffle dan Repeat One video belum tersimpan di file proyek
    (Repeat playlist tersimpan); untuk musik keduanya tersimpan. "Berhenti setelah item ini" tidak disimpan (sekali pakai).
64. **Canvas portrait/custom (0.26.0)**: thumbnail input dan tile input di Multiview tetap 16:9. Posisi layer, overlay dan
    judul memakai koordinat relatif, jadi tata letak yang dibuat untuk 16:9 akan tertarik bila canvas diganti ke 9:16;
    atur ulang di Layer Designer. Platform stream harus mendukung video vertikal (YouTube Shorts, Facebook, TikTok Live).
