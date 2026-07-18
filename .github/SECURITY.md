# Security Policy

`git-auto-commit-ollama` adalah Bash CLI yang membaca Git diff, membuat commit message melalui endpoint Ollama yang dikonfigurasi, lalu dapat menjalankan `git commit` dan `git push`. Karena tool ini menyentuh Git state, staged changes, secret scanning, dan endpoint jaringan, laporan keamanan diprioritaskan untuk dampak terhadap kerahasiaan, integritas, dan kontrol atas repository pengguna.

## Table of Contents

- [Supported Versions](#supported-versions)
- [Safe Usage](#safe-usage)
- [Reporting a Vulnerability](#reporting-a-vulnerability)
- [What to Include](#what-to-include)
- [Scope](#scope)
- [Out of Scope](#out-of-scope)
- [Disclosure Process](#disclosure-process)
- [Security Design Notes](#security-design-notes)

## Supported Versions

Repository saat ini belum memiliki tag Git pada riwayat yang tersedia. Dukungan keamanan mengikuti branch `main` dan revisi terbaru `git-ai.sh`. Nilai `VERSION` pada script adalah identitas versi CLI, bukan janji bahwa seluruh seri minor menerima backport keamanan.

| Version / branch | Supported | Notes |
| --- | --- | --- |
| `main` | Yes | Target utama untuk patch keamanan. |
| Versi script saat ini (`1.5.1`) | Yes | Didukung selama sesuai dengan revisi terbaru di `main`. |
| Commit atau salinan lama | Tidak dijamin | Update ke `main`; laporan tetap berguna jika isu juga berlaku pada versi terbaru. |
| Fork lokal yang dimodifikasi | Best effort | Sertakan diff non-sensitif jika laporan hanya terjadi di fork. |

Jika release tag resmi atau maintenance branch ditambahkan, tabel ini harus diperbarui untuk menjelaskan versi yang masih menerima patch keamanan.

## Safe Usage

`git-ai` mengirim konteks perubahan ke endpoint Ollama yang aktif. Konteks tersebut dapat mencakup nama dan status file, statistik dan ringkasan Git, potongan diff, serta diff yang dipakai dalam request analisis per-file. Endpoint dapat berada di mesin lokal atau host jaringan lain; tool ini tidak menjamin data tetap berada di mesin yang menjalankan CLI.

`git-ai` memiliki dua proteksi yang bekerja secara terpisah saat mendeteksi potensi secret:

- Secret guard pada staged changes akan membatalkan commit jika baris tambahan terlihat seperti token, password, private key, atau credential lain.
- Safe mode akan menghapus detail diff dari prompt utama dan melewati file sensitif pada analisis per-file saat pola bawaan terdeteksi. Metadata Git dan diff file lain yang tidak terdeteksi sensitif masih dapat dikirim.

Jika `gitleaks` tersedia, script juga menjalankan:

```bash
gitleaks protect --staged --redact --no-banner
```

Override tersedia, tetapi gunakan hanya untuk kasus yang benar-benar disengaja:

```bash
# Izinkan commit walau secret scanner menemukan temuan
git-ai --allow-secret-commit

# Tetap kirim diff detail ke AI walau pola sensitif terdeteksi
git-ai --force-diff
```

Kedua override tidak saling menggantikan:

- `--allow-secret-commit` hanya melewati pembatalan commit; safe mode tetap aktif jika pola sensitif terdeteksi.
- `--force-diff` mengizinkan pengiriman diff detail, tetapi tidak melewati secret guard.
- Untuk mengizinkan commit sekaligus mengirim diff yang terdeteksi sensitif, pengguna harus memilih kedua opsi secara eksplisit.

Catatan penting:

- Prefer jalankan Ollama secara lokal atau di jaringan tepercaya. Periksa `DEFAULT_OLLAMA_HOST` dan kosongkan `FALLBACK_OLLAMA_HOST` jika endpoint cadangan tidak digunakan.
- `git-ai.conf` di-`source` sebagai shell code. Perlakukan file tersebut sebagai code tepercaya, batasi siapa yang dapat mengubahnya, dan jangan menjalankan config dari sumber yang tidak dipercaya.
- Review perubahan sebelum commit, terutama untuk file konfigurasi dan environment.
- Tambahkan `.env`, credential, dan artifact sensitif lain ke `.gitignore`.
- Gunakan `--no-stage` untuk membatasi analisis ke perubahan yang sudah ditinjau, `--interactive` untuk meninjau message, dan `--no-push` untuk memisahkan commit dari push.
- `--dry-run` memakai index sementara dan tidak membuat commit, push, atau perubahan permanen pada Git state. Mode ini tetap menghubungi Ollama, melakukan warm-up, dan dapat menjalankan `ollama pull`; tambahkan `--no-pull` jika model baru tidak boleh dipasang.
- Jika secret guard menemukan temuan pada dry-run, script memperingatkan lalu tetap membuat preview tanpa commit atau push.
- `--no-verify` diterapkan sebagai `git commit --no-verify`, yang melewati `pre-commit` dan `commit-msg`; hook lain seperti `pre-push` tetap berjalan pada tahapnya masing-masing.

Deteksi secret bersifat best effort dan dapat menghasilkan false positive atau false negative. Safe mode bawaan dan hasil `gitleaks` juga tidak selalu mendeteksi pola yang sama. Jangan mengandalkan scanner sebagai pengganti review staged changes.

## Reporting a Vulnerability

Laporkan kerentanan secara privat melalui GitHub Security Advisories:

```text
https://github.com/aibersemi/git-auto-commit-ollama/security/advisories/new
```

Jika private vulnerability reporting belum tersedia untuk repository ini, jangan buka issue publik berisi detail exploit, secret, atau proof of concept penuh. Buat issue publik minimal untuk meminta kontak keamanan privat, atau hubungi maintainer melalui kanal privat organisasi yang tersedia.

Gunakan issue publik hanya untuk bug non-keamanan seperti typo dokumentasi, error help output, atau masalah usability yang tidak menimbulkan risiko kerahasiaan, integritas, atau akses tidak sah.

## What to Include

Sertakan informasi berikut agar laporan bisa ditriage cepat:

- Versi script dari `git-ai --version`.
- Commit hash atau branch yang diuji.
- OS, shell, dan versi `git`, `curl`, `jq`, serta `flock`.
- Apakah `gitleaks` dan `ollama` CLI tersedia.
- Konfigurasi non-sensitif dari `git-ai.conf`.
- Command yang dijalankan.
- Langkah reproduksi di repository sementara.
- Dampak keamanan yang jelas.
- Perilaku aktual dan perilaku yang diharapkan.
- Log yang sudah disensor.

Jangan sertakan:

- Secret valid, token, password, private key, cookie, session, atau credential internal.
- Diff repository privat yang tidak boleh dibagikan.
- URL internal, hostname internal, username, atau path produksi yang sensitif.
- Payload yang merusak data atau menjalankan aksi destruktif.

Untuk contoh smoke test berbasis repository sementara, gunakan pola di [`CONTRIBUTING.md#testing`](CONTRIBUTING.md#testing).

## Scope

Laporan berikut dianggap in scope:

- Diff detail atau data sensitif tetap terkirim ke Ollama saat safe mode seharusnya aktif.
- Secret guard gagal memblokir token, private key, password, atau credential yang jelas pada staged additions.
- Opsi seperti `--force-diff` atau `--allow-secret-commit` aktif tanpa aksi eksplisit pengguna.
- Command injection, argument injection, atau shell evaluation tak terduga yang dipicu oleh nama file, diff, branch, remote, nilai config saat digunakan, atau output model.
- Perubahan permanen pada index asli atau refs, commit, atau push saat `--dry-run`; staging otomatis saat `--no-stage`; atau push saat `--no-push`.
- Race condition atau lock bypass yang memungkinkan dua proses `git-ai` merusak Git state repository yang sama.
- Penulisan file sementara, lock file, atau cleanup yang bisa merusak file di luar area yang dimaksud.
- Fallback host Ollama atau pembacaan service environment yang menyebabkan data dikirim ke endpoint yang tidak dikonfigurasi.
- Log debug, error output, atau summary yang membocorkan secret staged changes.
- Regressions pada validasi konfigurasi yang membuat perilaku keamanan berubah diam-diam.

## Out of Scope

Hal berikut biasanya tidak diproses sebagai kerentanan keamanan project ini:

- Kualitas commit message, hallucination model, atau subject commit yang kurang akurat.
- Pengiriman diff sensitif yang memang diotorisasi dengan `--force-diff`, commit yang memang diotorisasi dengan `--allow-secret-commit`, atau bypass hook commit yang memang diminta dengan `--no-verify`. Kerusakan di luar batas masing-masing override tetap in scope.
- Kerentanan pada Git, Ollama, curl, jq, flock, gitleaks, shell, OS, atau model AI pihak ketiga.
- Workstation, repository, atau user account yang sudah dikuasai attacker sebelum `git-ai` dijalankan.
- Perintah yang memang ditulis secara eksplisit di `git-ai.conf`, karena file tersebut sengaja di-`source` sebagai trusted shell code. Bypass izin tulis config atau evaluasi ulang nilai config yang tidak semestinya tetap in scope.
- Repository yang berisi script hook berbahaya jika pengguna memilih menjalankan hooks Git. `--no-verify` melewati `pre-commit` dan `commit-msg`, tetapi tidak menonaktifkan `pre-push`.
- Leak data dari endpoint Ollama yang dikonfigurasi sendiri oleh pengguna di luar kendali project ini.
- Social engineering, phishing, spam, brute force, atau serangan terhadap akun maintainer.
- Denial of service yang hanya menghabiskan waktu lokal pada input sangat besar tanpa dampak kerahasiaan atau integritas.
- Permintaan bounty. Project ini belum memiliki program bounty.

Jika ragu, laporkan secara privat. Maintainer akan mengklasifikasikan apakah laporan tersebut security issue, bug biasa, atau hardening request.

## Disclosure Process

Target respons:

| Stage | Target |
| --- | --- |
| Acknowledgement | Dalam 7 hari kalender. |
| Triage awal | Dalam 14 hari kalender. |
| Update status | Setidaknya setiap 14 hari setelah triage jika isu valid belum selesai. |
| Fix target | Sesuai severity dan kompleksitas. Isu high impact diprioritaskan. |

Proses penanganan:

1. Maintainer menerima laporan privat dan mengonfirmasi penerimaan.
2. Maintainer mencoba reproduksi pada `main`.
3. Maintainer menentukan severity, scope, dan versi terdampak.
4. Patch disiapkan di branch/private fork jika diperlukan.
5. Reporter diminta memverifikasi fix bila memungkinkan.
6. Setelah fix tersedia, maintainer mempublikasikan advisory atau catatan rilis dengan detail secukupnya untuk mitigasi.

Jangan mempublikasikan detail exploit sebelum fix tersedia atau sebelum ada kesepakatan disclosure dengan maintainer.

## Security Design Notes

Selain panduan penggunaan aman di atas, beberapa prinsip keamanan yang harus dijaga saat mengubah project:

- Default proteksi tidak boleh dilemahkan tanpa alasan teknis yang kuat.
- Override berisiko harus membutuhkan aksi eksplisit pengguna.
- Batas setiap override harus tetap independen: izin commit tidak otomatis menjadi izin pengiriman diff, dan sebaliknya.
- Endpoint utama/fallback dan setiap network call yang dapat menerima konteks repository harus terlihat dan terdokumentasi.
- Config yang di-`source` harus diperlakukan sebagai trusted code; nilai config tetap harus di-quote dan divalidasi saat digunakan.
- Dry-run harus mengisolasi perubahan Git melalui index sementara, walaupun operasi jaringan dan auto-pull tetap dapat terjadi.
- Output debug harus berguna untuk diagnosis tanpa membocorkan credential.
- Dependensi wajib harus tetap sedikit dan mudah diaudit.
- Network call baru harus dibahas eksplisit sebelum diterima.

Checklist kontribusi berada di [`CONTRIBUTING.md#checklist`](CONTRIBUTING.md#checklist).
