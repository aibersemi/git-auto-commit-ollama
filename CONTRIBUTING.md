# Contributing

Terima kasih sudah ingin berkontribusi ke `git-auto-commit-ollama`. Panduan ini dibuat supaya perubahan tetap kecil, mudah ditinjau, dan aman untuk tool yang bekerja langsung pada Git state pengguna.

## Daftar Isi

- [Jenis Kontribusi](#jenis-kontribusi)
- [Sebelum Mulai](#sebelum-mulai)
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
- Ikuti prasyarat dan instalasi dari [`README.md`](README.md), bukan dari salinan instruksi di dokumen ini.
- Cek issue atau pull request yang sudah ada agar pekerjaan tidak duplikat.
- Buat perubahan yang fokus pada satu masalah.
- Ikuti kebijakan data sensitif di [`SECURITY.md`](SECURITY.md).
- Pastikan perubahan tetap cocok untuk penggunaan lokal dan jaringan internal.

## Standar Kode

Project ini adalah Bash CLI. Ikuti gaya yang sudah ada di `git-ai.sh`.

- Pertahankan `#!/usr/bin/env bash` dan `set -euo pipefail`.
- Pastikan lint Bash tetap bersih; command validasi utama ada di README.
- Quote variable expansion kecuali ada alasan Bash yang jelas.
- Gunakan fungsi kecil dengan nama yang menjelaskan perilaku.
- Jaga output pengguna tetap berbahasa Indonesia.
- Jangan menambah dependensi wajib tanpa memperbarui `check_deps`, README, dan panduan ini.
- Jika menambah opsi CLI, update `parse_args`, `show_help`, README, dan contoh penggunaan yang relevan.
- Jika mengubah konfigurasi, update `git-ai.conf`, validasi config, README, dan default fallback.
- Hindari perubahan destruktif terhadap Git state pengguna. Untuk perilaku berisiko, sediakan dry-run, konfirmasi, atau guard yang jelas.
- Jaga secret handling tetap konservatif. Jangan melemahkan safe mode atau secret guard tanpa alasan teknis yang kuat.

## Pengujian

Jalankan validasi dasar dari [`README.md#pengembangan`](README.md#pengembangan) sebelum membuat pull request.

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
- Mode preview saat secret terdeteksi.
- Override secret commit hanya jika perilaku override memang diubah.

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

Untuk laporan keamanan, jangan gunakan issue publik; ikuti [`SECURITY.md`](SECURITY.md). Untuk bug biasa, sensor log dan konfigurasi sebelum dipublikasikan.

## Panduan Pull Request

Alur kerja yang disarankan:

```bash
git checkout -b fix/deskripsi-singkat
# edit file
# jalankan validasi dari README bagian Pengembangan
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

Untuk vulnerability, threat surface, atau perubahan yang menyentuh secret handling, ikuti [`SECURITY.md`](SECURITY.md). Di pull request, jelaskan dampak keamanan dan pengujian tambahan yang dilakukan.

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
- Validasi dasar dari README sudah dijalankan.
- Smoke test tambahan dijelaskan jika perubahan menyentuh runtime.
- Dokumentasi sudah diperbarui jika perilaku berubah.
- Catatan keamanan mengikuti SECURITY jika perubahan menyentuh area sensitif.
- Perubahan default sudah dijelaskan dengan alasan yang jelas.
