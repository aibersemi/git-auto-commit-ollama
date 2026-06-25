# git-ai (Git Auto Commit Ollama)

`git-ai` adalah AI Commit Assistant berbasis bash script murni yang mengotomatisasi pembuatan pesan *commit* (commit message) menggunakan model LLM lokal via **Ollama**. Alat ini menganalisis perubahan kode Anda (git diff), mengumpulkan konteks (termasuk analisis mendalam per-file jika diperlukan), dan menghasilkan *commit subject* satu baris yang padat dan jelas.

## Fitur Utama

- **Otomatis & Cerdas**: Menganalisis *git diff* dan merangkumnya menjadi *commit message* standar tanpa campur tangan manual.
- **Keamanan Bawaan (Safe Mode)**: Secara otomatis mendeteksi dan memblokir pola sensitif (seperti kredensial, API key, private keys) agar tidak terkirim ke AI. Jika terdeteksi, skrip melewati file sensitif, tetap menganalisis file aman sampai batas `FILE_ANALYSIS_LIMIT`, dan hanya mengirim metadata Git beserta analisis file aman.
- **Analisis Per-file Berjalan Paralel**: Untuk *diff* yang besar, skrip ini memecah dan menganalisis file secara paralel sehingga konteks yang diberikan ke model jauh lebih akurat tanpa memakan waktu lama.
- **Structured Output**: Memanfaatkan fitur JSON Schema Ollama untuk memastikan bahwa keluaran model selalu mengikuti format yang konsisten dan siap digunakan.
- **Minim Ketergantungan**: Ditulis murni dalam bash. Anda hanya butuh `git`, `curl`, dan `jq`.

## Prasyarat

- `git`
- `curl`
- `jq`
- [Ollama](https://ollama.ai/) berjalan secara lokal atau dalam jaringan internal Anda.

## Instalasi

```bash
git clone https://github.com/MrMads/git-auto-commit-ollama.git
cd git-auto-commit-ollama
make install
```

> **Catatan**: `make install` secara otomatis akan membuat *symlink* secara global di `/usr/local/bin/git-ai`. Jadi, saat repositori ini diperbarui (via `git pull`), perubahan akan langsung terasa tanpa perlu instalasi ulang. Untuk menghapus, jalankan `make uninstall`.

## Penggunaan

Anda dapat memanggil `git-ai` dari dalam folder repositori git apa pun.

### Opsi Umum

```bash
# Stage semua file (git add -A), generate message, commit, lalu langsung push
git-ai

# Jalankan tanpa melakukan push
git-ai -n
# atau
git-ai --no-push

# Gunakan fitur staging patch interaktif (git add -p) sebelum commit
git-ai -p

# Tampilkan commit message dari AI dan minta konfirmasi (y/N) sebelum melakukan commit
git-ai -i
# atau
git-ai --interactive
```

### Opsi Lanjutan (CLI Arguments)

Alat ini mendukung banyak penyesuaian melalui *command-line arguments*:

- `-s, --status`: Hanya mengeksekusi `git status` dan memastikan ini adalah repo git (tidak commit).
- `--no-stage`: Jangan jalankan `git add` otomatis; hanya menganalisis apa yang sudah Anda `git add` sebelumnya.
- `--dry-run`: Lakukan seluruh proses analisis dan generasi pesan tanpa mengubah apapun (tidak commit). Hasil pesan hanya akan dicetak di layar.
- `--debug`: Tampilkan log *debugging* secara terperinci.
- `--force-diff`: Matikan fitur keamanan sementara; tetap kirim konten *diff* ke AI walaupun terdeteksi pola rahasia/sensitif.
- `--no-file-analysis`: Matikan fitur analisis per-file (jauh lebih cepat, tapi mungkin kurang mendetail untuk *commit* yang sangat masif).
- `--file-analysis-limit N`: Batasi maksimal `N` file aman yang akan dianalisis secara individu (default: 6). Saat Safe Mode aktif, file sensitif dilewati dan diganti dengan file aman lain jika tersedia.
- `--file-analysis-parallelism N`: Jumlah maksimal panggilan (API call) paralel saat menganalisis per-file (default: 4).
- `--no-structured`: Matikan fitur *JSON Structured Output* (fallback ke output teks biasa).
- `--no-pull`: Jangan lakukan `ollama pull` secara otomatis apabila model tidak ditemukan di *local*.
- `--no-banner`: Sembunyikan spanduk awal skrip.
- `--no-verify`: Lakukan `git commit` menggunakan `--no-verify` (melewati git hooks).

## Konfigurasi Lanjutan (`git-ai.conf`)

Selain argumen *CLI*, Anda dapat menyesuaikan konfigurasi baku secara permanen dengan memodifikasi file `git-ai.conf` yang berada tepat di samping skrip utama.

**Daftar Variabel yang Didukung:**
- `DEFAULT_MODEL`: Model yang akan digunakan (misalnya: `ministral-3:3b`, `llama3`).
- `DEFAULT_OLLAMA_HOST`: Host dari servis Ollama (misal: `http://localhost:11434`).
- `FALLBACK_OLLAMA_HOST`: Host cadangan jika host utama *down*.
- `OLLAMA_TEMPERATURE`: Angka kreativitas model (default: `0.2`).
- `OLLAMA_THINK`: Atur ke `true`, `low`, `medium`, atau `high` jika model Anda membutuhkan waktu "*berpikir*" khusus (misalnya `deepseek-r1`). Default: `false`.
- `OLLAMA_KEEP_ALIVE`: Kosong berarti mengikuti default service/server Ollama; isi hanya jika butuh override request (contoh: `5m`).
- `OLLAMA_NUM_CTX`: Kosong berarti mengikuti default service/server Ollama; isi hanya jika butuh override request (contoh: `4096`).
- `OLLAMA_NUM_PARALLEL`: Kosong berarti mengikuti default service/server Ollama; isi hanya jika butuh override request (contoh: `1`).
- `OLLAMA_MAX_NUM_PREDICT`: Batas maksimal token yang dihasilkan (maksimal `2048`).
- `FILE_ANALYSIS_NUM_PREDICT_PER_FILE`: Batasan jumlah token saat menganalisis satu buah file (default: `512`).
- `FILE_ANALYSIS_PARALLELISM`: Paralelisme eksekusi.
- `FILE_ANALYSIS_LIMIT`: Batasan jumlah file aman maksimal untuk fitur *file analysis*.

`git-ai.sh` tidak membuat, mengubah, atau melakukan reload unit systemd Ollama. Opsi request yang dibiarkan kosong akan memakai perilaku default dari service Ollama yang aktif, misalnya `/etc/systemd/system/ollama.service`.

## Panduan Pengembang & Keamanan

- **[CONTRIBUTING.md](CONTRIBUTING.md)**: Panduan untuk menyumbang kode ke repositori ini.
- **[SECURITY.md](SECURITY.md)**: Rincian lebih lanjut terkait fitur *Safe Mode* dan kebijakan laporan celah keamanan.

## Lisensi

Proyek ini menggunakan lisensi [MIT License](LICENSE). Anda bebas untuk menggunakan, mengubah, mendistribusikan, dan memanfaatkannya secara bebas dengan cukup menyertakan nama pembuat asli (Mr Mads).
