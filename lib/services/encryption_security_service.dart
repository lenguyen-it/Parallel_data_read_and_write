import 'dart:convert';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class EncryptionSecurityService {
  static final EncryptionSecurityService _instance =
      EncryptionSecurityService._internal();

  EncryptionSecurityService._internal();

  final _secureStorage = const FlutterSecureStorage();

  factory EncryptionSecurityService() {
    return _instance;
  }

  static const String _keyStorageKey = 'encryption_key';
  static const String _ivStorageKey = 'encryption_iv';

  encrypt.Key? _key;
  encrypt.IV? _iv;

  bool get isInitialized => _key != null && _iv != null;

  /// Khởi tạo mã hóa
  Future<void> initializeEncryption() async {
    String? keyString = await _secureStorage.read(key: _keyStorageKey);
    String? ivString = await _secureStorage.read(key: _ivStorageKey);

    if (keyString != null && ivString != null) {
      _key = encrypt.Key.fromBase64(keyString);
      _iv = encrypt.IV.fromBase64(ivString);
    } else {
      // AES-256
      _key = encrypt.Key.fromSecureRandom(32);
      // 128-bit IV
      _iv = encrypt.IV.fromSecureRandom(16);

      await _secureStorage.write(
        key: _keyStorageKey,
        value: _key!.base64,
      );
      await _secureStorage.write(
        key: _ivStorageKey,
        value: _iv!.base64,
      );
    }
  }

  /// Mã hóa chuỗi text
  String encryptData(String plainText) {
    if (_key == null || _iv == null) {
      throw Exception(
          "Key chưa được khởi tạo. Gọi initializeEncryption() trước.");
    }

    final encrypter =
        encrypt.Encrypter(encrypt.AES(_key!, mode: encrypt.AESMode.cbc));

    final encrypted = encrypter.encrypt(plainText, iv: _iv);
    return encrypted.base64;
  }

  /// Giải mã chuỗi text
  String decryptData(String encryptedText) {
    if (_key == null || _iv == null) {
      throw Exception("Key chưa được khởi tạo");
    }

    final encrypter =
        encrypt.Encrypter(encrypt.AES(_key!, mode: encrypt.AESMode.cbc));

    final decrypted = encrypter.decrypt(
      encrypt.Encrypted.fromBase64(encryptedText),
      iv: _iv,
    );

    return decrypted;
  }

  /// Mã hóa dữ liệu JSON
  String encryptJson(Map<String, dynamic> jsonData) {
    final jsonString = jsonEncode(jsonData);
    return encryptData(jsonString);
  }

  /// Giải mã dữ liệu JSON
  Map<String, dynamic> decryptJson(String encryptedData) {
    final jsonString = decryptData(encryptedData);
    return jsonDecode(jsonString);
  }

  /// Mã hóa List (cho CSV hoặc array)
  String encryptList(List<dynamic> listData) {
    final jsonString = jsonEncode(listData);
    return encryptData(jsonString);
  }

  /// Giải mã List
  List<dynamic> decryptList(String encryptedData) {
    final jsonString = decryptData(encryptedData);
    return jsonDecode(jsonString);
  }

  /// Reset key và iv (xóa dữ liệu cũ)
  Future<void> resetKey() async {
    await _secureStorage.delete(key: _keyStorageKey);
    await _secureStorage.delete(key: _ivStorageKey);
    _key = null;
    _iv = null;
    await initializeEncryption();
  }

  /// Xóa toàn bộ keys
  Future<void> clearKeys() async {
    await _secureStorage.delete(key: _keyStorageKey);
    await _secureStorage.delete(key: _ivStorageKey);
    _key = null;
    _iv = null;
  }
}
