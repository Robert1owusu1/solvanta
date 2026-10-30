import 'package:flutter/material.dart';

import 'app.dart';
import 'core/api/api_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The web app reads its API address from config.json before anything
  // talks to the server (no-op elsewhere).
  await ApiClient.loadRuntimeConfig();
  runApp(const SolvantaApp());
}
