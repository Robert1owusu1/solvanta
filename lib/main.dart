import 'package:flutter/material.dart';

import 'app.dart';
import 'core/api/api_client.dart';
import 'core/storage/data_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The school's data lives in an on-device database (SQLite / IndexedDB);
  // open it — moving anything earlier versions kept in SharedPreferences —
  // before the first screen reads it.
  await DataStore.open();
  // The web app reads its API address from config.json before anything
  // talks to the server (no-op elsewhere).
  await ApiClient.loadRuntimeConfig();
  runApp(const SolvantaApp());
}
