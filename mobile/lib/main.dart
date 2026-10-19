import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

import 'env.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'data/sync/sync_service.dart';

@pragma('vm:entry-point')
void syncDispatcher() {
  // Background sync every 15 min while the app is closed (Android WorkManager / iOS BGTask).
  Workmanager().executeTask((task, input) async {
    await Supabase.initialize(url: Env.supabaseUrl, anonKey: Env.supabaseAnonKey);
    await SyncService.instance.pushOutbox();
    await SyncService.instance.pullDeltas();
    return true;
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: Env.supabaseUrl,
    anonKey: Env.supabaseAnonKey,
    authOptions: const FlutterAuthClientOptions(authFlowType: AuthFlowType.pkce),
  );
  await Workmanager().initialize(syncDispatcher);
  await Workmanager().registerPeriodicTask('poultryos-sync', 'sync',
      frequency: const Duration(minutes: 15), constraints: Constraints(networkType: NetworkType.connected));
  runApp(const ProviderScope(child: PoultryOSApp()));
}

class PoultryOSApp extends ConsumerWidget {
  const PoultryOSApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'PoultryOS',
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      routerConfig: router,
      supportedLocales: const [Locale('en'), Locale('te'), Locale('hi'), Locale('ta'), Locale('kn'), Locale('mr')],
      debugShowCheckedModeBanner: false,
    );
  }
}
