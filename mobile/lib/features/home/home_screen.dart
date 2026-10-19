import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme.dart';

final _inr = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);

/// Owner / manager dashboard: read from the KPI views, not raw tables.
final batchKpiProvider = FutureProvider.autoDispose((ref) async =>
    await Supabase.instance.client.from('v_batch_kpi').select().order('code'));
final notificationsProvider = FutureProvider.autoDispose((ref) async =>
    await Supabase.instance.client.from('notification').select().isFilter('read_at', null).order('created_at', ascending: false).limit(5));
final eggRateProvider = FutureProvider.autoDispose((ref) async {
  final rows = await Supabase.instance.client.from('market_rate').select('rate, rate_date').eq('product', 'egg').eq('zone', 'Hyderabad').order('rate_date', ascending: false).limit(8);
  return rows;
});
final apArProvider = FutureProvider.autoDispose((ref) async {
  final sb = Supabase.instance.client;
  final ap = await sb.from('v_ap_ageing').select('outstanding');
  final ar = await sb.from('v_ar_ageing').select('outstanding');
  num s(List r) => r.fold<num>(0, (a, x) => a + (x['outstanding'] ?? 0));
  return (ap: s(ap), ar: s(ar));
});

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kpi = ref.watch(batchKpiProvider);
    final notes = ref.watch(notificationsProvider);
    final rate = ref.watch(eggRateProvider);
    final money = ref.watch(apArProvider);
    final name = Supabase.instance.client.auth.currentUser?.userMetadata?['full_name'] ?? '';

    return Scaffold(
      appBar: AppBar(title: Text(DateFormat('EEE, d MMM').format(DateTime.now())), actions: [
        IconButton(icon: const Icon(Icons.notifications_outlined), onPressed: () => context.go('/more')),
      ]),
      body: RefreshIndicator(
        onRefresh: () async { ref.invalidate(batchKpiProvider); ref.invalidate(notificationsProvider); ref.invalidate(eggRateProvider); ref.invalidate(apArProvider); },
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text('Good morning, ${name.toString().split(' ').first}', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          kpi.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text('Could not load KPIs: $e'),
            data: (rows) {
              final active = rows.where((r) => r['state'] != 'closed').toList();
              final birds = active.fold<int>(0, (a, r) => a + (r['birds_alive'] as int));
              final eggs = active.fold<int>(0, (a, r) => a + (r['eggs'] as int));
              return GridView.count(crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), childAspectRatio: 1.7, mainAxisSpacing: 10, crossAxisSpacing: 10, children: [
                _Tile('Birds alive', NumberFormat.decimalPattern('en_IN').format(birds), '${active.length} active batches'),
                _Tile('Eggs (period)', NumberFormat.decimalPattern('en_IN').format(eggs), 'laying batches'),
                rate.maybeWhen(data: (r) => _Tile('NECC egg · Hyd', '₹${(r.first['rate'] as num).toStringAsFixed(2)}', 'per egg · ${r.first['rate_date']}'), orElse: () => const _Tile('NECC egg · Hyd', '—', '')),
                money.maybeWhen(data: (m) => _Tile('AP / AR', '${_inr.format(m.ap)} / ${_inr.format(m.ar)}', 'payable / receivable'), orElse: () => const _Tile('AP / AR', '—', '')),
              ]);
            }),
          const SizedBox(height: 16),
          Text('Needs attention', style: Theme.of(context).textTheme.labelLarge),
          notes.maybeWhen(data: (n) => Column(children: n.map((x) => Card(child: ListTile(
            leading: Icon(Icons.circle, size: 12, color: x['severity'] == 'critical' ? Rag.crit : x['severity'] == 'warning' ? Rag.warn : Theme.of(context).colorScheme.primary),
            title: Text(x['title']), subtitle: Text(x['body'] ?? ''), dense: true))).toList()), orElse: () => const SizedBox.shrink()),
          const SizedBox(height: 16),
          Text('Batches', style: Theme.of(context).textTheme.labelLarge),
          kpi.maybeWhen(data: (rows) => Column(children: rows.map((r) {
            final crit = (r['mortality_pct'] as num) > 5; final closed = r['state'] == 'closed';
            return Card(child: ListTile(
              leading: Icon(Icons.circle, size: 12, color: closed ? Colors.grey : crit ? Rag.crit : Rag.good),
              title: Text(r['code']), subtitle: Text('${r['state']} · day ${r['age_days']} · ${NumberFormat.decimalPattern('en_IN').format(r['birds_alive'])} birds · mortality ${r['mortality_pct']}%'),
              trailing: const Icon(Icons.chevron_right), onTap: () => context.go('/farm/batch/${r['batch_id']}')));
          }).toList()), orElse: () => const SizedBox.shrink()),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: () => context.go('/log'), icon: const Icon(Icons.edit_note), label: const Text('Start today’s log')),
        ]),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value, this.sub);
  final String label, value, sub;
  @override
  Widget build(BuildContext context) => Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
    Text(label, style: Theme.of(context).textTheme.labelSmall), const SizedBox(height: 2),
    FittedBox(child: Text(value, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, fontFeatures: const [FontFeature.tabularFigures()]))),
    Text(sub, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
  ])));
}
