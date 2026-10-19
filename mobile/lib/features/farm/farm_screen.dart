import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final farmsProvider = FutureProvider.autoDispose((ref) async =>
    await Supabase.instance.client.from('farm').select('id,name,farm_type,district,capacity_birds, shed(id,name,capacity_birds, batch(id,code,state,placed_on,doc_count))').order('name'));

class FarmScreen extends ConsumerWidget {
  const FarmScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final farms = ref.watch(farmsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Farms & sheds')),
      body: farms.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => ListView(padding: const EdgeInsets.all(16), children: [
          for (final f in list) Card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ListTile(title: Text(f['name'], style: const TextStyle(fontWeight: FontWeight.w700)), subtitle: Text('${f['farm_type']} · ${f['district']} · capacity ${f['capacity_birds']}')),
            for (final s in (f['shed'] as List)) () {
              final batches = (s['batch'] as List).where((b) => b['state'] != 'closed').toList();
              final b = batches.isEmpty ? null : batches.first;
              final age = b == null ? null : DateTime.now().difference(DateTime.parse(b['placed_on'])).inDays;
              return ListTile(dense: true, leading: const Icon(Icons.warehouse_outlined),
                title: Text(s['name']), subtitle: Text(b == null ? 'Empty · ready for placement' : '${b['code']} · ${b['state']} · day $age · ${b['doc_count']} placed'),
                trailing: b == null ? null : const Icon(Icons.chevron_right),
                onTap: b == null ? null : () => context.go('/farm/batch/${b['id']}'));
            }(),
          ])),
        ]),
      ),
    );
  }
}
