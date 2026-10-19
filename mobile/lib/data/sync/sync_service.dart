// Offline-first sync: outbox replay (push) + cursor-based delta pull. Photos go separately.
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../env.dart';
import '../local/app_db.dart';

final outboxCountProvider = StreamProvider<int>((_) => AppDb.instance.outboxCount());

class SyncService {
  SyncService._();
  static final instance = SyncService._();
  final _db = AppDb.instance;
  final _sb = Supabase.instance.client;
  static const _pullTables = ['batch', 'daily_shed_log', 'market_rate'];

  /// Called by every local write. Record is already in the local table; this queues the replay.
  Future<void> enqueue(String table, String action, Map<String, dynamic> payload, {int? baseVersion}) async {
    await _db.into(_db.outbox).insert(OutboxCompanion.insert(
      opId: const Uuid().v4(), tableName: table, action: action,
      payloadJson: jsonEncode(payload), baseVersion: Value(baseVersion)));
    if (await _online()) unawaited(pushOutbox());
  }

  Future<bool> _online() async =>
      !(await Connectivity().checkConnectivity()).contains(ConnectivityResult.none);

  Future<void> pushOutbox() async {
    final ops = await (_db.select(_db.outbox)..orderBy([(o) => OrderingTerm.asc(o.createdAt)])..limit(50)).get();
    if (ops.isEmpty) return;
    final deviceId = (await _sb.auth.currentUser?.id) ?? 'anon';
    final res = await _sb.functions.invoke('sync-apply', body: {
      'device_id': deviceId,
      'ops': ops.map((o) => {'op_id': o.opId, 'table': o.tableName, 'action': o.action,
        'payload': jsonDecode(o.payloadJson), 'base_version': o.baseVersion}).toList(),
    });
    final results = (res.data['results'] as List).cast<Map<String, dynamic>>();
    for (final r in results) {
      final status = r['status'];
      if (status == 'applied' || status == 'duplicate') {
        await (_db.delete(_db.outbox)..where((o) => o.opId.equals(r['op_id']))).go();
      } else if (status == 'conflict') {
        // keep op; surface to manager. The UI reads outbox.lastError = 'conflict:<server_version>'
        await (_db.update(_db.outbox)..where((o) => o.opId.equals(r['op_id'])))
            .write(OutboxCompanion(lastError: Value('conflict:${r['detail']?['server_version']}')));
      } else {
        await (_db.update(_db.outbox)..where((o) => o.opId.equals(r['op_id'])))
            .write(OutboxCompanion(attempts: const Value.absent(), lastError: Value(r['detail']?.toString())));
      }
    }
    await uploadPendingMedia();
    if (ops.length == 50) await pushOutbox();
  }

  /// Pull rows changed since the per-table cursor. Server tables expose sync_version / updated_at.
  Future<void> pullDeltas() async {
    for (final t in _pullTables) {
      final cursor = await (_db.select(_db.syncCursors)..where((c) => c.tableName.equals(t))).getSingleOrNull();
      final since = cursor?.lastPulledAt?.toIso8601String() ?? '1970-01-01';
      final rows = await _sb.from(t).select().gte(t == 'market_rate' ? 'rate_date' : 'created_at', since).limit(2000);
      if (t == 'batch') {
        await _db.batch((b) => b.insertAllOnConflictUpdate(_db.batches, rows.map((r) => BatchesCompanion.insert(
          id: r['id'], tenantId: r['tenant_id'], farmId: r['farm_id'], shedId: r['shed_id'], code: r['code'],
          farmType: r['farm_type'], state: r['state'], placedOn: DateTime.parse(r['placed_on']),
          docCount: r['doc_count'], docRate: Value((r['doc_rate'] as num?)?.toDouble()))).toList()));
      } else if (t == 'daily_shed_log') {
        await _db.batch((b) => b.insertAllOnConflictUpdate(_db.dailyLogs, rows.map((r) => DailyLogsCompanion.insert(
          id: r['id'], tenantId: r['tenant_id'], batchId: r['batch_id'], shedId: r['shed_id'],
          logDate: DateTime.parse(r['log_date']), birdsOpening: r['birds_opening'],
          mortality: Value(r['mortality'] ?? 0), culls: Value(r['culls'] ?? 0), feedKg: Value((r['feed_kg'] as num?)?.toDouble() ?? 0),
          waterLitres: Value((r['water_litres'] as num?)?.toDouble()), tempMinC: Value((r['temp_min_c'] as num?)?.toDouble()),
          tempMaxC: Value((r['temp_max_c'] as num?)?.toDouble()), avgWeightG: Value(r['avg_weight_g']),
          remarks: Value(r['remarks']), locked: Value(r['locked'] ?? false), syncVersion: Value(r['sync_version'] ?? 1))).toList()));
      } else {
        await _db.batch((b) => b.insertAllOnConflictUpdate(_db.marketRates, rows.map((r) => MarketRatesCompanion.insert(
          product: r['product'], zone: r['zone'], rateDate: DateTime.parse(r['rate_date']), rate: (r['rate'] as num).toDouble())).toList()));
      }
      await _db.into(_db.syncCursors).insertOnConflictUpdate(SyncCursorsCompanion.insert(
        tableName: t, lastPulledAt: Value(DateTime.now().toUtc())));
    }
  }

  /// Photos: compressed JPEG to private `evidence` bucket under <tenant>/<entity>/<id>.jpg, then a media row.
  Future<void> uploadPendingMedia() async {
    final tenantId = _sb.auth.currentUser?.appMetadata['tenant_id'];
    final items = await (_db.select(_db.pendingMedia)..where((m) => m.uploaded.equals(false))).get();
    for (final m in items) {
      final path = '$tenantId/${m.entityType}/${m.id}.jpg';
      await _sb.storage.from('evidence').upload(path, File(m.localPath), fileOptions: const FileOptions(upsert: true));
      await _sb.from('media').insert({'id': m.id, 'tenant_id': tenantId, 'storage_path': path, 'sha256': m.sha256,
        'lat': m.lat, 'lng': m.lng, 'taken_at': m.takenAt.toIso8601String(), 'entity_type': m.entityType, 'entity_id': m.entityId});
      await (_db.update(_db.pendingMedia)..where((x) => x.id.equals(m.id))).write(const PendingMediaCompanion(uploaded: Value(true)));
    }
  }
}

void unawaited(Future<void> f) {}
