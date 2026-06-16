import 'dart:convert';
import 'package:cryptography/cryptography.dart';

class CryptoService {
  final _aesGcm = AesGcm.with256bits();

  // Menurunkan kunci enkripsi dari Password Master menggunakan PBKDF2
  Future<List<int>> deriveKey(String masterPassword, List<int> salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac(Sha256()),
      iterations: 100000, // Iterasi KDF yang aman
      bits: 256,
    );

    final secretKey = SecretKey(utf8.encode(masterPassword));
    final derivedKey = await pbkdf2.deriveKey(
      secretKey: secretKey,
      nonce: salt,
    );

    return await derivedKey.extractBytes();
  }

  // Mengenkripsi teks biasa menggunakan AES-GCM
  Future<Map<String, String>> encrypt(String plaintext, List<int> keyBytes) async {
    final secretKey = SecretKey(keyBytes);
    final clearTextBytes = utf8.encode(plaintext);

    final secretBox = await _aesGcm.encrypt(
      clearTextBytes,
      secretKey: secretKey,
    );

    return {
      'ciphertext': base64.encode(secretBox.cipherText),
      'nonce': base64.encode(secretBox.nonce),
      'mac': base64.encode(secretBox.mac.bytes),
    };
  }

  // Mendekripsi ciphertext menggunakan AES-GCM
  Future<String> decrypt({
    required String ciphertext,
    required String nonce,
    required String mac,
    required List<int> keyBytes,
  }) async {
    final secretKey = SecretKey(keyBytes);
    
    final secretBox = SecretBox(
      base64.decode(ciphertext),
      nonce: base64.decode(nonce),
      mac: Mac(base64.decode(mac)),
    );

    final clearTextBytes = await _aesGcm.decrypt(
      secretBox,
      secretKey: secretKey,
    );

    return utf8.decode(clearTextBytes);
  }
}
