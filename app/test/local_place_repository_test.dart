import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seniornav/core/contracts.dart';
import 'package:seniornav/data/local_place_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

SavedPlace place(
  String id, {
  int slot = 0,
  int sort = 0,
  bool verified = true,
}) {
  final now = DateTime(2026, 1, 1);
  return SavedPlace(
    id: id,
    slot: slot,
    label: '测试地点 $id',
    icon: 'place',
    name: '虚构测试地点',
    address: '虚构测试地址',
    city: '合肥',
    latitude: 31.86,
    longitude: 117.28,
    poiUid: 'test-poi-$id',
    updatedAt: now,
    verifiedAt: verified ? now : null,
    sortOrder: sort,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late String dbPath;
  late LocalPlaceRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seniornav_places_test_');
    dbPath = '${directory.path}/places.db';
    repository = LocalPlaceRepository(
      databaseFactory: databaseFactoryFfi,
      databasePath: dbPath,
    );
    await repository.initialize();
  });

  tearDown(() async {
    await repository.close();
    repository.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'fresh install is empty; consent and salted PIN survive reopening',
    () async {
      expect(repository.places, isEmpty);
      expect(repository.hasPin, isFalse);
      expect(repository.privacyAccepted, isFalse);
      await repository.setPin('2468');
      await repository.acceptPrivacy();
      expect(await repository.verifyPin('2468'), isTrue);
      expect(await repository.verifyPin('8642'), isFalse);
      final db = await databaseFactoryFfi.openDatabase(dbPath);
      final settings = await db.query('settings');
      expect(settings.any((row) => row['value'] == '2468'), isFalse);
      final oldSalt = settings.firstWhere(
        (row) => row['key'] == 'pinSalt',
      )['value'];
      await repository.setPin('2468');
      final newSettings = await db.query('settings');
      expect(
        newSettings.firstWhere((row) => row['key'] == 'pinSalt')['value'],
        isNot(oldSalt),
      );
      await repository.close();
      await repository.initialize();
      expect(repository.hasPin, isTrue);
      expect(repository.privacyAccepted, isTrue);
      expect(await repository.verifyPin('2468'), isTrue);
      expect(await repository.verifyPin(''), isFalse);
    },
  );

  test(
    'rejects unconfirmed places and invalid PINs without partial writes',
    () async {
      await expectLater(
        repository.savePlace(place('one')),
        throwsA(isA<AppFailure>()),
      );
      await repository.acceptPrivacy();
      await expectLater(
        repository.savePlace(place('one', verified: false)),
        throwsA(isA<AppFailure>()),
      );
      for (final pin in ['123', '1234567', 'abcd']) {
        await expectLater(repository.setPin(pin), throwsA(isA<AppFailure>()));
      }
      expect(repository.hasPin, isFalse);
      expect(repository.places, isEmpty);
    },
  );

  test('home is fixed, slots are unique, and saved data is BD-09', () async {
    await repository.acceptPrivacy();
    await repository.savePlace(place('home', slot: 1));
    expect(repository.places.single.label, '回家');
    expect(repository.places.single.icon, 'home');
    await expectLater(
      repository.deletePlace('home'),
      throwsA(isA<AppFailure>()),
    );
    await expectLater(
      repository.savePlace(place('home', slot: 0)),
      throwsA(isA<AppFailure>()),
    );
    await expectLater(
      repository.savePlace(place('other', slot: 1)),
      throwsA(isA<AppFailure>()),
    );
    final db = await databaseFactoryFfi.openDatabase(dbPath);
    expect((await db.query('places')).single['coordSystem'], 'BD-09');
    expect(await db.getVersion(), 1);
    expect(repository.places.single.id, 'home');
  });

  test(
    'schema enforces one active record per fixed slot even outside repository',
    () async {
      await repository.acceptPrivacy();
      await repository.savePlace(place('one', slot: 2));
      final db = await databaseFactoryFfi.openDatabase(dbPath);
      final row = Map<String, Object?>.of((await db.query('places')).single)
        ..['id'] = 'collision';
      await expectLater(
        db.insert('places', row),
        throwsA(isA<DatabaseException>()),
      );
      expect((await db.query('places')).length, 1);
    },
  );

  test('soft deletion keeps tombstone, releases slot, prevents accidental resurrection', () async {
    await repository.acceptPrivacy();
    await repository.savePlace(place('first', slot: 3));
    await repository.deletePlace('first');
    expect(repository.places, isEmpty);
    await repository.savePlace(place('replacement', slot: 3));
    await expectLater(
      repository.savePlace(place('first')),
      throwsA(isA<AppFailure>()),
    );
    final db = await databaseFactoryFfi.openDatabase(dbPath);
    final deleted = (await db.query(
      'places',
      where: 'id = ?',
      whereArgs: ['first'],
    )).single;
    expect(deleted['deletedAt'], isNotNull);
    expect(deleted['rev'], 2);
    await repository.close();
    await repository.initialize();
    expect(repository.places.map((p) => p.id), ['replacement']);
  });

  test('reorder is atomic and cannot include home or stale list ids', () async {
    await repository.acceptPrivacy();
    await repository.savePlace(place('home', slot: 1));
    await repository.savePlace(place('one', sort: 0));
    await repository.savePlace(place('two', sort: 1));
    await repository.reorderMore(['two', 'one']);
    expect(repository.places.map((p) => p.id), ['home', 'two', 'one']);
    await expectLater(
      repository.reorderMore(['home', 'two', 'one']),
      throwsA(isA<AppFailure>()),
    );
    await expectLater(
      repository.reorderMore(['one', 'one']),
      throwsA(isA<AppFailure>()),
    );
    expect(repository.places.map((p) => p.id), ['home', 'two', 'one']);
    await repository.close();
    await repository.initialize();
    expect(repository.places.map((p) => p.id), ['home', 'two', 'one']);
    expect(repository.places.last.rev, 2);
  });
}
