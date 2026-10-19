import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Hands a generated file (PDF, PNG, CSV…) to the user.
///
/// Mobile/desktop: writes it to the temp directory and opens the share sheet.
/// Web: there is no file system or temp directory, so the browser downloads
/// it instead (`XFile.saveTo` on web triggers an anchor download).
Future<void> saveAndShareFile(
    Uint8List bytes, String fileName, String mimeType) async {
  if (kIsWeb) {
    await XFile.fromData(bytes, name: fileName, mimeType: mimeType)
        .saveTo(fileName);
    return;
  }
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$fileName');
  await file.writeAsBytes(bytes, flush: true);
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, mimeType: mimeType)],
      fileNameOverrides: [fileName],
    ),
  );
}
