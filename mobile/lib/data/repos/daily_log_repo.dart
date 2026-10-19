// Write path for the supervisor's daily entry: local first, then outbox.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../local/app_db.dart';
import '../sync/sync_service.dart';

class DailyLogRepo {
  final _db = AppDb.instance;
  final _sync = SyncService.instance;
  String get _tenantId => Supabase.instance.client.auth.currentUser!.appMetadata['tenant_id'];

  Future<String> saveDailyLog({
    required Batche batch, required DateTime date, required int birdsOpening, required int mortality, required int culls,
    required double feedKg, double? water, double? tMin, double? tMax, double? rh, int? avgWeightG,
    Map<String, int>? eggGrades, String? remarks, String? causeCode, List<File> photos = const [],
  }) async {
    final id = const Uuid().v5(Uuid.NAMESPACE_URL, '${batch.id}/${date.toIso8601String().substring(0, 10)}');
    final payload = {
      'id': id, 'batch_id': batch.id, 'shed_id': batch.shedId, 'log_date': date.toIso8601String().substring(0, 10),
      'birds_opening': birdsOpening, 'mortality': mortality, 'culls': culls, 'feed_kg': feedKg, 'water_litres': water,
      'temp_min_c': tMin, 'temp_max_c': tMax, 'humidity_pct': rh, 'avg_weight_g': avgWeightG, 'remarks': remarks,
    };
    await _db.into(_db.dailyLogs).insertOnConflictUpdate(DailyLogsCompanion.insert(
      id: id, tenantId: _tenantId, batchId: batch.id, shedId: batch.shedId, logDate: date, birdsOpening: birdsOpening,
      mortality: Value(mortality), culls: Value(culls), feedKg: Value(feedKg), waterLitres: Value(water),
      tempMinC: Value(tMin), tempMaxC: Value(tMax), humidityPct: Value(rh), avgWeightG: Value(avgWeightG),
      eggGradesJson: Value(eggGrades == null ? null : jsonEncode(eggGrades)), remarks: Value(remarks), dirty: const Value(true)));
    await _sync.enqueue('daily_shed_log', 'insert', payload);

    if (eggGrades != null) {
      for (final e in eggGrades.entries) {
        await _sync.enqueue('egg_production', 'insert', {'daily_log_id': id, 'grade': e.key, 'count': e.value});
      }
    }
    if (mortality > 0) {
      await _sync.enqueue('mortality_event', 'insert', {
        'id': const Uuid().v4(), 'batch_id': batch.id, 'event_date': payload['log_date'], 'count': mortality, 'cause_code': causeCode});
    }
    // feed issue is a stock movement out of the farm store (-kg); the store id is resolved server-side by farm
    if (feedKg > 0) {
      await _sync.enqueue('stock_movement', 'insert', {
        'move_type': 'issue', 'qty': -feedKg, 'batch_id': batch.id, 'ref_type': 'daily_log', 'ref_id': id, 'moved_on': payload['log_date'],
        'farm_id': batch.farmId, 'item_name_hint': batch.farmType == 'layer' ? 'Layer mash (Phase 1)' : 'Broiler finisher pellets'});
    }
    for (final f in photos) await _stagePhoto(f, 'daily_shed_log', id);
    return id;
  }

  Future<void> _stagePhoto(File f, String entityType, String entityId) async {
    final bytes = await f.readAsBytes();
    Position? pos;
    try { pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.medium); } catch (_) {}
    await _db.into(_db.pendingMedia).insert(PendingMediaCompanion.insert(
      id: const Uuid().v4(), localPath: f.path, sha256: sha256.convert(bytes).toString(),
      lat: Value(pos?.latitude), lng: Value(pos?.longitude), takenAt: DateTime.now(), entityType: entityType, entityId: entityId));
  }
}
