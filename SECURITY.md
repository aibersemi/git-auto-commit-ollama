# Kebijakan Keamanan (Security Policy)

## Pelaporan Kerentanan Keamanan (Vulnerabilities)

Jika Anda menemukan kerentanan pada proyek ini yang dapat menimbulkan risiko keamanan (seperti eksploitasi bash atau injeksi tak terduga ke model AI), **mohon untuk tidak membuka Issue secara publik**.
Silakan lapor kepada pemilik/maintainer repositori secara langsung (via email atau pesan privat) agar tim kami bisa segera menyusun tambalan (patch) sebelum masalah diekspos ke publik.

## Fitur Keamanan Bawaan (Safe Mode)

Proyek `git-ai` memiliki fitur bawaan untuk secara proaktif mendeteksi potensi kebocoran rahasia (secrets). Alat ini membaca output `git diff` menggunakan ekspresi reguler (Regex) untuk mendeteksi variabel yang mencurigakan seperti:
- Kredensial, kunci, dan password.
- API Key (misalnya AWS, GitHub, GCP, Slack).
- Pola sertifikat dan Private Key.

Jika skrip menemukan string yang mungkin sensitif, ia akan memberikan peringatan dan menyembunyikan detail dif tersebut agar secret Anda tidak diteruskan secara sengaja (atau tidak sengaja) ke endpoint API pihak ketiga atau tercetak di log. Untuk analisis per-file, file yang memuat pola sensitif akan dilewati; skrip tetap menganalisis file aman lain sampai batas konfigurasi jika tersedia.

Meski demikian, ini **bukan jaminan anti bocor yang sempurna**. Pengguna disarankan untuk **tetap waspada dan meninjau perubahan** kode mereka secara mandiri sebelum melalukan `git commit` maupun `push`. 

## Versi Dukungan

Mohon senantiasa perbarui dan sinkronkan instalasi skrip Anda (`git pull` lalu perbarui/buat ulang symlink) ke versi terbaru agar mendapatkan daftar regex filter keamanan yang paling termutakhir.
