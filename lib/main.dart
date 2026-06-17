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

  String get displayTitle {
    if (title.contains('||')) {
      return title.split('||')[0].trim();
    }
    return title.trim();
  }

  String get credentialName {
    final parts = title.split('||');
    if (parts.length >= 3) {
      return parts[1].trim();
    }
    return displayTitle;
  }

  String get description {
    final parts = title.split('||');
    if (parts.length >= 3) {
      return parts[2].trim();
    } else if (parts.length == 2) {
      return parts[1].trim();
    }
    return '';
  }
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
      final isAvailable = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      setState(() => _canCheckBiometrics = isAvailable && isDeviceSupported);
      if (isAvailable && isDeviceSupported) {
        // Berikan delay sedikit agar proses inisialisasi state selesai
        Future.delayed(const Duration(milliseconds: 500), () {
          _autoBiometricLogin();
        });
      }
    } catch (_) {}
  }

  // Auto Login menggunakan Biometrik jika kunci tersimpan
  Future<void> _autoBiometricLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final savedEmail = prefs.getString('bio_email');
    final savedKeyHex = prefs.getString('bio_key');
    final savedLoginHash = prefs.getString('bio_login_hash');

    if (savedEmail != null && savedKeyHex != null && savedLoginHash != null) {
      try {
        final didAuthenticate = await _localAuth.authenticate(
          localizedReason: 'Pindai sidik jari atau wajah untuk membuka Vaulticor',
        );

        if (didAuthenticate) {
          setState(() => _isLoading = true);
          
          // Sign in ke Supabase agar session aktif sehingga RLS mengizinkan fetch data
          await supabase.auth.signInWithPassword(
            email: savedEmail,
            password: savedLoginHash,
          );

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
        }
      } catch (e) {
        _showToast('Gagal autentikasi biometrik: $e');
      } finally {
        if (mounted) {
          setState(() => _isLoading = false);
        }
      }
    } else {
      _showToast('Aktifkan biometrik dengan masuk menggunakan Password Master terlebih dahulu.', isError: true);
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
            'email': email,
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
        // Mencari profile langsung menggunakan email
        final List<dynamic> profiles = await supabase
            .from('profiles')
            .select('client_salt, encrypted_data_key, iv_dk, mac_dk')
            .eq('email', email);

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
          await prefs.setString('bio_login_hash', loginHash);

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
      final errorMsg = e.toString();
      if (errorMsg.contains('SecretBox') || errorMsg.contains('decryption') || errorMsg.contains('MAC')) {
        _showToast('Password Master yang Anda masukkan salah!');
      } else {
        _showToast('Autentikasi Gagal: $e');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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
                              child: Text(_isRegisterMode ? 'Daftar Vault' : 'Masuk',
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
                            : 'Belum punya akun? Daftar'),
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
  List<EncryptedCredential> _credentialsList = [];
  bool _isFetching = false;
  String _selectedCategoryFilter = 'Semua';

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


  @override
  Widget build(BuildContext context) {
    // Ambil list unik kategori untuk filter di layar utama (kelompokkan per layanan)
    final categories = ['Semua', ..._credentialsList.map((c) => c.displayTitle).toSet()];

    final filteredList = _selectedCategoryFilter == 'Semua'
        ? _credentialsList
        : _credentialsList.where((c) => c.displayTitle == _selectedCategoryFilter).toList();

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
            icon: const Icon(Icons.settings),
            tooltip: 'Pengaturan',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsPage()),
              );
            },
          )
        ],
      ),
      body: _isFetching
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Filter Kategori (Kelompokkan per layanan)
                Padding(
                  padding: const EdgeInsets.only(top: 16.0, bottom: 8.0),
                  child: SizedBox(
                    height: 38,
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 20.0),
                        itemCount: categories.length,
                        itemBuilder: (context, index) {
                          final category = categories[index];
                          final isSelected = category == _selectedCategoryFilter;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _selectedCategoryFilter = category;
                                });
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isSelected ? const Color(0xFF1E3A8A) : Colors.white,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: isSelected ? const Color(0xFF1E3A8A) : const Color(0xFFE2E8F0),
                                    width: 1.2,
                                  ),
                                  boxShadow: isSelected
                                      ? [
                                          BoxShadow(
                                            color: const Color(0xFF1E3A8A).withOpacity(0.2),
                                            blurRadius: 4,
                                            offset: const Offset(0, 2),
                                          )
                                        ]
                                      : null,
                                ),
                                child: Center(
                                  child: Text(
                                    category,
                                    style: TextStyle(
                                      color: isSelected ? Colors.white : const Color(0xFF64748B),
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
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
                      : Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8.0),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: const Color(0xFFE2E8F0), width: 1.5),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.grey.withOpacity(0.05),
                                  blurRadius: 8,
                                  offset: const Offset(0, 4),
                                )
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: SingleChildScrollView(
                                scrollDirection: Axis.vertical,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    // Table Header
                                    Container(
                                      color: const Color(0xFFF8FAFC),
                                      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                                      child: const Row(
                                        children: [
                                          Expanded(
                                            flex: 1,
                                            child: Text(
                                              'LAYANAN',
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: Color(0xFF475569),
                                                fontSize: 12,
                                                letterSpacing: 0.5,
                                              ),
                                            ),
                                          ),
                                          Expanded(
                                            flex: 1,
                                            child: Text(
                                              'USERNAME / EMAIL',
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: Color(0xFF475569),
                                                fontSize: 12,
                                                letterSpacing: 0.5,
                                              ),
                                            ),
                                          ),
                                          SizedBox(
                                            width: 80,
                                            child: Text(
                                              'AKSI',
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: Color(0xFF475569),
                                                fontSize: 12,
                                                letterSpacing: 0.5,
                                              ),
                                              textAlign: TextAlign.center,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const Divider(height: 1, color: Color(0xFFE2E8F0)),
                                    // Table Body
                                    ...filteredList.map((item) {
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
                                            return Container(
                                              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                                              decoration: BoxDecoration(
                                                border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
                                              ),
                                              child: const Text(
                                                'Mendekripsi data...',
                                                style: TextStyle(color: Colors.grey, fontSize: 13),
                                              ),
                                            );
                                          }

                                          final data = snapshot.data!;
                                          return PremiumTableRow(
                                            item: item,
                                            user: data['user']!,
                                            pass: data['pass']!,
                                            dataKey: widget.dataKey,
                                            onRefresh: _fetchPasswords,
                                          );
                                        },
                                      );
                                    }),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => AddCredentialPage(
                dataKey: widget.dataKey,
                credentialsList: _credentialsList,
                onSaveSuccess: _fetchPasswords,
              ),
            ),
          );
        },
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Kredensial', style: TextStyle(fontWeight: FontWeight.bold)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 4,
      ),
    );
  }
}

