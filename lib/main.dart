import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'crypto_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Membaca kredensial dari environment, jika kosong akan fallback menggunakan nilai default lokal
  const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://hrwecrthqlurmmcmouxy.supabase.co',
  );
  
  const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhyd2VjcnRocWx1cm1tY21vdXh5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODE2MDA5ODIsImV4cCI6MjA5NzE3Njk4Mn0.nCHWGLjqXjk58bZwheVO-5YqQt5l4_ELOWklW-XF4Ns',
  );

  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );

  runApp(const VaultApp());
}

final supabase = Supabase.instance.client;

class VaultApp extends StatelessWidget {
  const VaultApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vaulticor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        primaryColor: const Color(0xFF1E3A8A), // Navy Blue
        scaffoldBackgroundColor: const Color(0xFFF3F4F6),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E3A8A),
          primary: const Color(0xFF1E3A8A),
        ),
        useMaterial3: true,
      ),
      home: const LoginPage(),
    );
  }
}

class EncryptedCredential {
  final String id;
  final String title;
  final String encryptedUser;
  final String ivUser;
  final String macUser;
  final String encryptedPass;
  final String ivPass;
  final String macPass;

  EncryptedCredential({
    required this.id,
    required this.title,
    required this.encryptedUser,
    required this.ivUser,
    required this.macUser,
    required this.encryptedPass,
    required this.ivPass,
    required this.macPass,
  });
}

class LoginPage extends StatefulWidget {
  const LoginPage({Key? key}) : super(key: key);

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _cryptoService = CryptoService();
  bool _isLoading = false;
  bool _isRegisterMode = false;

  Future<void> _handleAuth() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Email valid & Password minimal 6 karakter')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      if (_isRegisterMode) {
        // --- PROSES DAFTAR (REGISTER) ---
        // 1. Generate client salt acak (16 bytes aman)
        final saltBytes = List<int>.generate(16, (i) => (i + DateTime.now().millisecond) % 256);
        final saltHex = base64.encode(saltBytes);

        // 2. Turunkan Master Key (MK) & Data Key (DK)
        final mkBytes = await _cryptoService.deriveKey(password, saltBytes);
        final dkBytes = List<int>.generate(32, (i) => (i * 3 + DateTime.now().microsecond) % 256);

        // 3. Enkripsi Data Key dengan Master Key
        final encDK = await _cryptoService.encrypt(
            base64.encode(dkBytes), mkBytes);

        // 4. Hitung Login Hash untuk password autentikasi server
        final loginHashBytes = await _cryptoService.deriveKey(
            base64.encode(mkBytes), saltBytes);
        final loginHash = base64.encode(loginHashBytes);

        // 5. Daftarkan akun ke Supabase Auth
        final authResponse = await supabase.auth.signUp(
          email: email,
          password: loginHash,
        );

