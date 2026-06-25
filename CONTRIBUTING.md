# Panduan Berkontribusi (Contributing)

Terima kasih atas ketertarikan Anda untuk berkontribusi pada proyek `git-auto-commit-ollama`! 

## Cara Berkontribusi

1. **Fork** repositori ini ke akun Anda sendiri.
2. Lakukan *clone* ke mesin lokal Anda.
3. Buat sebuah branch baru untuk menampung fitur baru atau perbaikan *bug* Anda (`git checkout -b nama-fitur-baru`).
4. Lakukan perubahan pada kode.
5. Uji perubahan Anda dan pastikan tidak ada sintaks bash yang rusak.
6. Commit perubahan Anda dengan *commit message* yang jelas (Anda bisa menggunakan skrip `git-ai` ini sendiri!).
7. **Push** branch Anda ke repositori hasil fork (`git push origin nama-fitur-baru`).
8. Buat **Pull Request** dari repositori Anda ke repositori utama.

## Panduan Penulisan Kode (Bash)
- Gunakan fitur Bash secara murni apabila memungkinkan untuk meminimalisir ketergantungan paket eksternal (sedapat mungkin, skrip hanya mengandalkan utilitas POSIX, `git`, `curl`, dan `jq`).
- Hindari penambahan *library* atau perintah spesifik sistem operasi (seperti `apt`, `yum`, dsb) di dalam script utama.
- Usahakan penulisan variabel lingkungan konsisten (huruf kapital dan *underscore* seperti `OLLAMA_HOST`).
- Jika Anda menambahkan argumen baru (`--arg-baru`), pastikan teks dokumentasinya (`git-ai --help`) juga diperbarui.

Semua kontribusi akan direviu sebelum digabungkan ke cabang utama.
