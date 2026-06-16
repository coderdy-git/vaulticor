-- 1. Buat Tabel Profiles (Menyimpan Salt & Data Key Terenkripsi Klien)
CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid REFERENCES auth.users ON DELETE CASCADE PRIMARY KEY,
  client_salt text NOT NULL,
  encrypted_data_key text NOT NULL,
  iv_dk text NOT NULL,
  encrypted_data_key_recovery text NOT NULL,
  iv_dk_recovery text NOT NULL,
  created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- 2. Buat Tabel Passwords (Menyimpan Data Kredensial Terenkripsi Klien)
CREATE TABLE IF NOT EXISTS public.passwords (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id uuid REFERENCES auth.users ON DELETE CASCADE NOT NULL,
  title text NOT NULL,
  encrypted_user text NOT NULL,
  iv_user text NOT NULL,
  mac_user text NOT NULL,
  encrypted_pass text NOT NULL,
  iv_pass text NOT NULL,
  mac_pass text NOT NULL,
  created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- 3. Aktifkan Keamanan Row Level Security (RLS)
ALTER TABLE public.passwords ENABLE ROW LEVEL SECURITY;

-- 4. Buat Kebijakan Akses Data (User Hanya Bisa Mengakses Datanya Sendiri)
DROP POLICY IF EXISTS "User can only access their own passwords" ON public.passwords;
CREATE POLICY "User can only access their own passwords" ON public.passwords
  FOR ALL USING (auth.uid() = user_id);
