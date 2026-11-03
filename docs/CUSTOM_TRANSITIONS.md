# Transisi custom (0.12.0)

Panel transisi › pilih salah satu transisi di bawah garis pemisah. Contoh bawaan langsung bisa dipakai;
"Baru…" membuat file dari template dan membukanya di editor, "Impor .metal…" menyalin file Anda ke folder
transisi, "Muat Ulang" mengompilasi ulang setelah file diedit, "Folder" membuka
`~/Library/Application Support/LiveCore Studio/Transitions`.

## Format file

Satu file `.metal` berisi satu fungsi (Metal Shading Language):

```metal
// name: Nama Yang Tampil
float4 transition(float2 uv, float progress, float ratio,
                  texture2d<float> from, texture2d<float> to, sampler s) {
    float d = (uv.x + uv.y) * 0.5;
    float edge = mix(-0.05, 1.05, progress);
    float m = 1.0 - smoothstep(edge - 0.05, edge, d);
    return mix(FROM(uv), TO(uv), m);
}
```

- `uv`: posisi 0..1, (0,0) = kiri atas.
- `progress`: 0 (seluruhnya gambar lama) sampai 1 (seluruhnya gambar baru). Di 0 dan 1 app menampilkan gambar
  lama/baru apa adanya, jadi transisi tidak bisa "nyangkut".
- `ratio`: lebar / tinggi output (mis. 1.777 untuk 16:9).
- `FROM(p)` / `TO(p)`: warna gambar lama / baru di posisi `p` (premultiplied BGRA).
- Fungsi bantu sendiri boleh ditambahkan di file yang sama.
- Tidak diizinkan: `#include`, `#import`, `#pragma`, fungsi `fragment`/`vertex`/`kernel`, buffer/tekstur tambahan.
  Batas ukuran 64 KB.

Bila kompilasi gagal, pesan error (dengan nomor baris file Anda) tampil di bawah daftar transisi dan
AUTO/T-bar memakai Dissolve sampai shader diperbaiki.
