import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart' as sqlite;

import '../core/contracts.dart';
import 'route_cache.dart';

/// 家庭地点、上次路线摘要与进行中行程只存本机；当前定位不进入此数据库。
class LocalPlaceRepository extends PlaceRepository
    implements RouteCache, TripStore {
  LocalPlaceRepository({
    sqlite.DatabaseFactory? databaseFactory,
    this.databasePath,
  }) : _factory = databaseFactory ?? sqlite.databaseFactory;

  final sqlite.DatabaseFactory _factory;
  final String? databasePath;
  sqlite.Database? _database;
  Future<void>? _initializing;
  List<SavedPlace> _places = const [];
  Map<String, String> _settings = const {};

  @override
  List<SavedPlace> get places => _places;

  @override
  bool get privacyAccepted => _settings['privacyAccepted'] == '1';

  @override
  bool get hasPin => _settings.containsKey('pinHash');

  @override
  Future<void> initialize() => _initializing ??= _open();

  Future<void> _open() async {
    try {
      final location =
          databasePath ??
          path.join(await _factory.getDatabasesPath(), 'seniornav.db');
      _database = await _factory.openDatabase(
        location,
        options: sqlite.OpenDatabaseOptions(
          version: 3,
          onCreate: (db, version) async {
            await db.execute('''
              CREATE TABLE places (
                id TEXT PRIMARY KEY,
                slot INTEGER NOT NULL CHECK (slot BETWEEN 0 AND 4),
                label TEXT NOT NULL,
                icon TEXT NOT NULL,
                name TEXT NOT NULL,
                address TEXT NOT NULL,
                city TEXT NOT NULL,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                coordSystem TEXT NOT NULL CHECK (coordSystem = 'BD-09'),
                poiUid TEXT NOT NULL,
                updatedAt INTEGER NOT NULL,
                verifiedAt INTEGER NOT NULL,
                sortOrder INTEGER NOT NULL DEFAULT 0,
                rev INTEGER NOT NULL DEFAULT 1,
                deletedAt INTEGER
              )
            ''');
            await db.execute('''
              CREATE UNIQUE INDEX active_home_slot ON places(slot)
              WHERE slot > 0 AND deletedAt IS NULL
            ''');
            await db.execute('''
              CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)
            ''');
            await _createRouteCache(db);
            await _createActiveTrip(db);
          },
          onUpgrade: (db, oldVersion, newVersion) async {
            if (oldVersion < 2) await _createRouteCache(db);
            if (oldVersion < 3) await _createActiveTrip(db);
          },
        ),
      );
      await _reload();
    } catch (_) {
      _initializing = null;
      throw const AppFailure('地点资料暂时无法打开，请退出后重新打开应用');
    }
  }

  sqlite.Database get _db {
    final value = _database;
    if (value == null) throw const AppFailure('地点资料尚未准备好');
    return value;
  }

  static Future<void> _createRouteCache(sqlite.DatabaseExecutor db) =>
      db.execute('''
        CREATE TABLE route_cache (
          placeId TEXT PRIMARY KEY,
          bundle TEXT NOT NULL
        )
      ''');

  static Future<void> _createActiveTrip(sqlite.DatabaseExecutor db) =>
      db.execute('''
        CREATE TABLE active_trip (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          placeId TEXT NOT NULL,
          bundle TEXT NOT NULL,
          startedAt INTEGER NOT NULL
        )
      ''');

  @override
  Future<ActiveTrip?> readTrip() async {
    try {
      await initialize();
      final rows = await _db.query('active_trip', where: 'id = 1');
      if (rows.isEmpty) return null;
      final bundle = decodeRouteBundle(rows.first['bundle'] as String);
      if (bundle == null) return null;
      return ActiveTrip(
        placeId: rows.first['placeId'] as String,
        bundle: bundle,
        startedAt: DateTime.fromMillisecondsSinceEpoch(
          rows.first['startedAt'] as int,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> startTrip(
    String placeId,
    RouteBundle bundle, {
    DateTime? startedAt,
  }) async {
    try {
      await initialize();
      await _db.insert('active_trip', {
        'id': 1,
        'placeId': placeId,
        'bundle': encodeRouteBundle(bundle),
        'startedAt':
            (startedAt ?? DateTime.now()).millisecondsSinceEpoch,
      }, conflictAlgorithm: sqlite.ConflictAlgorithm.replace);
    } catch (_) {
      throw const AppFailure('行程没有保存成功，请稍后再试');
    }
  }

  @override
  Future<void> endTrip() async {
    try {
      await initialize();
      await _db.delete('active_trip');
    } catch (_) {
      throw const AppFailure('行程没有结束成功，请稍后再试');
    }
  }

  @override
  Future<void> save(String placeId, RouteBundle bundle) async {
    // 缓存是兜底：写不进去也不能影响刚查到的路线展示。
    try {
      await initialize();
      await _db.insert('route_cache', {
        'placeId': placeId,
        'bundle': encodeRouteBundle(bundle),
      }, conflictAlgorithm: sqlite.ConflictAlgorithm.replace);
    } catch (_) {}
  }

  @override
  Future<RouteBundle?> read(String placeId) async {
    try {
      await initialize();
      final rows = await _db.query(
        'route_cache',
        where: 'placeId = ?',
        whereArgs: [placeId],
      );
      if (rows.isEmpty) return null;
      return decodeRouteBundle(rows.first['bundle'] as String);
    } catch (_) {
      return null;
    }
  }

  Future<void> _reload() async {
    final rows = await _db.query(
      'places',
      where: 'deletedAt IS NULL',
      orderBy: 'CASE WHEN slot = 0 THEN 5 ELSE slot END, sortOrder, id',
    );
    _places = List.unmodifiable(rows.map(_readPlace));
    final settings = await _db.query('settings');
    _settings = {
      for (final row in settings) row['key'] as String: row['value'] as String,
    };
    notifyListeners();
  }

  static SavedPlace _readPlace(Map<String, Object?> row) => SavedPlace(
    id: row['id'] as String,
    slot: row['slot'] as int,
    label: row['label'] as String,
    icon: row['icon'] as String,
    name: row['name'] as String,
    address: row['address'] as String,
    city: row['city'] as String,
    latitude: (row['latitude'] as num).toDouble(),
    longitude: (row['longitude'] as num).toDouble(),
    poiUid: row['poiUid'] as String,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updatedAt'] as int),
    verifiedAt: DateTime.fromMillisecondsSinceEpoch(row['verifiedAt'] as int),
    sortOrder: row['sortOrder'] as int,
    rev: row['rev'] as int,
    deletedAt: row['deletedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['deletedAt'] as int),
  );

  @override
  Future<void> savePlace(SavedPlace place) async {
    await initialize();
    if (!privacyAccepted) throw const AppFailure('请先阅读并同意使用说明');
    if (place.verifiedAt == null || (place.poiUid?.trim().isEmpty ?? true)) {
      throw const AppFailure('请先选择搜索结果，并在地图上核对入口');
    }
    if (place.id.isEmpty ||
        place.label.trim().isEmpty ||
        place.name.trim().isEmpty ||
        place.city.trim().isEmpty ||
        place.slot < 0 ||
        place.slot > 4 ||
        !place.latitude.isFinite ||
        !place.longitude.isFinite ||
        place.latitude.abs() > 90 ||
        place.longitude.abs() > 180) {
      throw const AppFailure('地点资料不完整，请重新选择地点');
    }
    try {
      await _db.transaction((txn) async {
        final existing = await txn.query(
          'places',
          where: 'id = ?',
          whereArgs: [place.id],
        );
        if (existing.isNotEmpty && existing.first['deletedAt'] != null) {
          throw const AppFailure('这个地点已删除，请重新添加');
        }
        if (existing.isNotEmpty &&
            existing.first['slot'] == 1 &&
            place.slot != 1) {
          throw const AppFailure('回家按钮不能移走，请直接修改家的地点');
        }
        if (place.slot > 0) {
          final occupied = await txn.query(
            'places',
            columns: ['id'],
            where: 'slot = ? AND deletedAt IS NULL AND id != ?',
            whereArgs: [place.slot, place.id],
          );
          if (occupied.isNotEmpty) {
            throw const AppFailure('这个首页位置已有地点，请编辑原来的地点');
          }
        }
        final values = <String, Object?>{
          'id': place.id,
          'slot': place.slot,
          'label': place.slot == 1 ? '回家' : place.label.trim(),
          'icon': place.slot == 1 ? 'home' : place.icon,
          'name': place.name.trim(),
          'address': place.address.trim(),
          'city': place.city.trim(),
          'latitude': place.latitude,
          'longitude': place.longitude,
          'coordSystem': 'BD-09',
          'poiUid': place.poiUid,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
          'verifiedAt': place.verifiedAt!.millisecondsSinceEpoch,
          'sortOrder': place.sortOrder,
          'rev': existing.isEmpty ? 1 : (existing.first['rev'] as int) + 1,
          'deletedAt': null,
        };
        if (existing.isEmpty) {
          await txn.insert('places', values);
        } else {
          await txn.update(
            'places',
            values,
            where: 'id = ?',
            whereArgs: [place.id],
          );
          // 目的地变了，旧路线与进行中的行程不再适用；只改名称/排序时保留。
          if (existing.first['latitude'] != place.latitude ||
              existing.first['longitude'] != place.longitude ||
              existing.first['poiUid'] != place.poiUid) {
            await txn.delete(
              'route_cache',
              where: 'placeId = ?',
              whereArgs: [place.id],
            );
            await txn.delete(
              'active_trip',
              where: 'placeId = ?',
              whereArgs: [place.id],
            );
          }
        }
      });
      await _reload();
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AppFailure('地点没有保存成功，请稍后再试');
    }
  }

  @override
  Future<void> deletePlace(String id) async {
    await initialize();
    try {
      await _db.transaction((txn) async {
        final rows = await txn.query(
          'places',
          where: 'id = ? AND deletedAt IS NULL',
          whereArgs: [id],
        );
        if (rows.isEmpty) return;
        if (rows.first['slot'] == 1) throw const AppFailure('家的地点不能删除，可以修改地址');
        final now = DateTime.now().millisecondsSinceEpoch;
        await txn.update(
          'places',
          {
            'deletedAt': now,
            'updatedAt': now,
            'rev': (rows.first['rev'] as int) + 1,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        await txn.delete('route_cache', where: 'placeId = ?', whereArgs: [id]);
        await txn.delete('active_trip', where: 'placeId = ?', whereArgs: [id]);
      });
      await _reload();
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AppFailure('地点没有删除成功，请稍后再试');
    }
  }

  @override
  Future<void> reorderMore(List<String> ids) async {
    await initialize();
    try {
      await _db.transaction((txn) async {
        final rows = await txn.query(
          'places',
          columns: ['id'],
          where: 'slot = 0 AND deletedAt IS NULL',
        );
        final known = rows.map((e) => e['id'] as String).toSet();
        if (ids.length != known.length ||
            ids.toSet().length != ids.length ||
            !known.containsAll(ids)) {
          throw const AppFailure('地点列表已变化，请返回后重新排序');
        }
        final now = DateTime.now().millisecondsSinceEpoch;
        for (var i = 0; i < ids.length; i++) {
          await txn.rawUpdate(
            'UPDATE places SET sortOrder = ?, updatedAt = ?, rev = rev + 1 WHERE id = ?',
            [i, now, ids[i]],
          );
        }
      });
      await _reload();
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AppFailure('顺序没有保存成功，请稍后再试');
    }
  }

  @override
  Future<void> acceptPrivacy() async {
    await initialize();
    try {
      await _db.insert('settings', {
        'key': 'privacyAccepted',
        'value': '1',
      }, conflictAlgorithm: sqlite.ConflictAlgorithm.replace);
      await _reload();
    } catch (_) {
      throw const AppFailure('使用说明的确认未保存，请稍后再试');
    }
  }

  @override
  Future<void> setPin(String pin) async {
    await initialize();
    if (!RegExp(r'^\d{4,6}$').hasMatch(pin)) {
      throw const AppFailure('请使用 4 至 6 位数字');
    }
    final random = Random.secure();
    final salt = base64Url.encode(
      List.generate(24, (_) => random.nextInt(256)),
    );
    final digest = sha256.convert(utf8.encode('$salt:$pin')).toString();
    try {
      await _db.transaction((txn) async {
        for (final entry in {'pinSalt': salt, 'pinHash': digest}.entries) {
          await txn.insert('settings', {
            'key': entry.key,
            'value': entry.value,
          }, conflictAlgorithm: sqlite.ConflictAlgorithm.replace);
        }
      });
      await _reload();
    } catch (_) {
      throw const AppFailure('家属密码未保存，请稍后再试');
    }
  }

  @override
  Future<bool> verifyPin(String pin) async {
    await initialize();
    final salt = _settings['pinSalt'];
    final expected = _settings['pinHash'];
    if (salt == null || expected == null) return false;
    final actual = sha256.convert(utf8.encode('$salt:$pin')).toString();
    var difference = actual.length ^ expected.length;
    for (var i = 0; i < actual.length && i < expected.length; i++) {
      difference |= actual.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return difference == 0;
  }

  /// 显式关闭用于退出/本地数据库测试；不清除任何资料。
  Future<void> close() async {
    await _database?.close();
    _database = null;
    _initializing = null;
  }
}
