import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// On-device hashing for secrets that used to live in SharedPreferences as
/// plain text: the app-lock PIN and the local copy of each account's password.
///
/// Why this exists — a SharedPreferences dump (root, `adb backup`, a stolen
/// device with USB debugging, or anyone reading the app's own files dir) handed
/// over a ready-to-use PIN/password. Salting means each secret has to be
/// attacked on its own, and stretching raises the cost of doing so.
///
/// Scope: this is a *device-local* deterrent, not a password KDF. Real
/// credential verification still happens on the backend; nothing here replaces
/// that. It only removes the usable secret from the file.
///
/// Stored shape is `v2$<salt>$<iterations>$<hex digest>`. The `v2` prefix is
/// what makes migration possible: anything without it is a legacy plain value,
/// so it can be verified once and then rewritten hashed (see
/// [verifySecret], which transparently accepts both forms).
const String kSecretHashPrefix = 'v2';

/// Iteration count for the stretch. Recorded inside each stored value so
/// raising it later never invalidates secrets written with an older count.
const int kSecretHashIterations = 10000;

const int _saltBytes = 16;

/// True when [stored] is already in hashed form (and must not be re-hashed).
bool isHashedSecret(String stored) => stored.startsWith('$kSecretHashPrefix\$');

/// Hashes [value] with a fresh random salt, ready to persist.
///
/// Passing an already-hashed value returns it unchanged, so callers that may
/// hold either form (e.g. re-saving a user loaded from disk) are safe.
String hashSecret(String value) {
  if (value.isEmpty) return value;
  if (isHashedSecret(value)) return value;

  final rng = Random.secure();
  final saltHex = List<int>.generate(_saltBytes, (_) => rng.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  return '$kSecretHashPrefix\$$saltHex\$$kSecretHashIterations\$'
      '${_stretch(saltHex, value, kSecretHashIterations)}';
}

/// Verifies [value] against [stored], accepting both the hashed form and a
/// legacy plain value so an install written before migration still unlocks.
///
/// Callers should re-write with [hashSecret] as soon as a legacy value
/// verifies — that is how the plain text actually leaves the file.
bool verifySecret(String value, String stored) {
  if (stored.isEmpty || value.isEmpty) return false;

  if (!isHashedSecret(stored)) {
    // Legacy plain text: compare, then let the caller upgrade it.
    return _constantTimeEquals(value, stored);
  }

  final parts = stored.split('\$');
  if (parts.length != 4 || parts[0] != kSecretHashPrefix) return false;

  final iterations = int.tryParse(parts[2]) ?? 0;
  if (iterations <= 0) return false;

  final actual = _stretch(parts[1], value, iterations);
  return _constantTimeEquals(actual, parts[3]);
}

String _stretch(String saltHex, String value, int iterations) {
  var digest = sha256.convert(utf8.encode('$saltHex:$value'));
  for (var i = 1; i < iterations; i++) {
    digest = sha256.convert(digest.bytes);
  }
  return digest.toString();
}

/// Length-independent comparison so a wrong-length guess doesn't leak via the
/// early return.
bool _constantTimeEquals(String a, String b) {
  final ab = utf8.encode(a);
  final bb = utf8.encode(b);
  var diff = ab.length == bb.length ? 0 : 1;
  for (var i = 0; i < ab.length && i < bb.length; i++) {
    diff |= ab[i] ^ bb[i];
  }
  return diff == 0;
}
