import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:uuid/uuid.dart';

class HistoryDatabase {
  HistoryDatabase._privateConstructor();
  static final HistoryDatabase instance = HistoryDatabase._privateConstructor();

  static Database? _database;

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

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE history_scans (
        id_local TEXT PRIMARY KEY,
        barcode TEXT,
        timestamp_device INTEGER,
        status TEXT,
        sync INTEGER DEFAULT 0,
        last_error TEXT
      )
    ''');
  }

  Future<String> insertScan(
    String code, {
    String status = 'pending',
    String? error,
  }) async {
    final db = await instance.database;
    final id = const Uuid().v4();

    await db.insert('history_scans', {
      'id_local': id,
      'barcode': code,
      'timestamp_device': DateTime.now().millisecondsSinceEpoch,
      'status': status,
      'last_error': error,
    });

    return id;
  }

  Future<void> updateStatusById(String idLocal, String status) async {
    final db = await instance.database;
    await db.update(
      'history_scans',
      {'status': status},
      where: 'id_local = ?',
      whereArgs: [idLocal],
    );
  }

  Future<void> updateSync(String idLocal, bool sync) async {
    final db = await instance.database;
    await db.update(
      'history_scans',
      {'sync': sync ? 1 : 0},
      where: 'id_local = ?',
      whereArgs: [idLocal],
    );
  }

  Future<List<Map<String, dynamic>>> getPendingScans() async {
    final db = await instance.database;
    return await db.query(
      'history_scans',
      where: 'status = ?',
      whereArgs: ['pending'],
    );
  }

  Future<List<Map<String, dynamic>>> getAllScans() async {
    final db = await instance.database;
    return await db.query('history_scans', orderBy: 'timestamp_device DESC');
  }

  Future<void> clearHistory() async {
    final db = await instance.database;
    await db.delete('history_scans');
  }

  Future<void> close() async {
    final db = _database;
    if (db != null && db.isOpen) await db.close();
  }
}
