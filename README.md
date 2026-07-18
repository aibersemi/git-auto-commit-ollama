<div align="center">

# Git Auto Commit Ollama

[![CI](https://github.com/aibersemi/git-auto-commit-ollama/actions/workflows/ci.yml/badge.svg)](https://github.com/aibersemi/git-auto-commit-ollama/actions/workflows/ci.yml)
![Bash](https://img.shields.io/badge/Bash-CLI-4EAA25?logo=gnubash&logoColor=white)
![Ollama](https://img.shields.io/badge/Ollama-local_AI-111827)
[![Saweria](https://img.shields.io/badge/Support-Saweria-F97316)](https://saweria.co/aibersemi)

</div>

CLI Bash untuk membuat commit message Git secara otomatis dengan Ollama.

`git-ai` membantu workflow commit harian: staging perubahan, membaca konteks diff, meminta model Ollama membuat commit message Conventional Commit berbahasa Inggris, lalu commit dan push. Tool ini cocok untuk server, workstation, atau repo internal yang ingin commit message tetap informatif tanpa mengirim kode ke layanan AI eksternal.

## Table of Contents

- [Features](#features)
- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Security](SECURITY.md)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Repository Structure](#repository-structure)
- [Support](#support)
- [License](#license)

## Features

- Auto stage perubahan dengan `git add -A`, atau staging interaktif via `git add -p`.
- Spinner saat `git add -A` dan secret scan staged changes berjalan di terminal, dengan status teks pada output non-interaktif.
- Preflight Ollama memeriksa apakah model sudah ada di memori; model yang belum ter-load dipanaskan dengan spinner sebelum proses Git dimulai.
- Generate commit message Conventional Commit melalui Ollama `/api/chat`.
- Semua output CLI dan commit message dihasilkan dalam bahasa Inggris.
- Structured output JSON Schema untuk hasil commit message yang lebih stabil.
- Analisis per-file opsional supaya prompt tetap fokus pada perubahan penting.
- Prioritaskan capability, API, integritas data, security, dan user flow; artefak generated hanya menjadi konteks pendukung.
- Safe mode saat pola sensitif terdeteksi, sehingga diff detail tidak dikirim ke model.
- Secret guard untuk staged changes, dengan dukungan tambahan `gitleaks` jika tersedia.
- Auto-push ke remote upstream, atau set upstream pertama kali jika belum ada.
- Dry-run untuk melihat commit message tanpa mengubah Git state.
- Lock per repository agar dua proses `git-ai` tidak berjalan bersamaan.
- CI GitHub Actions untuk validasi syntax Bash, ShellCheck, dan output help.

## How It Works

```mermaid
flowchart LR
  A[Perubahan Git] --> O[Verifikasi dan panaskan model Ollama]
  O --> B{Mode staging}
  B -->|default| C[git add -A]
  B -->|--patch| D[git add -p]
  B -->|--no-stage| E[Pakai staged changes]
  C --> F[Secret scan]
  D --> F
  E --> F
  F --> G[Bangun konteks diff]
  G --> H[Analisis per-file opsional]
  H --> I[Generate commit message via Ollama]
  I --> J[git commit]
  J --> K{Push aktif?}
  K -->|ya| L[git push]
  K -->|tidak| M[Selesai]
```

Commit message memakai format Conventional Commit tanpa scope: `<type>: <summary>`. Jika hanya satu file yang berubah, message hanya berisi subject. Jika lebih dari satu file berubah, message menambahkan 1-6 bullet penting setelah satu baris kosong. Batas total default message adalah `65536` karakter dan dapat diatur melalui `MAX_COMMIT_MESSAGE_LENGTH`; subject tidak dibatasi menjadi 72 atau 120 karakter.

Saat source change dan artefak generated muncul bersamaan, `git-ai` memilih tema subject dari perubahan fungsional seperti capability domain, API, integritas data, security, atau user flow. File generated—misalnya client API, schema, snapshot, dan hasil codegen—tidak menjadi tema utama atau bullet mandiri, kecuali tidak ada source change lain.

## Prerequisites

Wajib tersedia di mesin yang menjalankan CLI:

- `bash`
- `git`
- `curl`
- `jq`
- `flock` dari paket `util-linux`
- Ollama server yang bisa diakses dari host ini

Opsional:

- `ollama` CLI, dipakai untuk auto-pull model jika model default belum ada.
- `gitleaks`, dipakai sebagai scanner tambahan untuk staged secrets.
- `shellcheck`, dipakai untuk validasi saat development.

Contoh instalasi dependensi di Ubuntu/Debian:

```bash
sudo apt-get update
sudo apt-get install -y git curl jq util-linux shellcheck
```

Pastikan Ollama berjalan dan model default tersedia:

```bash
ollama serve
ollama pull gemma4:e4b
```

## Installation

Clone repository:

```bash
git clone git@github.com:aibersemi/git-auto-commit-ollama.git
cd git-auto-commit-ollama
```

Install command `git-ai` ke `/usr/local/bin`:

```bash
make install
```

Gunakan `PREFIX` jika ingin memasang ke lokasi lain:

```bash
make install PREFIX="$HOME/.local"
```

Setelah install, command tersedia dari direktori mana pun:

```bash
git-ai --version
git-ai --help
```

Uninstall:

```bash
make uninstall
```

## Configuration

Konfigurasi utama ada di [`git-ai.conf`](git-ai.conf). File ini berada satu folder dengan executable atau symlink `git-ai`, dan akan dibaca otomatis saat CLI dijalankan.

Nilai default saat ini:

| Variabel | Default | Fungsi |
| --- | --- | --- |
| `DEFAULT_MODEL` | `gemma4:e4b` | Model Ollama yang selalu dipakai. |
| `DEFAULT_OLLAMA_HOST` | `http://127.0.0.1:11434` | Host utama Ollama. |
| `FALLBACK_OLLAMA_HOST` | `http://10.50.0.2:11434` | Host cadangan jika host utama tidak bisa diakses. |
| `DEFAULT_DO_PUSH` | `1` | Push otomatis setelah commit. |
| `AI_TEMPERATURE` | `0.2` | Temperatur request ke model. |
| `AI_THINK` | `false` | Opsi thinking Ollama: `false`, `true`, `low`, `medium`, atau `high`. |
| `AI_NUM_PREDICT` | `2048` | Token output request utama. |
| `AI_MAX_NUM_PREDICT` | `2048` | Batas maksimum `num_predict`. |
| `MAX_COMMIT_MESSAGE_LENGTH` | `65536` | Panjang maksimal seluruh commit message. |
| `FILE_ANALYSIS_LIMIT` | `6` | Batas jumlah file untuk analisis per-file. |
| `FILE_ANALYSIS_PARALLELISM` | `4` | Jumlah request analisis file paralel. |
| `FILE_ANALYSIS_NUM_PREDICT_PER_FILE` | `512` | Token output untuk analisis per-file. |
| `MAX_FILES_LIST` | `20` | Batas jumlah file dalam konteks nama/status Git. |
| `TOP_FILES` | `4` | Jumlah file terbesar untuk ringkasan hunk. |
| `MAX_HUNK_CHARS` | `1000` | Batas karakter hunk per file. |
| `MAX_TOTAL_HUNKS_CHARS` | `3500` | Batas total karakter hunk yang dikirim ke AI. |

Jika `DEFAULT_OLLAMA_HOST` dikosongkan, script akan mencoba membaca `OLLAMA_HOST` dari:

```text
/etc/systemd/system/ollama.service
```

Jangan menyimpan secret di `git-ai.conf`.

## Usage

Jalankan dari dalam repository Git yang memiliki perubahan:

```bash
git-ai
```

Perintah default akan:

1. menjalankan `git add -A`;
2. memindai potensi secret;
3. membuat commit message dengan Ollama;
4. menjalankan `git commit`;
5. menjalankan `git push` jika `DEFAULT_DO_PUSH=1`.

Contoh workflow umum:

```bash
# Commit tanpa push
git-ai --no-push

# Staging interaktif
git-ai --patch

# Review atau edit commit message sebelum commit
git-ai --interactive

# Pakai staged changes yang sudah ada
git add git-ai.sh git-ai.conf
git-ai --no-stage

# Lihat commit message tanpa commit atau push
git-ai --dry-run

# Tampilkan status Git saja
git-ai --status
```

Opsi lanjutan:

```bash
# Matikan analisis per-file agar lebih cepat
git-ai --no-file-analysis

# Batasi analisis per-file ke 3 file
git-ai --file-analysis-limit 3

# Ubah paralelisme analisis per-file
git-ai --file-analysis-parallelism 2

# Matikan structured output dan pakai fallback plain text
git-ai --no-structured

# Jangan auto-pull model jika belum tersedia
git-ai --no-pull

# Jalankan commit tanpa Git hooks
git-ai --no-verify

# Tampilkan log debug
git-ai --debug
```

## Troubleshooting

| Masalah | Penyebab umum | Solusi |
| --- | --- | --- |
| `Ollama tidak dapat diakses` | Service mati atau host salah. | Jalankan `ollama serve`, cek `DEFAULT_OLLAMA_HOST`, atau isi `FALLBACK_OLLAMA_HOST`. |
| `Model DEFAULT_MODEL tidak ditemukan` | Model belum ada di server Ollama. | Jalankan `ollama pull gemma4:e4b` atau ubah `DEFAULT_MODEL`. |
| `--no-stage, tapi belum ada staged changes` | Belum menjalankan `git add`. | Stage file lebih dulu, lalu ulangi `git-ai --no-stage`. |
| Commit dibatalkan karena secret | Scanner menemukan potensi credential. | Hapus secret dari staged changes, lalu ulangi commit. |
| Hook Git menggagalkan commit | Pre-commit/pre-push hook gagal. | Perbaiki temuan hook, atau gunakan `--no-verify` jika memang disengaja. |
| Push gagal | Branch belum punya remote, akses SSH salah, atau remote menolak push. | Cek `git remote -v`, akses SSH, dan status branch. |

## Development

Validasi lokal:

```bash
bash -n git-ai.sh
shellcheck git-ai.sh
./git-ai.sh --help
```

CI di repository menjalankan validasi yang sama melalui GitHub Actions:

- `bash -n git-ai.sh`
- `shellcheck git-ai.sh`
- `./git-ai.sh --help`

Untuk mencoba tanpa membuat commit:

```bash
./git-ai.sh --dry-run --no-push
```

## Repository Structure

```text
.
|-- .github/workflows/ci.yml  # CI Bash validation
|-- Makefile                  # install/uninstall symlink git-ai
|-- git-ai.conf               # konfigurasi default runtime
`-- git-ai.sh                 # CLI utama
```

## Support

Jika project ini membantu workflow Anda, dukungan bisa dikirim melalui [Saweria](https://saweria.co/aibersemi).

## License

Project ini menggunakan MIT License. Lihat [`LICENSE`](LICENSE) untuk teks lisensi lengkap.
