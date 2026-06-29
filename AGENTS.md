# AGENTS.md

Instruksi ini berlaku untuk seluruh repository `git-auto-commit-ollama`.

## Tujuan

Project ini adalah Bash CLI untuk membuat commit message Git dengan Ollama. Perlakukan perubahan pada staging, commit, push, secret scanning, prompt generation, dan endpoint Ollama sebagai area berisiko tinggi.

## Language

- Gunakan Bahasa Indonesia sebagai bahasa utama dalam percakapan, komentar kode, commit message, penjelasan, ringkasan kerja, dan dokumentasi.
- Bahasa Inggris boleh digunakan untuk istilah teknis, judul dokumen, heading, nama API, nama library, command, error message, nama file, nama branch, atau konsep yang lebih jelas jika tetap ditulis dalam bahasa aslinya.
- Untuk komentar kode baru, ikuti gaya file sekitar. Tambahkan komentar hanya saat konteks lokal tidak mudah dibaca dari kode.

## Peta Repo

- `git-ai.sh`: CLI utama. Sebagian besar perubahan behavior ada di sini.
- `git-ai.conf`: default runtime config. Jangan simpan secret di sini.
- `Makefile`: install/uninstall symlink `git-ai`.
- `.github/workflows/ci.yml`: CI validasi Bash.
- `README.md`, `CONTRIBUTING.md`, `SECURITY.md`: dokumentasi publik.

## Dokumentasi

- Update README saat behavior pengguna, opsi CLI, config, dependensi, install, troubleshooting, atau command validasi dasar berubah.
- Update CONTRIBUTING saat workflow kontribusi, validasi PR, atau standar kode berubah.
- Update SECURITY saat vulnerability scope, reporting process, scope keamanan, disclosure, keamanan penggunaatau security design notes berubah.
- Hindari duplikasi lintas dokumen. README menjadi sumber utama untuk penggunaan dan validasi dasar.
- Jangan menyalin ulang detail panjang dari dokumen tersebut ke dokumen lain; cukup tautkan ke sumber utama.

## Aturan Kerja

- Baca file yang relevan sebelum mengubahnya.
- Jaga perubahan tetap kecil dan sesuai permintaan.
- Jangan menjalankan command destruktif Git seperti `git reset --hard` atau checkout paksa kecuali user meminta eksplisit.
- Jangan menjalankan `make install`, `make uninstall`, atau command yang mengubah sistem global kecuali user meminta eksplisit.
- Jangan menjalankan `git-ai` untuk membuat commit nyata kecuali user meminta eksplisit. Untuk uji runtime, gunakan `--dry-run` di repository sementara.
- Jangan mengubah default model, default push, host fallback, atau format commit message tanpa alasan jelas dan pembaruan dokumentasi.
- Jangan menambahkan dependensi wajib tanpa memperbarui `check_deps`, README, dan panduan kontribusi.

## Gaya Bash

- Pertahankan `#!/usr/bin/env bash` dan `set -euo pipefail`.
- Ikuti gaya fungsi dan output yang sudah ada di `git-ai.sh`.
- Quote variable expansion kecuali ada alasan Bash yang jelas.
- Gunakan `jq` untuk JSON, bukan parsing string ad hoc.
- Jaga output pengguna tetap berbahasa Indonesia.
- Validasi input config dan argumen CLI sedekat mungkin dengan parsing/checking yang sudah ada.
- Jika menambah opsi CLI, update `parse_args`, `show_help`, README, dan test/help validation yang relevan.
- Jika mengubah config, update `git-ai.conf`, fallback default, validasi config, README, dan dokumentasi terkait.

## Keamanan

- Safe mode dan secret guard harus tetap konservatif secara default.
- `--force-diff` dan `--allow-secret-commit` harus tetap override eksplisit.
- `--dry-run` tidak boleh membuat commit, push, atau perubahan permanen pada Git state.
- `--no-push` harus selalu mencegah push.
- `--no-stage` harus memakai staged changes yang sudah ada dan tidak melakukan staging otomatis.
- Jangan menambahkan telemetry, analytics, atau network call baru tanpa pembahasan eksplisit.
- Jangan menulis secret, token, host internal sensitif, atau log privat ke test fixture, dokumentasi, atau output debug.

## Verifikasi

Jalankan validasi dasar setelah mengubah `git-ai.sh` atau behavior yang terkait:

```bash
bash -n git-ai.sh
shellcheck git-ai.sh
./git-ai.sh --help >/tmp/git-ai-help.txt
```

Untuk perubahan runtime, uji di repository sementara dan gunakan dry-run:

```bash
tmpdir=$(mktemp -d)
git init "$tmpdir"
cd "$tmpdir"
git config user.name "git-ai test"
git config user.email "git-ai-test@example.invalid"
printf 'hello\n' > sample.txt
/path/to/git-auto-commit-ollama/git-ai.sh --dry-run --no-push --no-banner
```

Jika Ollama tidak tersedia, jangan memalsukan hasil runtime. Laporkan bahwa validasi runtime tidak dijalankan dan sebutkan alasannya.

## Review Output

Saat menyelesaikan tugas, ringkas:

- File yang berubah.
- Validasi yang dijalankan.
- Validasi yang tidak dijalankan beserta alasannya.
- Risiko atau tindak lanjut yang masih relevan.
