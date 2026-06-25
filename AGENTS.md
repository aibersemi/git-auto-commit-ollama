# AGENTS.md - git-auto-commit-ollama

Anda adalah **Agent AI** untuk proyek/repositori **git-auto-commit-ollama**. Ikuti instruksi inti ini dengan ketat jika Anda diminta untuk bekerja, memodifikasi, atau memberikan saran pada repositori ini.

- Lakukan backup sebelum ada perubahan, simpan di `/data/backups/git-auto-commit-ollama/<YYYYMMDD-HHMMSS>/`.

## 1. Bahasa Komunikasi Utama
- Gunakan **Bahasa Indonesia** untuk seluruh percakapan, penjelasan, serta dokumen pendukung (`README.md`, `CONTRIBUTING.md`, dll).
- Gunakan **Bahasa Inggris** murni untuk penamaan variabel kode, fungsionalitas teknis, atau instruksi Git yang standar (misal: *commit, push, staging, patch*).

## 2. Arsitektur & Aturan Kode (Bash)
- Repositori ini merupakan **bash script murni** tanpa kerangka kerja (framework) pihak ketiga. Skrip diwajibkan berjalan secara efisien.
- **Dilarang keras** menambah dependensi eksternal di luar `git`, `curl`, dan `jq`.
- Patuhi standar keamanan shell: `set -euo pipefail` di awal skrip tidak boleh dihapus.
- Jika Anda memperbarui logika UI terminal (seperti animasi *spinner*, *progress bar*, atau penomoran *step* yang menggunakan pewarnaan ANSI), pastikan tidak merusak fungsi saat `NO_COLOR` aktif atau saat output dialihkan (non-TTY).

## 3. Logika Inti & Keamanan
- **Safe Mode**: Jangan pernah melepas, merusak, atau menurunkan fungsi regex yang menyaring rahasia (*secrets*, *API keys*, *passwords*) di dalam git diff. 
- **Pemrosesan Paralel**: Skrip ini menggunakan *job control* Bash bawaan (subshells `&`, `wait`) untuk melakukan analisis API ke Ollama secara paralel (per-file). Jika mengubah logika pemanggilan API, jangan sampai merusak paralelismenya atau menyebabkan _memory leak/zombie process_.
- **Structured Output**: Skrip mengandalkan fungsi `format` dari Ollama (seperti JSON schema) untuk mendapatkan respon spesifik. Jika Anda mengutak-atik struktur respon *prompt*, pastikan skemanya (jq JSON schema) selaras.

## 4. Konvensi Dokumentasi & Argumen CLI
- Jika Anda menambahkan opsi baru pada `parse_args()`:
  1. Wajib menambahkannya ke dalam fungsi `show_help()` di skrip.
  2. Wajib memperbarui penjelasan di bagian **Opsi Lanjutan (CLI Arguments)** di `README.md`.
- Jika menambahkan variabel konfigurasi baru di `git-ai.conf`, update juga deskripsi variabelnya di `README.md` dan di dalam `show_help()`.

## 5. Tata Cara Instalasi
- Skrip ini menggunakan pendekatan symlink ke `/usr/local/bin` lewat perintah `make install`.
- Apabila terjadi *permission denied* saat simulasi atau pembuatan direktori/symlink, Anda memiliki wewenang menggunakan eksekusi `sudo` sesuai pola instalasi. Hindari mengubah file aslinya menjadi direktori root; tetap simpan *ownership* repositori pada *user* yang bersangkutan.
