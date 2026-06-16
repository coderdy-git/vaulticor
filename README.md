# Vaulticor

Vaulticor adalah aplikasi **Password Manager** (pengelola kata sandi) modern yang mengusung prinsip **Zero-Knowledge Architecture**. Aplikasi ini dirancang agar data sensitif pengguna dienkripsi sepenuhnya di sisi perangkat (client-side) sebelum disimpan ke infrastruktur cloud.

---

## 🔒 Prinsip & Mekanisme Keamanan (Zero-Knowledge)

Keamanan Vaulticor dibangun di atas premis bahwa **server/penyedia layanan cloud tidak boleh mengetahui atau memiliki kemampuan untuk mendekripsi data kredensial Anda**.

```
[Password Master] ──(PBKDF2)──> [Master Key]
                                    │
                                    ├───> [Login Hash] ──> (Auth ke Supabase)
                                    │
                                    └───> Dekripsi [Data Key] (AES-GCM) ──> Dekripsi Brankas Anda
```

### 1. Key Derivation Function (KDF)
Saat pendaftaran atau masuk log, Password Master Anda tidak pernah dikirim ke server. Aplikasi menggunakan fungsi **PBKDF2 dengan SHA-256 (100.000 iterasi)** bersama *Salt* acak yang unik per pengguna untuk menghasilkan kunci turunan lokal:
*   **Master Key (MK):** Digunakan secara lokal untuk mengenkripsi/dekripsi kunci utama (*Data Key*).
*   **Login Hash:** Hasil hash lanjutan dari *Master Key* yang dikirim ke Supabase Auth sebagai verifikasi password masuk. Server hanya mengenal *Login Hash* ini, bukan Password Master asli Anda.

### 2. Enkripsi AES-256-GCM
Setiap entri password atau username yang Anda simpan dienkripsi menggunakan metode **AES-GCM 256-bit** dengan Kunci Data (*Data Key*) unik. Enkripsi ini menghasilkan *Ciphertext*, *Nonce/IV*, dan *MAC (Message Authentication Code)* yang menjamin integritas data (tidak dapat dimodifikasi di server tanpa merusak dekripsi).

### 3. Pembersihan RAM Otomatis (Auto-Clear RAM)
Ketika brankas dikunci (baik secara manual maupun otomatis), seluruh variabel instansi *Master Key* dan *Data Key* biner di memori RAM perangkat dihapus bersih. Hal ini meminimalkan risiko serangan *Memory Dump* atau pembacaan memori oleh aplikasi pihak ketiga yang berbahaya.

---

## ☁️ Integrasi Infrastruktur Cloud (Supabase)

Vaulticor menggunakan **Supabase** sebagai Backend-as-a-Service (BaaS) untuk sinkronisasi data antarperangkat dengan lapisan keamanan berlapis:

*   **Authentication (GoTrue):** Autentikasi email menggunakan sistem bawaan Supabase dengan password berupa *Login Hash* terenkripsi.
*   **Row Level Security (RLS):** Aturan ketat di tingkat database PostgreSQL memastikan pengguna yang terautentikasi hanya memiliki akses baca/tulis ke baris data miliknya sendiri (`auth.uid() = user_id`).
*   **Zero-Knowledge Database:** Database PostgreSQL Supabase hanya menyimpan data profil biner terenkripsi (Salt, Encrypted Data Key, MAC) dan daftar kredensial terenkripsi.

---

## 🛠️ Otomatisasi Kompilasi Aman (CI/CD GitHub Actions)

Untuk menjaga keamanan kredensial aplikasi, **Supabase URL** dan **Anon Key** tidak ditulis keras (*hardcoded*) di dalam kode sumber. Vaulticor mendukung kompilasi aman menggunakan variabel lingkungan waktu build (*build-time variables*).

### Setup GitHub Secrets
Sebelum menjalankan kompilasi otomatis di repositori GitHub Anda, Anda wajib mendaftarkan dua rahasia berikut di **Settings -> Secrets and variables -> Actions**:
1.  `SUPABASE_URL`: URL API Proyek Supabase Anda.
2.  `SUPABASE_ANON_KEY`: Kunci Publik API Anonim Supabase Anda.

Pipa CI/CD GitHub Actions akan menyuntikkan rahasia tersebut secara aman ke dalam APK Android menggunakan argumen `--dart-define` saat build rilis berjalan di server cloud terisolasi.
