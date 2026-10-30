import 'package:idb_shim/idb_browser.dart';

import 'data_store.dart';
import 'idb_backend.dart';

/// IndexedDB in the browser: room for a whole school, unlike localStorage.
Future<KvBackend?> openPlatformBackend() => IdbBackend.open(idbFactoryBrowser);
