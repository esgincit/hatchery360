// Local offline store (Drift / SQLite). Mirrors the tenant's working set plus an outbox.
// Run: dart run build_runner build -d   → generates app_db.g.dart
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_db.g.dart';

class Batches extends Table {
  TextColumn get id => text()();
  TextColumn get tenantId => text()();
  TextColumn get farmId => text()();
  TextColumn get shedId => text()();
  TextColumn get code => text()();
  TextColumn get farmType => text()();            // layer | broiler | breeder | hatchery
  TextColumn get state => text()();
  DateTimeColumn get placedOn => dateTime()();
  IntColumn get docCount => integer()();
  RealColumn get docRate => real().nullable()();
  TextColumn get shedName => text().withDefault(const Constant(''))();
  TextColumn get farmName => text().withDefault(const Constant(''))();
  IntColumn get syncVersion => integer().withDefault(const Constant(1))();
  @override Set<Column> get primaryKey => {id};
}

class DailyLogs extends Table {
  TextColumn get id => text()();
  TextColumn get tenantId => text()();
  TextColumn get batchId => text()();
  TextColumn get shedId => text()();
  DateTimeColumn get logDate => dateTime()();
  IntColumn get birdsOpening => integer()();
  IntColumn get mortality => integer().withDefault(const Constant(0))();
  IntColumn get culls => integer().withDefault(const Constant(0))();
  RealColumn get feedKg => real().withDefault(const Constant(0))();
  RealColumn get waterLitres => real().nullable()();
  RealColumn get tempMinC => real().nullable()();
  RealColumn get tempMaxC => real().nullable()();
  RealColumn get humidityPct => real().nullable()();
  IntColumn get avgWeightG => integer().nullable()();
  TextColumn get eggGradesJson => text().nullable()();      // {"large":9000,...}
  TextColumn get remarks => text().nullable()();
  BoolColumn get locked => boolean().withDefault(const Constant(false))();
  IntColumn get syncVersion => integer().withDefault(const Constant(1))();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();
  @override Set<Column> get primaryKey => {id};
}

class MarketRates extends Table {
  TextColumn get product => text()();
  TextColumn get zone => text()();
  DateTimeColumn get rateDate => dateTime()();
  RealColumn get rate => real()();
  @override Set<Column> get primaryKey => {product, zone, rateDate};
}

/// Every local write lands here first; SyncService replays it to the sync-apply edge function.
class Outbox extends Table {
  TextColumn get opId => text()();                 // client uuid = idempotency key
  TextColumn get tableName => text()();
  TextColumn get action => text()();               // insert | update
  TextColumn get payloadJson => text()();
  IntColumn get baseVersion => integer().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  @override Set<Column> get primaryKey => {opId};
}

/// Photos waiting for upload (uploaded separately from the record, resumable).
class PendingMedia extends Table {
  TextColumn get id => text()();
  TextColumn get localPath => text()();
  TextColumn get sha256 => text()();
  RealColumn get lat => real().nullable()();
  RealColumn get lng => real().nullable()();
  DateTimeColumn get takenAt => dateTime()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  BoolColumn get uploaded => boolean().withDefault(const Constant(false))();
  @override Set<Column> get primaryKey => {id};
}

class SyncCursors extends Table {
  TextColumn get tableName => text()();
  IntColumn get lastVersion => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastPulledAt => dateTime().nullable()();
  @override Set<Column> get primaryKey => {tableName};
}

@DriftDatabase(tables: [Batches, DailyLogs, MarketRates, Outbox, PendingMedia, SyncCursors])
class AppDb extends _$AppDb {
  AppDb._() : super(_open());
  static final AppDb instance = AppDb._();
  @override int get schemaVersion => 1;

  static LazyDatabase _open() => LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    return NativeDatabase.createInBackground(File(p.join(dir.path, 'poultryos.sqlite')));
  });

  Stream<int> outboxCount() => (selectOnly(outbox)..addColumns([outbox.opId.count()]))
      .map((r) => r.read(outbox.opId.count()) ?? 0).watchSingle();
}
