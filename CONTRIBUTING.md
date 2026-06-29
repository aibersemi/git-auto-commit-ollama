# Contributing

Terima kasih sudah ingin berkontribusi ke `git-auto-commit-ollama`. Panduan ini dibuat supaya perubahan tetap kecil, mudah ditinjau, dan aman untuk tool yang bekerja langsung pada Git state pengguna.

## Daftar Isi

- [Jenis Kontribusi](#jenis-kontribusi)
- [Sebelum Mulai](#sebelum-mulai)
- [Setup Lokal](#setup-lokal)
- [Standar Kode](#standar-kode)
- [Pengujian](#pengujian)
- [Panduan Issue](#panduan-issue)
- [Panduan Pull Request](#panduan-pull-request)
- [Keamanan](#keamanan)
- [Dokumentasi](#dokumentasi)
- [Checklist](#checklist)

## Jenis Kontribusi

Kontribusi yang paling membantu untuk project ini:

- Bug fix pada workflow staging, commit, push, lock, atau integrasi Ollama.
- Perbaikan secret detection, safe mode, dan perilaku saat menangani data sensitif.
- Peningkatan kualitas prompt, structured output, fallback commit subject, atau validasi subject.
- Perbaikan performa untuk analisis per-file dan pengumpulan konteks diff.
- Dokumentasi penggunaan, troubleshooting, konfigurasi, dan contoh deployment.
- Validasi lint, CI, atau test scenario untuk Bash CLI.

Untuk perubahan besar, diskusikan dulu lewat issue sebelum membuat pull request. Contohnya: mengubah default model, menambah dependensi wajib, mengganti format commit message, atau mengubah perilaku default push.

## Sebelum Mulai

- Baca [`README.md`](README.md) untuk memahami cara kerja dan opsi CLI.
- Cek issue atau pull request yang sudah ada agar pekerjaan tidak duplikat.
- Buat perubahan yang fokus pada satu masalah.
- Jangan commit credential, token, private key, isi `.env`, log internal, atau diff dari repository privat.
- Pastikan perubahan tetap cocok untuk penggunaan lokal dan jaringan internal.

## Setup Lokal

Clone repository:

```bash
git clone git@github.com:aibersemi/git-auto-commit-ollama.git
cd git-auto-commit-ollama
```

Install dependensi validasi:

```bash
sudo apt-get update
sudo apt-get install -y git curl jq util-linux shellcheck
```

Validasi awal:

```bash
bash -n git-ai.sh
shellcheck git-ai.sh
./git-ai.sh --help
```

Opsional, siapkan Ollama untuk smoke test runtime:

```bash
ollama serve
ollama pull gemma4:e4b
```

## Standar Kode

Project ini adalah Bash CLI. Ikuti gaya yang sudah ada di `git-ai.sh`.

- Pertahankan `#!/usr/bin/env bash` dan `set -euo pipefail`.
- Pastikan `shellcheck git-ai.sh` bersih.
- Quote variable expansion kecuali ada alasan Bash yang jelas.
- Gunakan fungsi kecil dengan nama yang menjelaskan perilaku.
- Jaga output pengguna tetap berbahasa Indonesia.
- Jangan menambah dependensi wajib tanpa memperbarui `check_deps`, README, dan panduan ini.
- Jika menambah opsi CLI, update `parse_args`, `show_help`, README, dan contoh penggunaan yang relevan.
- Jika mengubah konfigurasi, update `git-ai.conf`, validasi config, README, dan default fallback.
- Hindari perubahan destruktif terhadap Git state pengguna. Untuk perilaku berisiko, sediakan dry-run, konfirmasi, atau guard yang jelas.
- Jaga secret handling tetap konservatif. Jangan melemahkan safe mode atau secret guard tanpa alasan teknis yang kuat.

## Pengujian

Minimal jalankan sebelum membuat pull request:

```bash
bash -n git-ai.sh
shellcheck git-ai.sh
./git-ai.sh --help >/tmp/git-ai-help.txt
```

Untuk perubahan runtime yang menyentuh staging, prompt, commit, atau push, lakukan smoke test di repository sementara. Jangan memakai repository kerja utama untuk eksperimen yang bisa membuat commit.

```bash
tmpdir=$(mktemp -d)
git init "$tmpdir"
cd "$tmpdir"
git config user.name "git-ai test"
git config user.email "git-ai-test@example.invalid"
printf 'hello\n' > sample.txt
/path/to/git-auto-commit-ollama/git-ai.sh --dry-run --no-push --no-banner
```

Jika perubahan menyentuh secret detection, uji minimal:

- Placeholder secret yang seharusnya boleh lewat.
- Token nyata palsu yang seharusnya diblokir.
- Mode `--dry-run` saat secret terdeteksi.
- Mode `--allow-secret-commit` hanya jika perilaku override memang diubah.

Jika perubahan menyentuh Ollama:

- Uji host utama dari `DEFAULT_OLLAMA_HOST`.
- Uji fallback host jika konfigurasi mendukung.
- Uji model yang belum tersedia dengan dan tanpa `--no-pull`.
- Uji `--no-structured` jika logic structured output diubah.

## Panduan Issue

Saat melaporkan bug, sertakan:

- Versi script dari `git-ai --version`.
- OS dan shell yang digunakan.
- Versi `git`, `jq`, `curl`, dan `shellcheck` jika relevan.
- Konfigurasi non-sensitif dari `git-ai.conf`.
- Command yang dijalankan.
- Perilaku yang terjadi dan perilaku yang diharapkan.
- Potongan log yang sudah disensor.

Untuk feature request, jelaskan:

- Masalah yang ingin diselesaikan.
- Workflow saat ini.
- Perubahan perilaku yang diusulkan.
- Dampak terhadap keamanan, default push, dan kompatibilitas CLI.

Jangan sertakan secret valid, URL internal sensitif, nama repository privat, atau diff yang tidak boleh dipublikasikan.

## Panduan Pull Request

Alur kerja yang disarankan:

```bash
git checkout -b fix/deskripsi-singkat
# edit file
bash -n git-ai.sh
shellcheck git-ai.sh
./git-ai.sh --help >/tmp/git-ai-help.txt
git status
git commit
git push -u origin fix/deskripsi-singkat
```

Pull request sebaiknya berisi:

- Ringkasan masalah dan solusi.
- Daftar file utama yang berubah.
- Hasil command validasi yang dijalankan.
- Catatan kompatibilitas jika ada opsi, config, atau default behavior yang berubah.
- Screenshot/log singkat hanya jika membantu dan sudah disensor.

Jaga PR tetap kecil. Jika satu perubahan membutuhkan refactor besar dan behavior change, pisahkan menjadi beberapa PR yang bisa ditinjau satu per satu.

## Keamanan

Project ini berinteraksi dengan diff Git, commit message, secret scanner, dan endpoint Ollama. Perlakukan semua perubahan di area ini sebagai berisiko tinggi.

- Jangan menonaktifkan secret guard secara default.
- Jangan mengirim diff detail ke layanan eksternal sebagai perilaku default.
- Jangan menambahkan telemetry, analytics, atau network call baru tanpa pembahasan eksplisit.
- Jangan menyimpan secret di `git-ai.conf`, test fixture, log, atau dokumentasi.
- Sensor token, host internal, path sensitif, dan nama repository privat sebelum membuka issue atau PR.

Jika menemukan celah keamanan, jangan publikasikan exploit lengkap di issue publik. Hubungi maintainer melalui kanal privat yang tersedia, atau buat laporan minimal yang menjelaskan dampak tanpa menyertakan secret atau langkah eksploitasi lengkap.

## Dokumentasi

Update dokumentasi saat perubahan memengaruhi:

- Opsi CLI.
- Variabel konfigurasi.
- Dependensi.
- Perilaku default commit atau push.
- Secret handling.
- Cara install, uninstall, atau troubleshooting.

Dokumen yang biasanya perlu ikut diperbarui:

- [`README.md`](README.md)
- [`git-ai.conf`](git-ai.conf)
- Help output di `show_help`
- Contoh command di panduan ini

## Checklist

Sebelum submit issue atau pull request, pastikan:

- Perubahan fokus pada satu masalah.
- `bash -n git-ai.sh` lulus.
- `shellcheck git-ai.sh` lulus.
- `./git-ai.sh --help` masih berjalan.
- Dokumentasi sudah diperbarui jika perilaku berubah.
- Tidak ada secret, credential, atau data internal di diff.
- Risiko terhadap Git state pengguna sudah dipertimbangkan.
- Perubahan default sudah dijelaskan dengan alasan yang jelas.
