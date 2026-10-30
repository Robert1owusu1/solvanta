import 'data_store.dart';

/// No database on this platform: SharedPreferences it is.
Future<KvBackend?> openPlatformBackend() async => null;
