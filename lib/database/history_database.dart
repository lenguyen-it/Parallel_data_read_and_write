import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:uuid/uuid.dart';

class HistoryDatabase {
  // 🔹 Singleton pattern
  HistoryDatabase._privateConstructor();
  static final HistoryDatabase instance = HistoryDatabase._privateConstructor();

  static Database? _database;

  // 🔹 Mở hoặc tạo DB
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('history_scans.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
    );
  }

  // 🔹 Tạo bảng
  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE history_scans (
        id_local TEXT PRIMARY KEY,
        barcode TEXT,
        timestamp_device INTEGER,
        status TEXT,
        last_error TEXT
      )
    ''');
  }

  // 🔹 Thêm bản ghi (cả RFID & Barcode dùng chung)
  Future<void> insertScan(
    String code, {
    String status = 'success',
    String? error,
  }) async {
    final db = await instance.database;
    await db.insert('history_scans', {
      'id_local': const Uuid().v4(),
      'barcode': code,
      'timestamp_device': DateTime.now().millisecondsSinceEpoch,
      'status': status,
      'last_error': error,
    });
  }

  // 🔹 Lấy tất cả lịch sử
  Future<List<Map<String, dynamic>>> getAllScans() async {
    final db = await instance.database;
    return await db.query('history_scans', orderBy: 'timestamp_device DESC');
  }

  // 🔹 Xoá toàn bộ lịch sử (nếu cần)
  Future<void> clearHistory() async {
    final db = await instance.database;
    await db.delete('history_scans');
  }

  // 🔹 Đóng DB
  Future<void> close() async {
    final db = await _database;
    if (db != null && db.isOpen) await db.close();
  }
}
