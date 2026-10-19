import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/sync/sync_service.dart';

final vendorsProvider = FutureProvider.autoDispose((ref) async =>
    await Supabase.instance.client.from('vendor').select('name,category,contact_name,phone,district,rating,gstin').order('category'));
final stockProvider = FutureProvider.autoDispose((ref) async =>
    await Supabase.instance.client.from('v_stock_balance').select('qty, item(name,unit,reorder_level)'));

class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(outboxCountProvider).value ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(children: [
        ListTile(leading: const Icon(Icons.sync), title: const Text('Sync now'), subtitle: Text('$pending records waiting'),
          onTap: () async { await SyncService.instance.pushOutbox(); await SyncService.instance.pullDeltas(); if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Synced'))); }),
        ListTile(leading: const Icon(Icons.store_outlined), title: const Text('Vendors & suppliers'), onTap: () => _push(context, const _VendorsPage())),
        ListTile(leading: const Icon(Icons.inventory_2_outlined), title: const Text('Stock & reorder'), onTap: () => _push(context, const _StockPage())),
        const ListTile(leading: Icon(Icons.groups_outlined), title: Text('Labour & attendance')),
        const ListTile(leading: Icon(Icons.build_outlined), title: Text('Equipment & maintenance')),
        const ListTile(leading: Icon(Icons.verified_user_outlined), title: Text('Compliance & documents')),
        const ListTile(leading: Icon(Icons.language), title: Text('Language · తెలుగు / English')),
        ListTile(leading: const Icon(Icons.logout), title: const Text('Sign out'), onTap: () => Supabase.instance.client.auth.signOut()),
      ]),
    );
  }
  void _push(BuildContext c, Widget w) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => w));
}

class _VendorsPage extends ConsumerWidget {
  const _VendorsPage();
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(appBar: AppBar(title: const Text('Vendors')),
    body: ref.watch(vendorsProvider).when(loading: () => const Center(child: CircularProgressIndicator()), error: (e, _) => Text('$e'),
      data: (rows) => ListView(children: [for (final v in rows) ListTile(title: Text(v['name']), subtitle: Text('${v['category']} · ${v['contact_name']} · ${v['phone']} · ${v['district']}'),
        trailing: Text('★ ${v['rating']}'))])));
}

class _StockPage extends ConsumerWidget {
  const _StockPage();
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(appBar: AppBar(title: const Text('Stock')),
    body: ref.watch(stockProvider).when(loading: () => const Center(child: CircularProgressIndicator()), error: (e, _) => Text('$e'),
      data: (rows) => ListView(children: [for (final s in rows) ListTile(title: Text(s['item']['name']), subtitle: Text('reorder at ${s['item']['reorder_level']} ${s['item']['unit']}'),
        trailing: Text('${s['qty']} ${s['item']['unit']}', style: TextStyle(fontWeight: FontWeight.w700,
          color: (s['qty'] as num) <= (s['item']['reorder_level'] as num? ?? 0) ? Theme.of(context).colorScheme.error : null)))])));
}