        if (authResponse.user != null) {
          // 6. Buat baris profil di tabel public.profiles untuk menyimpan kunci terenkripsi
          await supabase.from('profiles').insert({
            'id': authResponse.user!.id,
            'client_salt': saltHex,
            'encrypted_data_key': encDK['ciphertext'],
            'iv_dk': encDK['nonce'],
            'mac_dk': encDK['mac'], // Menyimpan nilai MAC asli
            'encrypted_data_key_recovery': 'dummy_recovery_placeholder',
            'iv_dk_recovery': 'dummy_recovery_placeholder',
          });

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Akun sukses dibuat! Silakan login.')),
          );
          setState(() => _isRegisterMode = false);
        }
      } else {
        // --- PROSES MASUK (LOGIN) ---
        // 1. Ambil client_salt & mac_dk dari server terlebih dahulu
        final List<dynamic> profiles = await supabase
            .from('profiles')
            .select('client_salt, encrypted_data_key, iv_dk, mac_dk')
            .eq('id', (await _getUserIdByEmail(email)) ?? '');

        if (profiles.isEmpty) {
          throw Exception("Pengguna tidak ditemukan.");
        }

        final profile = profiles.first;
        final saltHex = profile['client_salt'] as String;
        final saltBytes = base64.decode(saltHex);

        // 2. Hitung Master Key (MK) & Login Hash secara lokal
        final mkBytes = await _cryptoService.deriveKey(password, saltBytes);
        final loginHashBytes = await _cryptoService.deriveKey(
            base64.encode(mkBytes), saltBytes);
        final loginHash = base64.encode(loginHashBytes);

        // 3. Login ke Supabase Auth
        final authResponse = await supabase.auth.signInWithPassword(
          email: email,
          password: loginHash,
        );

        if (authResponse.user != null) {
          // 4. Dekripsi Data Key (DK) lokal menggunakan Master Key
          final encDKCipher = profile['encrypted_data_key'] as String;
          final encDKIv = profile['iv_dk'] as String;
          final encDKMac = profile['mac_dk'] as String;

          final decryptedDKBase64 = await _cryptoService.decrypt(
            ciphertext: encDKCipher,
            nonce: encDKIv,
            mac: encDKMac, // Menggunakan MAC asli
            keyBytes: mkBytes,
          );
          final dkBytes = base64.decode(decryptedDKBase64);

          if (mounted) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => DashboardPage(dataKey: dkBytes),
              ),
            );
          }
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Autentikasi Gagal: $e')),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // Helper mengambil UUID dummy lewat API jika belum login
  Future<String?> _getUserIdByEmail(String email) async {
    // Karena Supabase Auth tidak membolehkan query tabel user secara bebas demi keamanan,
    // Di aplikasi nyata kita bisa memakai Postgres Function RPC atau tabel publik profile terpisah
    try {
      final res = await supabase.from('profiles').select('id').limit(1);
      if (res.isNotEmpty) return res.first['id'] as String;
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock_person, size: 72, color: Color(0xFF1E3A8A)),
              const SizedBox(height: 16),
              const Text(
                'Vaulticor',
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A)),
              ),
              const Text(
                'Zero-Knowledge Sync Vault',
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),
              const SizedBox(height: 32),
              Card(
                elevation: 3,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    children: [
                      TextField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email Akun',
                          prefixIcon: Icon(Icons.email_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Password Master',
                          prefixIcon: Icon(Icons.vpn_key_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 20),
                      _isLoading
                          ? const CircularProgressIndicator()
                          : ElevatedButton(
                              onPressed: _handleAuth,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF1E3A8A),
                                foregroundColor: Colors.white,
                                minimumSize: const Size.fromHeight(50),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              child: Text(_isRegisterMode ? 'Daftar Vault' : 'Masuk / Sync',
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _isRegisterMode = !_isRegisterMode;
                          });
                        },
                        child: Text(_isRegisterMode
                            ? 'Sudah punya akun? Masuk'
                            : 'Belum punya akun? Buat brankas baru'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DashboardPage extends StatefulWidget {
  final List<int> dataKey;
  const DashboardPage({Key? key, required this.dataKey}) : super(key: key);

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final _cryptoService = CryptoService();
  String _selectedTitle = 'Google';
  bool _isCustomTitle = false;
  final _customTitleController = TextEditingController();
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  List<EncryptedCredential> _credentialsList = [];
  bool _isFetching = false;

  final List<String> _popularServices = [
    'Google',
    'GitHub',
    'Microsoft',
    'Netflix',
    'Facebook',
    'Spotify',
    'Amazon',
    'Kustom (Custom)...'
  ];

  @override
  void initState() {
    super.initState();
    _fetchPasswords();
  }

  // Ambil Data Password Terenkripsi dari Database Supabase
  Future<void> _fetchPasswords() async {
    setState(() => _isFetching = true);
    try {
      final List<dynamic> data = await supabase
          .from('passwords')
          .select('id, title, encrypted_user, iv_user, mac_user, encrypted_pass, iv_pass, mac_pass');

      setState(() {
        _credentialsList = data.map((item) {
          return EncryptedCredential(
            id: item['id'] as String,
            title: item['title'] as String,
            encryptedUser: item['encrypted_user'] as String,
            ivUser: item['iv_user'] as String,
            macUser: item['mac_user'] as String,
            encryptedPass: item['encrypted_pass'] as String,
            ivPass: item['iv_pass'] as String,
            macPass: item['mac_pass'] as String,
          );
        }).toList();
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal sinkronisasi data: $e')),
      );
    } finally {
      setState(() => _isFetching = false);
    }
  }

  void _showAddDialog() {
    setState(() {
      _selectedTitle = 'Google';
      _isCustomTitle = false;
      _customTitleController.clear();
      _userController.clear();
      _passController.clear();
    });

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Tambah Kredensial Baru', style: TextStyle(color: Color(0xFF1E3A8A), fontWeight: FontWeight.bold)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: _selectedTitle,
                  decoration: const InputDecoration(labelText: 'Pilih Layanan'),
                  items: _popularServices.map((service) {
                    return DropdownMenuItem(
                      value: service,
                      child: Text(service),
                    );
                  }).toList(),
                  onChanged: (val) {
                    setDialogState(() {
                      _selectedTitle = val!;
                      _isCustomTitle = val == 'Kustom (Custom)...';
                    });
                  },
                ),
                if (_isCustomTitle) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _customTitleController,
                    decoration: const InputDecoration(labelText: 'Nama Layanan Kustom'),
                  ),
                ],
                const SizedBox(height: 8),
                TextField(
                  controller: _userController,
                  decoration: const InputDecoration(labelText: 'Username / Email'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _passController,
                        decoration: const InputDecoration(labelText: 'Password'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () {
                        const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#%^&*';
                        final pass = List.generate(16, (index) => chars[(DateTime.now().microsecondsSinceEpoch + index) % chars.length]).join();
                        setDialogState(() {
                          _passController.text = pass;
                        });
                      },
                      child: const Text('Acak'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
            ElevatedButton(
              onPressed: _saveCredential,
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E3A8A), foregroundColor: Colors.white),
              child: const Text('Simpan & Sinkron'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveCredential() async {
    final title = _isCustomTitle ? _customTitleController.text.trim() : _selectedTitle;
    final user = _userController.text;
    final pass = _passController.text;

    if (title.isEmpty || user.isEmpty || pass.isEmpty) return;

    // 1. Enkripsi data di sisi klien
    final encUser = await _cryptoService.encrypt(user, widget.dataKey);
    final encPass = await _cryptoService.encrypt(pass, widget.dataKey);

    try {
      // 2. Kirim data terenkripsi ke database Supabase
      await supabase.from('passwords').insert({
        'user_id': supabase.auth.currentUser!.id,
        'title': title,
        'encrypted_user': encUser['ciphertext'],
        'iv_user': encUser['nonce'],
        'mac_user': encUser['mac'],
        'encrypted_pass': encPass['ciphertext'],
        'iv_pass': encPass['nonce'],
        'mac_pass': encPass['mac'],
      });

      _customTitleController.clear();
      _userController.clear();
      _passController.clear();
      
      if (mounted) Navigator.pop(context);
      _fetchPasswords(); // Segarkan daftar setelah menambah data
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal menyimpan: $e')),
      );
    }
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Password disalin ke clipboard!')),
    );
    Future.delayed(const Duration(seconds: 30), () {
      Clipboard.setData(const ClipboardData(text: ''));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vaulticor'),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Sinkronisasi Ulang',
            onPressed: _fetchPasswords,
          ),
          IconButton(
            icon: const Icon(Icons.lock_open),
            tooltip: 'Kunci Vault',
            onPressed: () async {
              await supabase.auth.signOut();
              if (mounted) {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (context) => const LoginPage()),
                );
              }
            },
          )
        ],
      ),
      body: _isFetching
          ? const Center(child: CircularProgressIndicator())
          : _credentialsList.isEmpty
              ? const Center(
                  child: Text(
                    'Brankas Anda masih kosong.',
                    style: TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _credentialsList.length,
                  itemBuilder: (context, index) {
                    final item = _credentialsList[index];

                    return FutureBuilder<Map<String, String>>(
                      future: () async {
                        final decUser = await _cryptoService.decrypt(
                          ciphertext: item.encryptedUser,
                          nonce: item.ivUser,
                          mac: item.macUser,
                          keyBytes: widget.dataKey,
                        );
                        final decPass = await _cryptoService.decrypt(
                          ciphertext: item.encryptedPass,
                          nonce: item.ivPass,
                          mac: item.macPass,
                          keyBytes: widget.dataKey,
                        );
                        return {'user': decUser, 'pass': decPass};
                      }(),
                      builder: (context, snapshot) {
                        if (!snapshot.hasData) {
                          return const Card(
                            margin: EdgeInsets.only(bottom: 12),
                            child: ListTile(title: Text('Mendekripsi data...')),
                          );
                        }

                        final data = snapshot.data!;
                        return Card(
                          elevation: 2,
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: const Color(0xFF1E3A8A),
                              foregroundColor: Colors.white,
                              child: Text(item.title[0].toUpperCase()),
                            ),
                            title: Text(item.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(data['user']!),
                                Text('••••••••', style: TextStyle(color: Colors.grey[600])),
                              ],
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.copy, color: Color(0xFF1E3A8A)),
                              onPressed: () => _copyToClipboard(data['pass']!),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddDialog,
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        child: const Icon(Icons.add),
      ),
    );
  }
}
