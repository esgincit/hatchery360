import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme.dart';

final batchDetailProvider = FutureProvider.autoDispose.family((ref, String id) async {
  final sb = Supabase.instance.client;
  final kpi = await sb.from('v_batch_kpi').select().eq('batch_id', id).single();
  final logs = await sb.from('daily_shed_log').select('log_date,birds_opening,mortality,feed_kg,avg_weight_g,temp_max_c, egg_production(grade,count)').eq('batch_id', id).order('log_date', ascending: false).limit(28);
  final vacc = await sb.from('vaccination_schedule').select('due_date,done_on, vaccine_master(name)').eq('batch_id', id).order('due_date');
  final cases = await sb.from('disease_case').select().eq('batch_id', id).order('opened_on', ascending: false);
  final visits = await sb.from('vet_visit').select().eq('batch_id', id).order('visit_date', ascending: false);
  return (kpi: kpi, logs: logs.reversed.toList(), vacc: vacc, cases: cases, visits: visits);
});

class BatchScreen extends ConsumerWidget {
  const BatchScreen({super.key, required this.batchId});
  final String batchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(batchDetailProvider(batchId));
    return Scaffold(
      appBar: AppBar(title: d.maybeWhen(data: (x) => Text(x.kpi['code']), orElse: () => const Text('Batch'))),
      body: d.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (x) {
          final k = x.kpi; final isLayer = k['farm_type'] == 'layer';
          final mort = x.logs.map((l) => (l['mortality'] as int).toDouble()).toList();
          final base = mort.length > 7 ? mort.sublist(0, mort.length - 7).fold(0.0, (a, b) => a + b) / (mort.length - 7) : 0.0;
          final series = isLayer
              ? x.logs.map((l) { final eggs = (l['egg_production'] as List).fold<int>(0, (a, e) => a + (e['count'] as int)); return eggs == 0 ? null : 100.0 * eggs / (l['birds_opening'] as int); }).toList()
              : x.logs.map((l) => (l['avg_weight_g'] as int?)?.toDouble()).toList();
          return ListView(padding: const EdgeInsets.all(16), children: [
            Row(children: [
              _Stat('Birds', '${k['birds_alive']}', 'of ${k['doc_count']}'),
              _Stat('Age', isLayer ? 'wk ${(k['age_days'] as int) ~/ 7}' : 'day ${k['age_days']}', k['state']),
              _Stat('Mortality', '${k['mortality_pct']}%', 'cum.'),
            ]),
            const SizedBox(height: 12),
            Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(isLayer ? 'Hen-day production %' : 'Avg body weight (g)', style: Theme.of(context).textTheme.labelLarge),
              SizedBox(height: 160, child: LineChart(LineChartData(
                gridData: const FlGridData(drawVerticalLine: false),
                titlesData: const FlTitlesData(topTitles: AxisTitles(), rightTitles: AxisTitles()),
                borderData: FlBorderData(show: false),
                lineBarsData: [LineChartBarData(
                  spots: [for (var i = 0; i < series.length; i++) if (series[i] != null) FlSpot(i.toDouble(), series[i]!)],
                  isCurved: false, barWidth: 2, dotData: const FlDotData(show: false), color: Theme.of(context).colorScheme.primary)],
              ))),
            ]))),
            const SizedBox(height: 12),
            Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Daily mortality · baseline ${base.toStringAsFixed(1)}/day', style: Theme.of(context).textTheme.labelLarge),
              SizedBox(height: 120, child: BarChart(BarChartData(
                gridData: const FlGridData(drawVerticalLine: false), borderData: FlBorderData(show: false),
                titlesData: const FlTitlesData(topTitles: AxisTitles(), rightTitles: AxisTitles(), bottomTitles: AxisTitles()),
                barGroups: [for (var i = 0; i < mort.length; i++) BarChartGroupData(x: i, barRods: [BarChartRodData(toY: mort[i], width: 6,
                  color: mort[i] > 1.8 * base && mort[i] > 5 ? Rag.crit : Theme.of(context).colorScheme.outline)])],
              ))),
            ]))),
            if (x.cases.isNotEmpty) ...[const SizedBox(height: 12), Card(color: Rag.crit.withOpacity(.08), child: ListTile(
              leading: const Icon(Icons.biotech, color: Rag.crit), title: Text('AI flag: ${x.cases.first['ai_top_condition']} · ${((x.cases.first['ai_confidence'] as num) * 100).round()}%'),
              subtitle: Text(x.cases.first['vet_confirmed'] == true ? 'Vet confirmed' : 'Awaiting vet confirmation')))],
            const SizedBox(height: 12),
            Text('Vaccinations', style: Theme.of(context).textTheme.labelLarge),
            for (final v in x.vacc) ListTile(dense: true, title: Text(v['vaccine_master']['name']), subtitle: Text('due ${v['due_date']}'),
              trailing: v['done_on'] != null ? const Icon(Icons.check_circle, color: Rag.good)
                : DateTime.parse(v['due_date']).isBefore(DateTime.now()) ? const Icon(Icons.error, color: Rag.crit) : const Icon(Icons.schedule)),
            if (x.visits.isNotEmpty) ...[const SizedBox(height: 12), Text('Vet visits', style: Theme.of(context).textTheme.labelLarge),
              for (final v in x.visits) Card(child: ListTile(title: Text('${v['vet_name']} · ${v['visit_date']}'), subtitle: Text('${v['findings']}\nRx: ${v['prescription']}'), isThreeLine: true))],
            const SizedBox(height: 16),
            FilledButton(onPressed: () => context.go('/log?batch=$batchId'), child: const Text('Log today')),
          ]);
        },
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.l, this.v, this.s);
  final String l, v, s;
  @override
  Widget build(BuildContext context) => Expanded(child: Card(child: Padding(padding: const EdgeInsets.all(10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(l, style: Theme.of(context).textTheme.labelSmall), Text(v, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)), Text(s, style: Theme.of(context).textTheme.bodySmall)]))));
}
