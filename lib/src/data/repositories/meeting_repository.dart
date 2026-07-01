import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../models/important_meeting.dart';

class MeetingRepository {
  static const _databaseName = 'snap_reminder.db';
  static const _databaseVersion = 1;
  static const _tableName = 'important_meetings';

  Database? _database;

  Future<List<ImportantMeeting>> loadUpcoming() async {
    final database = await _openDatabase();
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await database.query(
      _tableName,
      where: 'starts_at_millis >= ?',
      whereArgs: [now],
      orderBy: 'starts_at_millis ASC',
    );

    return rows.map(ImportantMeeting.fromMap).toList();
  }

  Future<ImportantMeeting?> findById(int id) async {
    final database = await _openDatabase();
    final rows = await database.query(
      _tableName,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return ImportantMeeting.fromMap(rows.first);
  }

  Future<int> save(ImportantMeeting meeting) async {
    final database = await _openDatabase();
    return database.insert(
      _tableName,
      meeting.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> delete(int id) async {
    final database = await _openDatabase();
    await database.delete(_tableName, where: 'id = ?', whereArgs: [id]);
  }

  Future<Database> _openDatabase() async {
    final existingDatabase = _database;
    if (existingDatabase != null) {
      return existingDatabase;
    }

    final databasePath = await getDatabasesPath();
    final database = await openDatabase(
      path.join(databasePath, _databaseName),
      version: _databaseVersion,
      onCreate: (database, version) async {
        await database.execute('''
          CREATE TABLE $_tableName (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            starts_at_millis INTEGER NOT NULL,
            reminder_offset_minutes INTEGER NOT NULL,
            source_image_path TEXT,
            created_at_millis INTEGER NOT NULL
          )
        ''');
      },
    );

    _database = database;
    return database;
  }
}
