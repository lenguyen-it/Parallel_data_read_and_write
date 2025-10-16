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

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE history_scans (
        id_local TEXT PRIMARY KEY,
        barcode TEXT,
        timestamp_device INTEGER,
        status TEXT,
        sync INTEGER DEFAULT 0,
        last_error TEXT,
        scan_duration_ms REAL,
        sync_duration_ms REAL,
        created_at INTEGER,
        updated_at INTEGER
      )
    ''');
  }

  final _uuid = const Uuid();

  /// ------------------ INSERT SINGLE ------------------
  Future<String> insertScan(
    String code, {
    String status = 'pending',
    String? error,
    double? scanDurationMs,
  }) async {
    final db = await instance.database;
    final id = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.insert('history_scans', {
      'id_local': id,
      'barcode': code,
      'timestamp_device': now,
      'status': status,
      'last_error': error,
      'sync': 0,
      'scan_duration_ms': scanDurationMs,
      'created_at': now,
      'updated_at': now,
    });

    return id;
  }

  /// ------------------ BATCH INSERT ------------------
  Future<List<String>> batchInsertScans(
    List<Map<String, dynamic>> scans, {
    String status = 'pending',
  }) async {
    if (scans.isEmpty) return [];

    final db = await instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final ids = <String>[];

    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var scan in scans) {
        final id = _uuid.v4();
        ids.add(id);
        batch.insert('history_scans', {
          'id_local': id,
          'barcode': scan['barcode'] ?? '',
          'timestamp_device': now,
          'status': status,
          'last_error': scan['last_error'],
          'sync': 0,
          'scan_duration_ms': scan['scan_duration_ms'],
          'created_at': now,
          'updated_at': now,
        });
      }
      await batch.commit(noResult: true);
    });

    return ids;
  }

  /// ------------------ UPDATE STATUS ------------------
  Future<void> updateStatusById(
    String idLocal,
    String status, {
    double? syncDurationMs,
  }) async {
    final db = await instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    final updateData = <String, dynamic>{
      'status': status,
      'updated_at': now,
    };
    if (syncDurationMs != null) {
      updateData['sync_duration_ms'] = syncDurationMs;
    }

    await db.update(
      'history_scans',
      updateData,
      where: 'id_local = ?',
      whereArgs: [idLocal],
    );
  }

  /// ------------------ GETTERS ------------------
  Future<List<Map<String, dynamic>>> getPendingScans() async {
    final db = await instance.database;
    return await db.query(
      'history_scans',
      where: 'status = ?',
      whereArgs: ['pending'],
      orderBy: 'timestamp_device ASC',
    );
  }

  Future<List<Map<String, dynamic>>> getAllScans() async {
    final db = await instance.database;
    return await db.query(
      'history_scans',
      orderBy: 'timestamp_device DESC',
    );
  }

  /// ------------------ CLEAR & CLOSE ------------------
  Future<void> clearHistory() async {
    final db = await instance.database;
    await db.delete('history_scans');
  }

  Future<void> close() async {
    final db = _database;
    if (db != null && db.isOpen) {
      await db.close();
    }
  }
}
