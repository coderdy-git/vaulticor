import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  final LocalAuthentication _localAuth = LocalAuthentication();
  bool _isLoading = false;
  bool _isRegisterMode = false;
  bool _canCheckBiometrics = false;

  @override
  void initState() {
    super.initState();
    _checkBiometricAvailability();
  }

  Future<void> _checkBiometricAvailability() async {
    try {
      final isAvailable = await _localAuth.canCheckBiometrics || await _localAuth.isDeviceSupported();
      setState(() => _canCheckBiometrics = isAvailable);
      if (isAvailable) {
        _autoBiometricLogin();
      }
    } catch (_) {}
  }

  // Auto Login menggunakan Biometrik jika kunci tersimpan
  Future<void> _autoBiometricLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final savedEmail = prefs.getString('bio_email');
    final savedKeyHex = prefs.getString('bio_key');

    if (savedEmail != null && savedKeyHex != null) {
      final didAuthenticate = await _localAuth.authenticate(
        localizedReason: 'Pindai sidik jari atau wajah untuk membuka Vaulticor',
      );

      if (didAuthenticate) {
        setState(() => _isLoading = true);
        try {
          final List<int> dkBytes = base64.decode(savedKeyHex);
          if (mounted) {
            _showToast('Buka brankas biometrik sukses!', isError: false);
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => DashboardPage(dataKey: dkBytes),
              ),
            );
          }
        } catch (e) {
          _showToast('Gagal memuat kunci biometrik: $e');
        } finally {
          setState(() => _isLoading = false);
        }
      }
    }
  }

  void _showToast(String msg, {bool isError = true}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red[800] : Colors.green[800],
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _handleAuth() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.length < 6) {
      _showToast('Email valid & Password minimal 6 karakter');
      return;
    }

    setState(() => _isLoading = true);

    try {
      if (_isRegisterMode) {
        // --- REGISTER MODE ---
        final saltBytes = List<int>.generate(16, (i) => (i + DateTime.now().millisecond) % 256);
        final saltHex = base64.encode(saltBytes);

        final mkBytes = await _cryptoService.deriveKey(password, saltBytes);
        final dkBytes = List<int>.generate(32, (i) => (i * 3 + DateTime.now().microsecond) % 256);
        final encDK = await _cryptoService.encrypt(base64.encode(dkBytes), mkBytes);

        final loginHashBytes = await _cryptoService.deriveKey(base64.encode(mkBytes), saltBytes);
        final loginHash = base64.encode(loginHashBytes);

        final authResponse = await supabase.auth.signUp(
          email: email,
          password: loginHash,
        );

        if (authResponse.user != null) {
          await supabase.from('profiles').insert({
            'id': authResponse.user!.id,
            'client_salt': saltHex,
            'encrypted_data_key': encDK['ciphertext'],
            'iv_dk': encDK['nonce'],
            'mac_dk': encDK['mac'],
            'encrypted_data_key_recovery': 'dummy_recovery_placeholder',
            'iv_dk_recovery': 'dummy_recovery_placeholder',
          });

          _showToast('Akun sukses dibuat! Silakan login.', isError: false);
          setState(() => _isRegisterMode = false);
        }
      } else {
        // --- LOGIN MODE ---
        final List<dynamic> profiles = await supabase
            .from('profiles')
            .select('client_salt, encrypted_data_key, iv_dk, mac_dk')
            .eq('id', (await _getUserIdByEmail(email)) ?? '');

        if (profiles.isEmpty) {
          throw Exception("Pengguna tidak terdaftar.");
        }

        final profile = profiles.first;
        final saltHex = profile['client_salt'] as String;
        final saltBytes = base64.decode(saltHex);

        final mkBytes = await _cryptoService.deriveKey(password, saltBytes);
        final loginHashBytes = await _cryptoService.deriveKey(base64.encode(mkBytes), saltBytes);
        final loginHash = base64.encode(loginHashBytes);

        final authResponse = await supabase.auth.signInWithPassword(
          email: email,
          password: loginHash,
        );

        if (authResponse.user != null) {
          final encDKCipher = profile['encrypted_data_key'] as String;
          final encDKIv = profile['iv_dk'] as String;
          final encDKMac = profile['mac_dk'] as String;

          final decryptedDKBase64 = await _cryptoService.decrypt(
            ciphertext: encDKCipher,
            nonce: encDKIv,
            mac: encDKMac,
            keyBytes: mkBytes,
          );
          final dkBytes = base64.decode(decryptedDKBase64);

          // Simpan kredensial biometrik untuk login cepat berikutnya
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('bio_email', email);
          await prefs.setString('bio_key', base64.encode(dkBytes));

          if (mounted) {
            _showToast('Login berhasil!', isError: false);
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
      _showToast('Autentikasi Gagal: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<String?> _getUserIdByEmail(String email) async {
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
              // Menggunakan icon app lock bawaan login
              const Icon(Icons.lock_person, size: 80, color: Color(0xFF1E3A8A)),
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
                      if (!_isRegisterMode && _canCheckBiometrics) ...[
                        const SizedBox(height: 16),
                        IconButton(
                          icon: const Icon(Icons.fingerprint, size: 48, color: Color(0xFF1E3A8A)),
                          onPressed: _autoBiometricLogin,
                        ),
                        const Text('Masuk dengan Biometrik', style: TextStyle(fontSize: 12, color: Colors.grey)),
                      ],
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
  String _selectedCategoryFilter = 'Semua';

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
      _showToast('Gagal sinkronisasi data: $e');
    } finally {
      setState(() => _isFetching = false);
    }
  }

  void _showToast(String msg, {bool isError = true}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red[800] : Colors.green[800],
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // Tampilan penambahan baru dari BAWAH (BottomSheet)
  void _showAddBottomSheet() {
    setState(() {
      _selectedTitle = 'Google';
      _isCustomTitle = false;
      _customTitleController.clear();
      _userController.clear();
      _passController.clear();
    });

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            top: 20,
            left: 20,
            right: 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Tambah Kredensial Baru',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A)),
                ),
                const SizedBox(height: 16),
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
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _saveCredential,
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E3A8A), foregroundColor: Colors.white),
                      child: const Text('Simpan & Sinkron'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _saveCredential() async {
    final title = _isCustomTitle ? _customTitleController.text.trim() : _selectedTitle;
    final user = _userController.text;
    final pass = _passController.text;

    if (title.isEmpty || user.isEmpty || pass.isEmpty) return;

    final encUser = await _cryptoService.encrypt(user, widget.dataKey);
    final encPass = await _cryptoService.encrypt(pass, widget.dataKey);

    try {
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
      
      if (mounted) {
        Navigator.pop(context);
        _showToast('Sukses menyimpan data ke cloud!', isError: false);
      }
      _fetchPasswords();
    } catch (e) {
      _showToast('Gagal menyimpan: $e');
    }
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    _showToast('Password disalin ke clipboard!', isError: false);
    Future.delayed(const Duration(seconds: 30), () {
      Clipboard.setData(const ClipboardData(text: ''));
    });
  }

  @override
  Widget build(BuildContext context) {
    // Ambil list unik kategori untuk filter di layar utama (kelompokkan per layanan)
    final categories = ['Semua', ..._credentialsList.map((c) => c.title).toSet()];

    final filteredList = _selectedCategoryFilter == 'Semua'
        ? _credentialsList
        : _credentialsList.where((c) => c.title == _selectedCategoryFilter).toList();

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
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('bio_key'); // hapus cache biometrik
              if (mounted) {
                _showToast('Brankas terkunci!', isError: false);
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
          : Column(
              children: [
                // Filter Kategori (Kelompokkan per layanan)
                Container(
                  height: 50,
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: categories.length,
                    itemBuilder: (context, index) {
                      final category = categories[index];
                      final isSelected = category == _selectedCategoryFilter;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8.0),
                        child: ChoiceChip(
                          label: Text(category),
                          selected: isSelected,
                          onSelected: (selected) {
                            setState(() {
                              _selectedCategoryFilter = category;
                            });
                          },
                          selectedColor: const Color(0xFF1E3A8A),
                          labelStyle: TextStyle(
                            color: isSelected ? Colors.white : Colors.black,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Expanded(
                  child: filteredList.isEmpty
                      ? const Center(
                          child: Text(
                            'Brankas Anda masih kosong.',
                            style: TextStyle(color: Colors.grey, fontSize: 16),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: filteredList.length,
                          itemBuilder: (context, index) {
                            final item = filteredList[index];

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
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddBottomSheet,
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        child: const Icon(Icons.add),
      ),
    );
  }
}