class PremiumTableRow extends StatefulWidget {
  final EncryptedCredential item;
  final String user;
  final String pass;
  final List<int> dataKey;
  final VoidCallback onRefresh;

  const PremiumTableRow({
    Key? key,
    required this.item,
    required this.user,
    required this.pass,
    required this.dataKey,
    required this.onRefresh,
  }) : super(key: key);

  @override
  State<PremiumTableRow> createState() => _PremiumTableRowState();
}

class _PremiumTableRowState extends State<PremiumTableRow> {
  Widget _getServiceLogo(String serviceName) {
    final name = serviceName.trim().toLowerCase();
    if (name.isEmpty) return _fallbackAvatar();

    // Pemetaan nama ke domain official masing-masing
    String domain;
    if (name.contains('bpjs kesehatan')) {
      domain = 'bpjs-kesehatan.go.id';
    } else if (name.contains('bpjs ketenagakerjaan') || name.contains('bpjs tenaga kerja')) {
      domain = 'bpjsketenagakerjaan.go.id';
    } else if (name == 'chatgpt' || name.contains('openai')) {
      domain = 'openai.com';
    } else if (name == 'twitter / x' || name == 'twitter' || name == 'x') {
      domain = 'x.com';
    } else if (name.contains('.')) {
      domain = name;
    } else {
      domain = '${name.replaceAll(' ', '')}.com';
    }

    return Image.network(
      'https://www.google.com/s2/favicons?sz=64&domain=$domain',
      width: 18,
      height: 18,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return _fallbackAvatar();
      },
      errorBuilder: (context, error, stackTrace) => _fallbackAvatar(),
    );
  }

  Widget _fallbackAvatar() {
    return Text(
      widget.item.displayTitle.isNotEmpty ? widget.item.displayTitle[0].toUpperCase() : 'V',
      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
    );
  }

  void _navigateToDetailPage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CredentialDetailPage(
          item: widget.item,
          user: widget.user,
          pass: widget.pass,
          dataKey: widget.dataKey,
          onRefresh: widget.onRefresh,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9))),
      ),
      child: InkWell(
        onTap: _navigateToDetailPage,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          child: Row(
            children: [
              // Layanan
              Expanded(
                flex: 1,
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: const Color(0xFF1E3A8A).withValues(alpha: 0.1),
                      foregroundColor: const Color(0xFF1E3A8A),
                      child: ClipOval(
                        child: Center(
                          child: _getServiceLogo(widget.item.displayTitle),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.item.displayTitle,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: Color(0xFF1E293B),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              // Username / Email
              Expanded(
                flex: 1,
                child: Text(
                  widget.user,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF475569)),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Aksi (Detail Button)
              SizedBox(
                width: 80,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E3A8A).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Detail',
                      style: TextStyle(
                        color: Color(0xFF1E3A8A),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
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

class PasswordHistoryEntry {
  final String password;
  final DateTime date;

  PasswordHistoryEntry({required this.password, required this.date});
}

class DecryptedPasswordData {
  final String currentPassword;
  final DateTime? lastChanged;
  final List<PasswordHistoryEntry> history;

  DecryptedPasswordData({
    required this.currentPassword,
    this.lastChanged,
    required this.history,
  });

  factory DecryptedPasswordData.parse(String decryptedText) {
    try {
      if (decryptedText.startsWith('{') && decryptedText.endsWith('}')) {
        final map = jsonDecode(decryptedText) as Map<String, dynamic>;
        final current = map['current'] as String;
        final lastChangedStr = map['last_changed'] as String?;
        final historyList = map['history'] as List<dynamic>? ?? [];

        final history = historyList.map((item) {
          final itemMap = item as Map<String, dynamic>;
          return PasswordHistoryEntry(
            password: itemMap['pass'] as String,
            date: DateTime.parse(itemMap['date'] as String),
          );
        }).toList();

        return DecryptedPasswordData(
          currentPassword: current,
          lastChanged: lastChangedStr != null ? DateTime.parse(lastChangedStr) : null,
          history: history,
        );
      }
    } catch (_) {}

    return DecryptedPasswordData(
      currentPassword: decryptedText,
      lastChanged: null,
      history: [],
    );
  }

  String toSerializedJson() {
    final historyJson = history.map((e) => {
      'pass': e.password,
      'date': e.date.toIso8601String(),
    }).toList();

    return jsonEncode({
      'current': currentPassword,
      'last_changed': lastChanged?.toIso8601String(),
      'history': historyJson,
    });
  }
}

class CredentialDetailPage extends StatefulWidget {
  final EncryptedCredential item;
  final String user;
  final String pass;
  final List<int> dataKey;
  final VoidCallback onRefresh;

  const CredentialDetailPage({
    Key? key,
    required this.item,
    required this.user,
    required this.pass,
    required this.dataKey,
    required this.onRefresh,
  }) : super(key: key);

  @override
  State<CredentialDetailPage> createState() => _CredentialDetailPageState();
}

class _CredentialDetailPageState extends State<CredentialDetailPage> {
  final _cryptoService = CryptoService();
  String _displayTitle = '';
  String _credentialName = '';
  String _description = '';
  late DecryptedPasswordData _passwordData;

  bool _isEditing = false;
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _isUserCopied = false;
  bool _isPassCopied = false;

  late TextEditingController _titleController;
  late TextEditingController _nameController;
  late TextEditingController _descController;

  final Map<int, bool> _historyObscured = {};
  final Map<int, bool> _historyCopied = {};

  @override
  void initState() {
    super.initState();
    _displayTitle = widget.item.displayTitle;
    _credentialName = widget.item.credentialName;
    _description = widget.item.description;
    _passwordData = DecryptedPasswordData.parse(widget.pass);

    _titleController = TextEditingController(text: _displayTitle);
    _nameController = TextEditingController(text: _credentialName);
    _descController = TextEditingController(text: _description);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  String _formatDateTime(DateTime dt) {
    final months = [
      'Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni',
      'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember'
    ];
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}, $hour:$minute';
  }

  Widget _getServiceLogo(String serviceName) {
    final name = serviceName.trim().toLowerCase();
    if (name.isEmpty) return _fallbackAvatar();

    String domain;
    if (name.contains('bpjs kesehatan')) {
      domain = 'bpjs-kesehatan.go.id';
    } else if (name.contains('bpjs ketenagakerjaan') || name.contains('bpjs tenaga kerja')) {
      domain = 'bpjsketenagakerjaan.go.id';
    } else if (name == 'chatgpt' || name.contains('openai')) {
      domain = 'openai.com';
    } else if (name == 'twitter / x' || name == 'twitter' || name == 'x') {
      domain = 'x.com';
    } else if (name.contains('.')) {
      domain = name;
    } else {
      domain = '${name.replaceAll(' ', '')}.com';
    }

    return Image.network(
      'https://www.google.com/s2/favicons?sz=64&domain=$domain',
      width: 36,
      height: 36,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return _fallbackAvatar();
      },
      errorBuilder: (context, error, stackTrace) => _fallbackAvatar(),
    );
  }

  Widget _fallbackAvatar() {
    return Text(
      _displayTitle.isNotEmpty ? _displayTitle[0].toUpperCase() : 'V',
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A)),
    );
  }

  Widget _buildSSOBadge(String ssoPass) {
    final provider = ssoPass.split(':').last;
    String label = 'Google SSO';
    Color bgColor = const Color(0xFFF1F5F9);
    Color textColor = const Color(0xFF334155);
    String domain = 'google.com';

    if (provider == 'github') {
      label = 'GitHub SSO';
      bgColor = const Color(0xFF1E293B);
      textColor = Colors.white;
      domain = 'github.com';
    } else if (provider == 'apple') {
      label = 'Apple SSO';
      bgColor = Colors.black;
      textColor = Colors.white;
      domain = 'apple.com';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: provider == 'google' ? Border.all(color: const Color(0xFFCBD5E1)) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipOval(
            child: Image.network(
              'https://www.google.com/s2/favicons?sz=64&domain=$domain',
              width: 14,
              height: 14,
              errorBuilder: (context, error, stackTrace) => const Icon(Icons.link, size: 14, color: Colors.grey),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: textColor,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
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

  Future<void> _saveChanges() async {
    final newTitle = _titleController.text.trim();
    final newName = _nameController.text.trim();
    final newDesc = _descController.text.trim();

    if (newTitle.isEmpty) {
      _showToast('Nama layanan tidak boleh kosong!');
      return;
    }

    final finalName = newName.isEmpty ? newTitle : newName;

    setState(() => _isLoading = true);

    try {
      final combinedTitle = "$newTitle || $finalName || $newDesc";
      await supabase
          .from('passwords')
          .update({'title': combinedTitle})
          .eq('id', widget.item.id);

      setState(() {
        _displayTitle = newTitle;
        _credentialName = finalName;
        _description = newDesc;
        _isEditing = false;
      });

      _showToast('Perubahan berhasil disimpan', isError: false);
      widget.onRefresh();
    } catch (e) {
      _showToast('Gagal menyimpan perubahan: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _showUpdatePasswordDialog() async {
    final newPassController = TextEditingController();
    bool obscureNewPass = true;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Perbarui Password', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A))),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Password lama Anda akan disimpan dengan aman di riwayat brankas akun ini.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: newPassController,
                    obscureText: obscureNewPass,
                    decoration: InputDecoration(
                      labelText: 'Password Baru',
                      prefixIcon: const Icon(Icons.lock_outline_rounded, color: Color(0xFF1E3A8A)),
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscureNewPass ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                          color: Colors.grey,
                        ),
                        onPressed: () {
                          setDialogState(() {
                            obscureNewPass = !obscureNewPass;
                          });
                        },
                      ),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Batal', style: TextStyle(color: Color(0xFF64748B))),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (newPassController.text.trim().isEmpty) {
                      _showToast('Password tidak boleh kosong!');
                      return;
                    }
                    Navigator.pop(context, true);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1E3A8A),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Perbarui'),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirm == true) {
      setState(() => _isLoading = true);
      try {
        final newPass = newPassController.text.trim();
        final oldPass = _passwordData.currentPassword;

        final updatedHistory = List<PasswordHistoryEntry>.from(_passwordData.history);
        updatedHistory.add(PasswordHistoryEntry(password: oldPass, date: DateTime.now()));

        final newData = DecryptedPasswordData(
          currentPassword: newPass,
          lastChanged: DateTime.now(),
          history: updatedHistory,
        );

        final encryptedData = await _cryptoService.encrypt(newData.toSerializedJson(), widget.dataKey);

        await supabase.from('passwords').update({
          'encrypted_pass': encryptedData['ciphertext'],
          'iv_pass': encryptedData['nonce'],
          'mac_pass': encryptedData['mac'],
        }).eq('id', widget.item.id);

        _showToast('Password berhasil diperbarui', isError: false);
        widget.onRefresh();

        setState(() {
          _passwordData = newData;
        });
      } catch (e) {
        _showToast('Gagal memperbarui password: $e');
      } finally {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _confirmDelete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus Kredensial?'),
        content: const Text(
          'Apakah Anda yakin ingin menghapus kredensial ini? Tindakan ini tidak dapat dibatalkan.',
          style: TextStyle(color: Color(0xFF475569)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal', style: TextStyle(color: Color(0xFF64748B))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() => _isLoading = true);
      try {
        await supabase.from('passwords').delete().eq('id', widget.item.id);
        _showToast('Kredensial berhasil dihapus', isError: false);
        widget.onRefresh();
        if (mounted) {
          Navigator.pop(context); // Kembali ke dashboard
        }
      } catch (e) {
        _showToast('Gagal menghapus kredensial: $e');
      } finally {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSSO = widget.pass.startsWith('SSO:');

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Ubah Kredensial' : 'Detail Kredensial'),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        actions: [
          if (!_isEditing)
            IconButton(
              icon: const Icon(Icons.edit_rounded),
              tooltip: 'Ubah Kredensial',
              onPressed: () {
                setState(() {
                  _titleController.text = _displayTitle;
                  _nameController.text = _credentialName;
                  _descController.text = _description;
                  _isEditing = true;
                });
              },
            )
          else ...[
            IconButton(
              icon: const Icon(Icons.close_rounded),
              tooltip: 'Batal',
              onPressed: () {
                setState(() {
                  _isEditing = false;
                });
              },
            ),
            IconButton(
              icon: const Icon(Icons.check_rounded),
              tooltip: 'Simpan',
              onPressed: _saveChanges,
            ),
          ]
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Service Icon & Header Card
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE2E8F0), width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.grey.withValues(alpha: 0.05),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 28,
                          backgroundColor: const Color(0xFF1E3A8A).withValues(alpha: 0.1),
                          child: ClipOval(
                            child: Center(
                              child: _getServiceLogo(_isEditing ? _titleController.text : _displayTitle),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _isEditing
                              ? Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    TextFormField(
                                      controller: _titleController,
                                      decoration: const InputDecoration(
                                        labelText: 'Layanan / Provider',
                                        hintText: 'Contoh: Netflix, Google',
                                        border: UnderlineInputBorder(),
                                      ),
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF1E293B),
                                      ),
                                      onChanged: (val) {
                                        setState(() {}); // refresh favicon preview
                                      },
                                    ),
                                    const SizedBox(height: 8),
                                    TextFormField(
                                      controller: _nameController,
                                      decoration: const InputDecoration(
                                        labelText: 'Nama Kredensial',
                                        hintText: 'Default mengikuti nama layanan',
                                        border: UnderlineInputBorder(),
                                      ),
                                      style: const TextStyle(
                                        fontSize: 14,
                                        color: Color(0xFF475569),
                                      ),
                                    ),
                                  ],
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _displayTitle,
                                      style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF1E293B),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _credentialName,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: Color(0xFF64748B),
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Username / Email Card
                  _buildSectionLabel('USERNAME / EMAIL'),
                  const SizedBox(height: 8),
                  _buildInfoCard(
                    child: Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            widget.user,
                            style: const TextStyle(
                              fontSize: 15,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            _isUserCopied ? Icons.check_circle_rounded : Icons.copy_rounded,
                            size: 20,
                            color: _isUserCopied ? Colors.green[700] : const Color(0xFF1E3A8A),
                          ),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: widget.user));
                            setState(() => _isUserCopied = true);
                            Future.delayed(const Duration(seconds: 2), () {
                              if (mounted) setState(() => _isUserCopied = false);
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Password Card
                  _buildSectionLabel('PASSWORD'),
                  const SizedBox(height: 8),
                  _buildInfoCard(
                    child: isSSO
                        ? Container(
                            alignment: Alignment.centerLeft,
                            child: _buildSSOBadge(widget.pass),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: SelectableText(
                                      _obscurePassword ? '••••••••' : _passwordData.currentPassword,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontFamily: _obscurePassword ? null : 'monospace',
                                        color: const Color(0xFF1E293B),
                                        letterSpacing: _obscurePassword ? 1.5 : 0.0,
                                      ),
                                    ),
                                  ),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: Icon(
                                          _obscurePassword
                                              ? Icons.visibility_off_outlined
                                              : Icons.visibility_outlined,
                                          size: 20,
                                          color: const Color(0xFF64748B),
                                        ),
                                        onPressed: () {
                                          setState(() {
                                            _obscurePassword = !_obscurePassword;
                                          });
                                        },
                                      ),
                                      IconButton(
                                        icon: Icon(
                                          _isPassCopied ? Icons.check_circle_rounded : Icons.copy_rounded,
                                          size: 20,
                                          color: _isPassCopied ? Colors.green[700] : const Color(0xFF1E3A8A),
                                        ),
                                        onPressed: () {
                                          Clipboard.setData(ClipboardData(text: _passwordData.currentPassword));
                                          setState(() => _isPassCopied = true);
                                          Future.delayed(const Duration(seconds: 2), () {
                                            if (mounted) setState(() => _isPassCopied = false);
                                          });
                                        },
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.sync_rounded, size: 20, color: Color(0xFF1E3A8A)),
                                        tooltip: 'Perbarui Password',
                                        onPressed: _showUpdatePasswordDialog,
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              if (_passwordData.lastChanged != null) ...[
                                const Divider(height: 16, color: Color(0xFFF1F5F9)),
                                Text(
                                  'Terakhir diubah: ${_formatDateTime(_passwordData.lastChanged!)}',
                                  style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontStyle: FontStyle.italic),
                                ),
                              ],
                            ],
                          ),
                  ),
                  const SizedBox(height: 20),

                  // Password History Card
                  if (!isSSO && _passwordData.history.isNotEmpty) ...[
                    _buildSectionLabel('RIWAYAT PASSWORD'),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE2E8F0), width: 1.5),
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _passwordData.history.length,
                        separatorBuilder: (context, index) => const Divider(height: 1, color: Color(0xFFE2E8F0)),
                        itemBuilder: (context, index) {
                          final revIndex = _passwordData.history.length - 1 - index;
                          final entry = _passwordData.history[revIndex];
                          final isObscured = _historyObscured[revIndex] ?? true;
                          final isCopied = _historyCopied[revIndex] ?? false;

                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      SelectableText(
                                        isObscured ? '••••••••' : entry.password,
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontFamily: isObscured ? null : 'monospace',
                                          color: const Color(0xFF475569),
                                          letterSpacing: isObscured ? 1.5 : 0.0,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _formatDateTime(entry.date),
                                        style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
                                      ),
                                    ],
                                  ),
                                ),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: Icon(
                                        isObscured ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                        size: 16,
                                        color: const Color(0xFF64748B),
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          _historyObscured[revIndex] = !isObscured;
                                        });
                                      },
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: Icon(
                                        isCopied ? Icons.check_circle_rounded : Icons.copy_rounded,
                                        size: 16,
                                        color: isCopied ? Colors.green[700] : const Color(0xFF1E3A8A),
                                      ),
                                      onPressed: () {
                                        Clipboard.setData(ClipboardData(text: entry.password));
                                        setState(() {
                                          _historyCopied[revIndex] = true;
                                        });
                                        Future.delayed(const Duration(seconds: 2), () {
                                          if (mounted) {
                                            setState(() {
                                              _historyCopied[revIndex] = false;
                                            });
                                          }
                                        });
                                      },
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],

                  // Description Card (Keterangan)
                  _buildSectionLabel('KETERANGAN / CATATAN'),
                  const SizedBox(height: 8),
                  _isEditing
                      ? Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFE2E8F0), width: 1.5),
                          ),
                          child: TextFormField(
                            controller: _descController,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              hintText: 'Tambahkan keterangan atau catatan mengenai akun ini...',
                              hintStyle: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                              border: InputBorder.none,
                            ),
                            style: const TextStyle(
                              fontSize: 14,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                        )
                      : _buildInfoCard(
                          child: Container(
                            width: double.infinity,
                            constraints: const BoxConstraints(minHeight: 60),
                            child: SelectableText(
                              _description.isNotEmpty
                                  ? _description
                                  : 'Tidak ada keterangan / catatan untuk akun ini.',
                              style: TextStyle(
                                fontSize: 14,
                                color: _description.isNotEmpty ? const Color(0xFF1E293B) : const Color(0xFF94A3B8),
                                fontStyle: _description.isNotEmpty ? FontStyle.normal : FontStyle.italic,
                              ),
                            ),
                          ),
                        ),

                  const SizedBox(height: 40),

                  // Delete Button
                  if (!_isEditing)
                    OutlinedButton.icon(
                      onPressed: _confirmDelete,
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      label: const Text('Hapus Kredensial', style: TextStyle(fontWeight: FontWeight.bold)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFDC2626),
                        side: const BorderSide(color: Color(0xFFFCA5A5)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    )
                  else
                    ElevatedButton.icon(
                      onPressed: _saveChanges,
                      icon: const Icon(Icons.save_rounded, size: 18),
                      label: const Text('Simpan Perubahan', style: TextStyle(fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1E3A8A),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 2,
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _buildSectionLabel(String label) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        color: Color(0xFF64748B),
        letterSpacing: 0.8,
      ),
    );
  }

  Widget _buildInfoCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1.5),
      ),
      child: child,
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({Key? key}) : super(key: key);

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _isBiometricEnabled = false;
  String _userEmail = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _userEmail = prefs.getString('bio_email') ?? supabase.auth.currentUser?.email ?? 'Tidak diketahui';
      _isBiometricEnabled = prefs.getString('bio_key') != null;
    });
  }

  Future<void> _toggleBiometrics(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    if (!enabled) {
      await prefs.remove('bio_email');
      await prefs.remove('bio_key');
      await prefs.remove('bio_login_hash');
      setState(() {
        _isBiometricEnabled = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Biometrik dinonaktifkan.'),
            backgroundColor: Colors.blueGrey,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Untuk mengaktifkan biometrik kembali, harap masuk menggunakan Password Master Anda.'),
            backgroundColor: Colors.amber,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pengaturan'),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Profil Kategori
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: const Color(0xFF1E3A8A).withOpacity(0.1),
                    child: const Icon(Icons.person, size: 32, color: Color(0xFF1E3A8A)),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Akun Aktif',
                          style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          _userEmail,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Security Settings Card
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.fingerprint, color: Color(0xFF1E3A8A)),
                  title: const Text('Login dengan Biometrik', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Gunakan sidik jari/wajah untuk masuk cepat'),
                  trailing: Switch(
                    value: _isBiometricEnabled,
                    activeTrackColor: const Color(0xFF1E3A8A).withOpacity(0.5),
                    activeColor: const Color(0xFF1E3A8A),
                    onChanged: _toggleBiometrics,
                  ),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.info_outline, color: Color(0xFF1E3A8A)),
                  title: const Text('Versi Aplikasi', style: TextStyle(fontWeight: FontWeight.w600)),
                  trailing: const Text('v1.2.2', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Action Buttons
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red[800],
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () async {
              await supabase.auth.signOut();
              if (!mounted) return;
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (context) => const LoginPage()),
                (route) => false,
              );
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Brankas berhasil dikunci dan keluar!'),
                  backgroundColor: Colors.green[800],
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline),
                SizedBox(width: 8),
                Text('Kunci Brankas & Keluar', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AddCredentialPage extends StatefulWidget {
  final List<int> dataKey;
  final List<EncryptedCredential> credentialsList;
  final VoidCallback onSaveSuccess;

  const AddCredentialPage({
    Key? key,
    required this.dataKey,
    required this.credentialsList,
    required this.onSaveSuccess,
  }) : super(key: key);

  @override
  State<AddCredentialPage> createState() => _AddCredentialPageState();
}

class _AddCredentialPageState extends State<AddCredentialPage> {
  final _cryptoService = CryptoService();
  int _currentStep = 1; // 1: Select Provider, 2: Fill Details
  String _selectedProvider = '';
  bool _isCustomProvider = false;
  bool _isLoading = false;

  final _customTitleController = TextEditingController();
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  final _searchController = TextEditingController();
  String _selectedLoginMethod = 'password';
  bool _obscurePassword = true;

  final List<String> _googleAccounts = [];
  final List<String> _githubAccounts = [];
  final List<String> _appleAccounts = [];

  String _searchQuery = '';
  String _selectedCategory = 'Semua';

  final List<String> _providerCategories = [
    'Semua',
    'Sosial Media',
    'Pemerintahan',
    'Kerja & Produktivitas',
    'Hiburan & Media',
    'Teknologi & Utama',
  ];

  final Map<String, String> _presetProvidersWithCategories = {
    'Google': 'Teknologi & Utama',
    'Apple': 'Teknologi & Utama',
    'GitHub': 'Teknologi & Utama',
    'Microsoft': 'Teknologi & Utama',
    'BPJS Kesehatan': 'Pemerintahan',
    'BPJS Ketenagakerjaan': 'Pemerintahan',
    'Netflix': 'Hiburan & Media',
    'Facebook': 'Sosial Media',
    'Spotify': 'Hiburan & Media',
    'Amazon': 'Hiburan & Media',
    'Steam': 'Hiburan & Media',
    'Discord': 'Sosial Media',
    'Twitter / X': 'Sosial Media',
    'Instagram': 'Sosial Media',
    'TikTok': 'Sosial Media',
    'LinkedIn': 'Sosial Media',
    'ChatGPT': 'Teknologi & Utama',
    'Adobe': 'Kerja & Produktivitas',
    'Zoom': 'Kerja & Produktivitas',
    'Slack': 'Kerja & Produktivitas',
  };

  @override
  void initState() {
    super.initState();
    _decryptExistingAccounts();
  }

  @override
  void dispose() {
    _customTitleController.dispose();
    _userController.dispose();
    _passController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _decryptExistingAccounts() async {
    setState(() => _isLoading = true);
    try {
      for (var item in widget.credentialsList) {
        final lowerTitle = item.title.toLowerCase();
        if (lowerTitle.contains('google') || lowerTitle.contains('github') || lowerTitle.contains('apple')) {
          final decryptedEmail = await _cryptoService.decrypt(
            ciphertext: item.encryptedUser,
            nonce: item.ivUser,
            mac: item.macUser,
            keyBytes: widget.dataKey,
          );
          if (decryptedEmail.isNotEmpty) {
            if (lowerTitle.contains('google') && !_googleAccounts.contains(decryptedEmail)) {
              _googleAccounts.add(decryptedEmail);
            } else if (lowerTitle.contains('github') && !_githubAccounts.contains(decryptedEmail)) {
              _githubAccounts.add(decryptedEmail);
            } else if (lowerTitle.contains('apple') && !_appleAccounts.contains(decryptedEmail)) {
              _appleAccounts.add(decryptedEmail);
            }
          }
        }
      }
    } catch (_) {}
    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  InputDecoration _buildInputDecoration({
    required String labelText,
    Widget? prefixIcon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: labelText,
      labelStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 14, fontWeight: FontWeight.w500),
      floatingLabelStyle: const TextStyle(color: Color(0xFF1E3A8A), fontWeight: FontWeight.bold),
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      contentPadding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 16.0),
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF1E3A8A), width: 2.0),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.red, width: 1.5),
      ),
    );
  }

  void _showSelectionModal<T>({
    required String title,
    required List<T> items,
    required T selectedItem,
    required Widget Function(T item) itemBuilder,
    required void Function(T item) onSelected,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 20, right: 20, top: 20, bottom: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.grey),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0xFFE2E8F0)),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: items.length,
                  separatorBuilder: (context, index) => const Divider(height: 1, color: Color(0xFFF1F5F9)),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final isSelected = item == selectedItem;
                    return InkWell(
                      onTap: () {
                        onSelected(item);
                        Navigator.pop(context);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        color: isSelected ? const Color(0xFF1E3A8A).withOpacity(0.04) : null,
                        child: Row(
                          children: [
                            Expanded(child: itemBuilder(item)),
                            if (isSelected)
                              const Icon(Icons.check_circle_rounded, color: Color(0xFF1E3A8A), size: 22),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _getProviderLogo(String providerName, {double size = 32}) {
    final name = providerName.trim().toLowerCase();
    if (name == 'kustom') {
      return Icon(Icons.add_circle_outline_rounded, size: size, color: const Color(0xFF1E3A8A));
    }

    // Pemetaan nama ke domain official masing-masing
    String domain;
    if (name.contains('bpjs kesehatan')) {
      domain = 'bpjs-kesehatan.go.id';
    } else if (name.contains('bpjs ketenagakerjaan') || name.contains('bpjs tenaga kerja')) {
      domain = 'bpjsketenagakerjaan.go.id';
    } else if (name == 'chatgpt' || name.contains('openai')) {
      domain = 'openai.com';
    } else if (name == 'twitter / x' || name == 'twitter' || name == 'x') {
      domain = 'x.com';
    } else if (name.contains('.')) {
      domain = name;
    } else {
      domain = '${name.replaceAll(' ', '')}.com';
    }

    return ClipOval(
      child: Image.network(
        'https://www.google.com/s2/favicons?sz=64&domain=$domain',
        width: size,
        height: size,
        errorBuilder: (context, error, stackTrace) => Icon(Icons.public_rounded, size: size, color: Colors.grey),
      ),
    );
  }

  Future<void> _saveCredential() async {
    final title = _isCustomProvider ? _customTitleController.text.trim() : _selectedProvider;
    final user = _userController.text;
    String pass = _passController.text;

    if (title.isEmpty || user.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nama layanan & Username tidak boleh kosong!'), backgroundColor: Colors.red),
      );
      return;
    }

    if (_selectedLoginMethod == 'password' && pass.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password tidak boleh kosong!'), backgroundColor: Colors.red),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      if (_selectedLoginMethod == 'google_sso') pass = 'SSO:google';
      if (_selectedLoginMethod == 'github_sso') pass = 'SSO:github';
      if (_selectedLoginMethod == 'apple_sso') pass = 'SSO:apple';

      final encUser = await _cryptoService.encrypt(user, widget.dataKey);
      final encPass = await _cryptoService.encrypt(pass, widget.dataKey);

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

      widget.onSaveSuccess();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sukses menyimpan $title!'),
            backgroundColor: Colors.green[800],
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal menyimpan: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentStep == 1 ? 'Pilih Layanan' : 'Isi Kredensial'),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_currentStep == 2) {
              setState(() {
                _currentStep = 1;
              });
            } else {
              Navigator.pop(context);
            }
          },
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _currentStep == 1
              ? _buildProviderGrid()
              : _buildFillDetailsForm(),
    );
  }

  Widget _buildProviderGrid() {
    final filteredPreset = _presetProvidersWithCategories.keys.where((provider) {
      // Filter kategori
      final matchesCategory = _selectedCategory == 'Semua' ||
          _presetProvidersWithCategories[provider] == _selectedCategory;
      // Filter pencarian
      final matchesSearch = provider.toLowerCase().contains(_searchQuery.toLowerCase());
      return matchesCategory && matchesSearch;
    }).toList();

    final allProviders = [...filteredPreset, 'Kustom'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Input Pencarian
        Padding(
          padding: const EdgeInsets.only(left: 20.0, right: 20.0, top: 16.0, bottom: 8.0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Cari layanan...',
              hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
              prefixIcon: const Icon(Icons.search, color: Color(0xFF1E3A8A)),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: Colors.grey),
                      onPressed: () {
                        setState(() {
                          _searchController.clear();
                          _searchQuery = '';
                        });
                      },
                    )
                  : null,
              contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF1E3A8A), width: 2.0),
              ),
            ),
            onChanged: (value) {
              setState(() {
                _searchQuery = value;
              });
            },
          ),
        ),
        // Kategori filter horizontal
        Padding(
          padding: const EdgeInsets.only(bottom: 12.0),
          child: SizedBox(
            height: 38,
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20.0),
                itemCount: _providerCategories.length,
                itemBuilder: (context, index) {
                  final category = _providerCategories[index];
                  final isSelected = _selectedCategory == category;
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _selectedCategory = category;
                      });
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.only(right: 8.0),
                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                      decoration: BoxDecoration(
                        color: isSelected ? const Color(0xFF1E3A8A) : Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isSelected ? const Color(0xFF1E3A8A) : const Color(0xFFE2E8F0),
                          width: 1.2,
                        ),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: const Color(0xFF1E3A8A).withOpacity(0.2),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                )
                              ]
                            : null,
                      ),
                      child: Center(
                        child: Text(
                          category,
                          style: TextStyle(
                            color: isSelected ? Colors.white : const Color(0xFF64748B),
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        // Grid Layanan
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.only(left: 20, right: 20, top: 16, bottom: 20),
            clipBehavior: Clip.hardEdge,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 0.95,
              crossAxisSpacing: 14,
              mainAxisSpacing: 14,
            ),
            itemCount: allProviders.length,
            itemBuilder: (context, index) {
              final provider = allProviders[index];
              return Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE2E8F0), width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.grey.withOpacity(0.05),
                      blurRadius: 6,
                      offset: const Offset(0, 3),
                    )
                  ],
                ),
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        _selectedProvider = provider;
                        _isCustomProvider = provider == 'Kustom';
                        _currentStep = 2;
                        _selectedLoginMethod = 'password';
                        _userController.clear();
                        _passController.clear();
                      });
                    },
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _getProviderLogo(provider, size: 36),
                        const SizedBox(height: 10),
                        Text(
                          provider,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Color(0xFF334155)),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildFillDetailsForm() {
    final displayTitle = _isCustomProvider ? 'Layanan Kustom' : _selectedProvider;
    final serviceLower = (_isCustomProvider ? _customTitleController.text : _selectedProvider).toLowerCase();

    final isPrimaryService = serviceLower.contains('google') ||
                             serviceLower.contains('apple') ||
                             serviceLower.contains('microsoft');

    final loginMethods = <DropdownMenuItem<String>>[
      const DropdownMenuItem(
        value: 'password',
        child: Row(
          children: [
            Icon(Icons.lock_outline_rounded, color: Color(0xFF64748B), size: 20),
            SizedBox(width: 10),
            Text('Password Standar', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    ];
    if (!isPrimaryService) {
      loginMethods.add(
        DropdownMenuItem(
          value: 'google_sso',
          child: Row(
            children: [
              ClipOval(
                child: Image.network(
                  'https://www.google.com/s2/favicons?sz=32&domain=google.com',
                  width: 20,
                  height: 20,
                  errorBuilder: (ctx, err, st) => const Icon(Icons.g_mobiledata_rounded, color: Colors.blue),
                ),
              ),
              const SizedBox(width: 10),
              const Text('Masuk dengan Google (SSO)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      );
      loginMethods.add(
        DropdownMenuItem(
          value: 'github_sso',
          child: Row(
            children: [
              ClipOval(
                child: Image.network(
                  'https://www.google.com/s2/favicons?sz=32&domain=github.com',
                  width: 20,
                  height: 20,
                  errorBuilder: (ctx, err, st) => const Icon(Icons.code_rounded, color: Colors.black),
                ),
              ),
              const SizedBox(width: 10),
              const Text('Masuk dengan GitHub (SSO)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      );
      loginMethods.add(
        DropdownMenuItem(
          value: 'apple_sso',
          child: Row(
            children: [
              ClipOval(
                child: Image.network(
                  'https://www.google.com/s2/favicons?sz=32&domain=apple.com',
                  width: 20,
                  height: 20,
                  errorBuilder: (ctx, err, st) => const Icon(Icons.apple_rounded, color: Colors.black),
                ),
              ),
              const SizedBox(width: 10),
              const Text('Masuk dengan Apple (SSO)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      );
    }

    if (!loginMethods.any((item) => item.value == _selectedLoginMethod)) {
      _selectedLoginMethod = 'password';
    }

    List<String> linkedAccounts = [];
    String ssoProviderName = '';
    if (_selectedLoginMethod == 'google_sso') {
      linkedAccounts = _googleAccounts;
      ssoProviderName = 'Google';
    } else if (_selectedLoginMethod == 'github_sso') {
      linkedAccounts = _githubAccounts;
      ssoProviderName = 'GitHub';
    } else if (_selectedLoginMethod == 'apple_sso') {
      linkedAccounts = _appleAccounts;
      ssoProviderName = 'Apple';
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Column(
              children: [
                CircleAvatar(
                  radius: 36,
                  backgroundColor: const Color(0xFF1E3A8A).withOpacity(0.08),
                  child: _getProviderLogo(_selectedProvider, size: 48),
                ),
                const SizedBox(height: 12),
                Text(
                  displayTitle,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          if (_isCustomProvider) ...[
            TextField(
              controller: _customTitleController,
              decoration: _buildInputDecoration(
                labelText: 'Nama Layanan Kustom',
                prefixIcon: const Icon(Icons.business_rounded, color: Color(0xFF1E3A8A)),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
          ],
          GestureDetector(
            onTap: () {
              _showSelectionModal<String>(
                title: 'Pilih Metode Login',
                items: ['password', if (!isPrimaryService) ...['google_sso', 'github_sso', 'apple_sso']],
                selectedItem: _selectedLoginMethod,
                itemBuilder: (item) {
                  if (item == 'password') {
                    return const Row(
                      children: [
                        Icon(Icons.lock_outline_rounded, color: Color(0xFF64748B), size: 20),
                        SizedBox(width: 12),
                        Text('Password Standar', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                      ],
                    );
                  }
                  String ssoName = '';
                  String domain = '';
                  IconData fallbackIcon = Icons.g_mobiledata_rounded;
                  Color fallbackColor = Colors.blue;
                  if (item == 'google_sso') {
                    ssoName = 'Google';
                    domain = 'google.com';
                    fallbackIcon = Icons.g_mobiledata_rounded;
                    fallbackColor = Colors.blue;
                  } else if (item == 'github_sso') {
                    ssoName = 'GitHub';
                    domain = 'github.com';
                    fallbackIcon = Icons.code_rounded;
                    fallbackColor = Colors.black;
                  } else if (item == 'apple_sso') {
                    ssoName = 'Apple';
                    domain = 'apple.com';
                    fallbackIcon = Icons.apple_rounded;
                    fallbackColor = Colors.black;
                  }
                  return Row(
                    children: [
                      ClipOval(
                        child: Image.network(
                          'https://www.google.com/s2/favicons?sz=32&domain=$domain',
                          width: 20,
                          height: 20,
                          errorBuilder: (ctx, err, st) => Icon(fallbackIcon, color: fallbackColor),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text('Masuk dengan $ssoName (SSO)', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    ],
                  );
                },
                onSelected: (val) {
                  setState(() {
                    _selectedLoginMethod = val;
                    _userController.clear();
                  });
                },
              );
            },
            child: AbsorbPointer(
              child: TextField(
                controller: TextEditingController(
                  text: _selectedLoginMethod == 'password'
                      ? 'Password Standar'
                      : _selectedLoginMethod == 'google_sso'
                          ? 'Masuk dengan Google (SSO)'
                          : _selectedLoginMethod == 'github_sso'
                              ? 'Masuk dengan GitHub (SSO)'
                              : 'Masuk dengan Apple (SSO)',
                ),
                decoration: _buildInputDecoration(
                  labelText: 'Metode Login',
                  prefixIcon: const Icon(Icons.login_rounded, color: Color(0xFF1E3A8A)),
                  suffixIcon: const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF1E3A8A)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_selectedLoginMethod == 'password') ...[
            TextField(
              controller: _userController,
              decoration: _buildInputDecoration(
                labelText: 'Username / Email',
                prefixIcon: const Icon(Icons.person_outline_rounded, color: Color(0xFF1E3A8A)),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passController,
              obscureText: _obscurePassword,
              decoration: _buildInputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline_rounded, color: Color(0xFF1E3A8A)),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    color: Colors.grey,
                  ),
                  onPressed: () {
                    setState(() {
                      _obscurePassword = !_obscurePassword;
                    });
                  },
                ),
              ),
            ),
          ] else ...[
            if (linkedAccounts.isNotEmpty) ...[
              GestureDetector(
                onTap: () {
                  _showSelectionModal<String>(
                    title: 'Pilih Akun $ssoProviderName',
                    items: linkedAccounts,
                    selectedItem: _userController.text.isEmpty ? linkedAccounts.first : _userController.text,
                    itemBuilder: (item) {
                      return Row(
                        children: [
                          const Icon(Icons.alternate_email_rounded, color: Color(0xFF64748B), size: 18),
                          const SizedBox(width: 12),
                          Text(item, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                        ],
                      );
                    },
                    onSelected: (val) {
                      setState(() {
                        _userController.text = val;
                      });
                    },
                  );
                },
                child: AbsorbPointer(
                  child: TextField(
                    controller: TextEditingController(
                      text: _userController.text.isEmpty ? linkedAccounts.first : _userController.text,
                    ),
                    decoration: _buildInputDecoration(
                      labelText: 'Pilih Akun $ssoProviderName yang Ditautkan',
                      prefixIcon: const Icon(Icons.account_circle_rounded, color: Color(0xFF1E3A8A)),
                      suffixIcon: const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF1E3A8A)),
                    ).copyWith(
                      helperText: 'Hubungkan dengan identitas utama Anda.',
                      helperStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                    ),
                  ),
                ),
              ),
            ] else ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.amber[50],
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.amber[200]!),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.amber[800]),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Belum ada akun $ssoProviderName utama yang tersimpan. Harap simpan akun $ssoProviderName Anda terlebih dahulu di Vaulticor.',
                        style: TextStyle(color: Colors.amber[900], fontSize: 13, height: 1.3),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: (_selectedLoginMethod != 'password' && linkedAccounts.isEmpty)
                ? null
                : () {
                    if (_selectedLoginMethod != 'password' && _userController.text.isEmpty) {
                      _userController.text = linkedAccounts.first;
                    }
                    _saveCredential();
                  },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1E3A8A),
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 2,
              shadowColor: const Color(0xFF1E3A8A).withOpacity(0.3),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.save_rounded),
                SizedBox(width: 8),
                Text('Simpan & Sinkron', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
