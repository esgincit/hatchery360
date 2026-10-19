// Supervisor daily entry. Works fully offline; photos staged for later upload; AI triage on demand.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/local/app_db.dart';
import '../../data/repos/daily_log_repo.dart';

final activeBatchesProvider = StreamProvider.autoDispose((ref) =>
    (AppDb.instance.select(AppDb.instance.batches)..where((b) => b.state.isNotIn(['closed']) & b.farmType.isNotIn(['hatchery']))).watch());

class DailyLogScreen extends ConsumerStatefulWidget {
  const DailyLogScreen({super.key, this.batchId});
  final String? batchId;
  @override ConsumerState<DailyLogScreen> createState() => _DailyLogScreenState();
}

class _DailyLogScreenState extends ConsumerState<DailyLogScreen> {
  final _form = GlobalKey<FormState>();
  final _c = <String, TextEditingController>{};
  final _photos = <File>[];
  Map<String, dynamic>? _ai;
  String? _batchId;
  bool _saving = false;

  TextEditingController c(String k, [String v = '']) => _c.putIfAbsent(k, () => TextEditingController(text: v));
  int i(String k) => int.tryParse(c(k).text) ?? 0;
  double d(String k) => double.tryParse(c(k).text) ?? 0;

  Future<void> _capture() async {
    final x = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 70, maxWidth: 1600);
    if (x != null) setState(() => _photos.add(File(x.path)));
  }

  Future<void> _aiTriage(Batche b) async {
    // Online-only: uploads staged photos first, then calls the ai-triage edge function.
    setState(() => _ai = {'loading': true});
    try {
      final sb = Supabase.instance.client;
      final tenant = sb.auth.currentUser!.appMetadata['tenant_id'];
      final ids = <String>[];
      for (final f in _photos) {
        final id = DateTime.now().microsecondsSinceEpoch.toString();
        final path = '$tenant/triage/$id.jpg';
        await sb.storage.from('evidence').upload(path, f);
        final m = await sb.from('media').insert({'tenant_id': tenant, 'storage_path': path, 'entity_type': 'batch', 'entity_id': b.id}).select('id').single();
        ids.add(m['id']);
      }
      final res = await sb.functions.invoke('ai-triage', body: {'batch_id': b.id, 'media_ids': ids});
      setState(() => _ai = Map<String, dynamic>.from(res.data));
    } catch (e) { setState(() => _ai = {'error': '$e'}); }
  }

  Future<void> _save(Batche b) async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final isLayer = b.farmType == 'layer';
    final grades = isLayer ? {for (final g in ['jumbo','large','medium','small','cracked','dirty']) g: i('g_$g') * 30} : null;
    await DailyLogRepo().saveDailyLog(
      batch: b, date: DateTime.now(), birdsOpening: i('birds'), mortality: i('mort'), culls: i('cull'),
      feedKg: d('feed') * 50, water: d('water'), tMin: d('tmin'), tMax: d('tmax'), rh: d('rh'),
      avgWeightG: isLayer ? null : i('wt'), eggGrades: grades, remarks: c('rem').text,
      causeCode: _ai?['ranked']?[0]?['code'], photos: _photos);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved offline · ${b.shedName}. Will sync when online.')));
    context.go('/farm/batch/${b.id}');
  }

  @override
  Widget build(BuildContext context) {
    final batches = ref.watch(activeBatchesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Daily log · నేటి నమోదు')),
      body: batches.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) {
          if (list.isEmpty) return const Center(child: Text('No active batches synced yet. Pull to sync on Home.'));
          final b = list.firstWhere((x) => x.id == (_batchId ?? widget.batchId), orElse: () => list.first);
          final isLayer = b.farmType == 'layer';
          return Form(key: _form, child: ListView(padding: const EdgeInsets.all(16), children: [
            SizedBox(height: 40, child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final x in list) Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: Text(x.shedName.isEmpty ? x.code : x.shedName), selected: x.id == b.id, onSelected: (_) => setState(() => _batchId = x.id)))])),
            const SizedBox(height: 12),
            Text('${b.code} · ${isLayer ? 'wk ${DateTime.now().difference(b.placedOn).inDays ~/ 7}' : 'day ${DateTime.now().difference(b.placedOn).inDays}'}', style: Theme.of(context).textTheme.titleMedium),
            _section('Birds'),
            Row(children: [
              Expanded(child: _num('birds', 'Opening birds', '${b.docCount}')), const SizedBox(width: 8),
              Expanded(child: _num('mort', 'Mortality')), const SizedBox(width: 8),
              Expanded(child: _num('cull', 'Culls')),
            ]),
            if (isLayer) ...[_section('Eggs by grade (trays of 30)'),
              GridView.count(crossAxisCount: 3, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), childAspectRatio: 1.9, mainAxisSpacing: 8, crossAxisSpacing: 8,
                children: [for (final g in ['jumbo','large','medium','small','cracked','dirty']) _num('g_$g', g[0].toUpperCase() + g.substring(1))])]
            else ...[_section('Growth sample'), Row(children: [Expanded(child: _num('wt', 'Avg weight (g)')), const SizedBox(width: 8), Expanded(child: _num('cv', 'Uniformity CV %'))])],
            _section('Feed & water'),
            Row(children: [Expanded(child: _num('feed', 'Feed (bags 50 kg)')), const SizedBox(width: 8), Expanded(child: _num('water', 'Water (litres)'))]),
            _section('Shed climate'),
            Row(children: [Expanded(child: _num('tmin', 'Min °C')), const SizedBox(width: 8), Expanded(child: _num('tmax', 'Max °C')), const SizedBox(width: 8), Expanded(child: _num('rh', 'RH %'))]),
            _section('Evidence photos'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final f in _photos) ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.file(f, width: 96, height: 72, fit: BoxFit.cover)),
              OutlinedButton.icon(onPressed: _capture, icon: const Icon(Icons.photo_camera_outlined), label: const Text('Capture')),
            ]),
            if (_photos.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: FilledButton.tonalIcon(onPressed: () => _aiTriage(b), icon: const Icon(Icons.biotech_outlined), label: const Text('Check with AI (beta)'))),
            if (_ai != null) _AiCard(_ai!),
            _section('Remarks'),
            TextFormField(controller: c('rem'), decoration: const InputDecoration(hintText: 'e.g. greenish droppings in row 3')),
            const SizedBox(height: 20),
            FilledButton(onPressed: _saving ? null : () => _save(b), child: Text(_saving ? 'Saving…' : 'Save log · syncs when online')),
          ]));
        },
      ),
    );
  }

  Widget _section(String t) => Padding(padding: const EdgeInsets.only(top: 16, bottom: 8), child: Text(t.toUpperCase(), style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 1)));
  Widget _num(String k, String label, [String v = '']) => TextFormField(controller: c(k, v), keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label), validator: (s) => (s == null || s.isEmpty) && k == 'birds' ? 'Required' : null);
}

class _AiCard extends StatelessWidget {
  const _AiCard(this.ai);
  final Map<String, dynamic> ai;
  @override
  Widget build(BuildContext context) {
    if (ai['loading'] == true) return const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator());
    if (ai['error'] != null) return Text('AI unavailable offline: ${ai['error']}');
    final ranked = (ai['ranked'] as List?) ?? [];
    return Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('AI triage · advisory only', style: Theme.of(context).textTheme.labelLarge),
      for (final r in ranked) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(r['code']), Text('${((r['confidence'] as num) * 100).round()}%')]),
        LinearProgressIndicator(value: (r['confidence'] as num).toDouble())])),
      const SizedBox(height: 6), Text('First actions: ${ai['first_actions'] ?? ''}'),
      const SizedBox(height: 4), Text('A vet confirms the diagnosis in the app.', style: Theme.of(context).textTheme.bodySmall),
    ])));
  }
}
