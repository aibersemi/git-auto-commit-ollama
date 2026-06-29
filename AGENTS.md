# AGENTS.md - git-auto-commit-ollama

Anda adalah **Agent AI** untuk proyek/repositori **git-auto-commit-ollama**. Ikuti instruksi ini dengan ketat saat bekerja, memodifikasi, meninjau, atau memberi saran pada repositori ini.

## Default Language

- Gunakan Bahasa Indonesia sebagai bahasa utama dalam percakapan, penjelasan, komentar ringkas, ringkasan kerja, commit message, dan dokumentasi.
- Bahasa Inggris boleh digunakan untuk istilah teknis, nama API, nama library, command, error message, nama file, nama branch, judul dokumen, heading, atau konsep yang lebih jelas jika tetap ditulis dalam bahasa aslinya.

## Arsitektur Skrip

- Repositori ini berpusat pada skrip Bash murni `git-ai.sh`.
- Konfigurasi default dibaca dari `git-ai.conf` di folder yang sama dengan skrip.
- Jika mengubah logika output terminal seperti banner, spinner, progress bar, step, warna ANSI, atau ringkasan akhir, pastikan tetap aman saat TTY.

## Keamanan dan Safe Mode

- Jangan melepas, melemahkan, atau mempersempit perlindungan `sensitive_pattern_regex()` tanpa alasan keamanan yang kuat.
- Jika pola sensitif terdeteksi dan `--force-diff` tidak aktif, skrip harus tetap menghindari pengiriman detail diff ke AI.
- Analisis per-file juga harus melewati chunk diff yang mengandung pola sensitif kecuali `--force-diff` aktif.
- Jika memperbarui pola deteksi secret, pertahankan cakupan minimal untuk password, secret, API, token, private, token, key.
- Debug output tidak boleh membocorkan secret dari diff, payload, atau response yang berpotensi sensitif.

## Validasi Subject Commit

- Subject wajib Bahasa Indonesia, 1 baris, ringkas, spesifik, tanpa conventional commit prefix, tanpa body/footer, dan tidak berakhir dengan titik.
- Subject wajib lolos `validate_commit_subject()`: tidak kosong, minimal 8 karakter, tidak mengandung control character, tidak berakhir titik, dan tidak hanya whitespace.
- Jika subject dari AI gagal request, gagal parse, gagal validasi, atau gagal kualitas, lakukan retry maksimal 3 kali dengan backoff sebelum memakai fallback subject generator.
- Fallback subject harus tetap dibangun dari konteks Git yang aman, bukan dari asumsi bebas.

## Dry Run dan Locking

- Untuk test run dan memastikan aplikasi berjalan baik, gunakan `git-ai --dry-run`.
- `--dry-run` wajib memakai `GIT_INDEX_FILE` sementara yang disalin dari indeks asli jika ada, lalu dibersihkan setelah selesai.
- Dry-run boleh melakukan simulasi staging pada index sementara, tetapi tidak boleh mengubah index asli, membuat commit, atau push.
- Locking repo wajib memakai `.git/git-ai.lock` melalui `flock -n` agar hanya satu instance `git-ai.sh` berjalan pada repo yang sama.
- Lock harus dilepas dan file lock dibersihkan saat proses selesai atau keluar lewat trap.

## Instalasi

- Instalasi proyek menggunakan symlink ke `/usr/local/bin` melalui `make install`.
- Jika simulasi atau instalasi mengalami permission denied saat membuat direktori atau symlink, boleh memakai `sudo` sesuai pola instalasi.
- Jangan mengubah ownership file repositori menjadi root; ownership repositori tetap milik user yang bersangkutan.

## Backup

- Lokasi backup standar: `/data/backups/git-auto-commit-ollama/<jenis-backup>/<YYYYMMDD-HHMMSS>/`.
