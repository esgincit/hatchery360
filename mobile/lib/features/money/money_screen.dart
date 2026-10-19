import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _inr = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);

final billsProvider = FutureProvider.autoDispose((ref) async =>
    await Supabase.instance.client.from('bill').select('bill_no,category,due_date,total,paid,status, vendor(name)').neq('status', 'paid').order('due_date'));
final invoicesProvider = FutureProvider.autoDispose((ref) async =>
    await Supabase.instance.client.from('invoice').select('invoice_no,product,qty,unit,rate,due_date,total,paid,status, customer(name)').neq('status', 'paid').order('due_date'));

class MoneyScreen extends ConsumerWidget {
  const MoneyScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bills = ref.watch(billsProvider), inv = ref.watch(invoicesProvider);
    return DefaultTabController(length: 2, child: Scaffold(
      appBar: AppBar(title: const Text('Money'), bottom: const TabBar(tabs: [Tab(text: 'Payables'), Tab(text: 'Receivables')])),
      body: TabBarView(children: [
        bills.when(loading: () => const Center(child: CircularProgressIndicator()), error: (e, _) => Text('$e'),
          data: (rows) => _Ageing(rows, (r) => r['vendor']['name'], (r) => '${r['bill_no']} · ${r['category']}')),
        inv.when(loading: () => const Center(child: CircularProgressIndicator()), error: (e, _) => Text('$e'),
          data: (rows) => _Ageing(rows, (r) => r['customer']['name'], (r) => '${r['invoice_no']} · ${r['qty']} ${r['unit']} @ ₹${r['rate']}')),
      ]),
    ));
  }
}

class _Ageing extends StatelessWidget {
  const _Ageing(this.rows, this.party, this.sub);
  final List rows; final String Function(dynamic) party, sub;
  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final b = <String, num>{'Not due': 0, '1–30': 0, '31–60': 0, '60+': 0};
    for (final r in rows) {
      final o = (r['total'] as num) - (r['paid'] as num); final d = today.difference(DateTime.parse(r['due_date'])).inDays;
      b[d <= 0 ? 'Not due' : d <= 30 ? '1–30' : d <= 60 ? '31–60' : '60+'] = b[d <= 0 ? 'Not due' : d <= 30 ? '1–30' : d <= 60 ? '31–60' : '60+']! + o;
    }
    final total = b.values.fold<num>(0, (a, x) => a + x);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Outstanding ${_inr.format(total)}', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Wrap(spacing: 12, children: [for (final e in b.entries) Text('${e.key}: ${_inr.format(e.value)}')]),
      ]))),
      for (final r in rows) ListTile(title: Text(party(r)), subtitle: Text('${sub(r)} · due ${r['due_date']}'),
        trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(_inr.format((r['total'] as num) - (r['paid'] as num)), style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(r['status'], style: TextStyle(color: r['status'] == 'overdue' ? Theme.of(context).colorScheme.error : null))])),
    ]);
  }
}
