import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../sync/sync_queue.dart';

/// Raised for any non-2xx response or transport failure. `statusCode` is 0 for
/// network errors so callers can distinguish "unreachable" from "rejected".
class ApiException implements Exception {
  ApiException(this.statusCode, this.message, [this.body]);

  final int statusCode;
  final String message;
  final Map<String, dynamic>? body;

  bool get isNetwork => statusCode == 0;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Thin JSON-over-HTTP client for the SOLVANTA backend.
///
/// The default base URL is `http://127.0.0.1:8080`, which works for the host,
/// an emulator, and a physical device after `adb reverse tcp:8080 tcp:8080`.
/// Override with `--dart-define=SOLVANTA_API=<url>` (or the environment
/// variable `SOLVANTA_API_URL`, useful for tests).
///
/// Offline behaviour: when a **mutating** request (POST/PUT/PATCH/DELETE)
/// fails with a network error it is automatically captured in
/// `SyncQueue.instance` so nothing is silently lost — kind/payload default
/// to `api.<verb> <path>` and `{method, path, body}` (enough to re-issue the
/// request verbatim), and can be customised or disabled per call via
/// [request]. Reads and `/auth/*` payloads are never queued implicitly.
class ApiClient {
  ApiClient({String? baseUrl, http.Client? client, String? token})
      : baseUrl = (baseUrl ?? defaultApiBaseUrl()).replaceFirst(RegExp(r'/+$'), ''),
        _client = client ?? http.Client() {
    // A token from a previous login in this process is shared with every
    // later client, so independently constructed data sources (auth, safety,
    // …) can authenticate without re-logging-in.
    _token = token ?? sharedToken;
    // First client to exist becomes the outbox replayer, so items persisted
    // by a previous offline session are replayed without startup wiring.
    // The lead can still take over with SyncQueue.instance.setHandler(...).
    SyncQueue.instance.registerHandler(_replaySyncItem);
  }

  final String baseUrl;
  final http.Client _client;

  /// Session bearer token shared process-wide once `login()` succeeds. New
  /// [ApiClient]s (e.g. a fresh [RemoteDataSource] in a repository) adopt it,
  /// so API-mode features work beyond auth without re-authentication.
  static String? sharedToken;

  String? _token;

  /// Bearer token attached to every request once `login()` succeeds. Setting
  /// it also publishes it to [sharedToken] for other clients in this process;
  /// clearing it (logout) clears the shared session token as well.
  String? get token => _token;
  set token(String? value) {
    _token = value;
    if (value != null && value.isNotEmpty) {
      sharedToken = value;
    } else {
      sharedToken = null;
    }
  }

  static const _defineKey = String.fromEnvironment('SOLVANTA_API');

  /// Whether an API endpoint was explicitly configured (via `SOLVANTA_API`
  /// dart-define or the `SOLVANTA_API_URL` environment variable), as opposed to
  /// the default localhost fallback.
  static bool get isConfigured =>
      _defineKey.isNotEmpty ||
      (Platform.environment['SOLVANTA_API_URL']?.trim().isNotEmpty ?? false);

  static String defaultApiBaseUrl() {
    if (_defineKey.isNotEmpty) return _defineKey;
    final env = Platform.environment['SOLVANTA_API_URL'];
    if (env != null && env.trim().isNotEmpty) return env.trim();
    return 'http://127.0.0.1:8080';
  }

  Future<dynamic> get(String path) => _send('GET', path, null);
  Future<dynamic> post(String path, [Object? body]) => _send('POST', path, body);
  Future<dynamic> put(String path, [Object? body]) => _send('PUT', path, body);
  Future<dynamic> patch(String path, [Object? body]) =>
      _send('PATCH', path, body);
  Future<dynamic> delete(String path) => _send('DELETE', path, null);

  /// Sends an arbitrary request with explicit outbox control. This is the
  /// escape hatch for callers that need to customise what a network failure
  /// queues: Dart doesn't allow named parameters alongside post/put/patch/
  /// delete's optional positional `body`, so those keep their exact public
  /// signatures (with the sensible auto-queue default) and this method
  /// carries the optional named parameters:
  ///
  /// * [syncKind] — outbox category (default `api.<verb> <path>`), e.g.
  ///   pass `'message.send'` so your replay handler can dispatch on it.
  /// * [syncPayload] — merged *over* the built-in `method`/`path`/`body`
  ///   replay fields (your keys win on clashes).
  /// * [offlineQueue] — force queueing on or off; null (default) applies
  ///   the policy: mutating, non-`/auth` requests queue, reads never do.
  Future<dynamic> request(
    String method,
    String path, {
    Object? body,
    String? syncKind,
    Map<String, dynamic>? syncPayload,
    bool? offlineQueue,
  }) =>
      _send(
        method,
        path,
        body,
        syncKind: syncKind,
        syncPayload: syncPayload,
        offlineQueue: offlineQueue,
      );

  Future<dynamic> _send(
    String method,
    String path,
    Object? body, {
    String? syncKind,
    Map<String, dynamic>? syncPayload,
    bool? offlineQueue,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = <String, String>{
      if (body != null) 'Content-Type': 'application/json',
      if (token != null && token!.isNotEmpty) 'Authorization': 'Bearer $token',
    };

    // --- Offline outbox decision ---------------------------------------
    final mutating = method != 'GET' && method != 'HEAD';
    // An explicit offlineQueue always wins; otherwise queue only mutating,
    // non-auth requests. Auth payloads (passwords!) must never be persisted
    // implicitly, and reads are re-fetchable — neither queues by default.
    final shouldQueue = offlineQueue ?? (mutating && !path.startsWith('/auth'));
    final kind = syncKind ?? 'api.${method.toLowerCase()} $path';
    final payload = <String, dynamic>{
      'method': method,
      'path': path,
      'body': body,
      ...?syncPayload,
    };

    // Network failures are queued best-effort; the original error is still
    // what callers see (the outbox must never mask it).
    ApiException networkFailure(String message) {
      if (shouldQueue) _queueOff(kind, payload);
      return ApiException(0, message);
    }

    final start = DateTime.now();
    try {
      final res = switch (method) {
        'GET' => await _client.get(uri, headers: headers),
        'POST' => await _client.post(uri, headers: headers, body: _enc(body)),
        'PUT' => await _client.put(uri, headers: headers, body: _enc(body)),
        'PATCH' => await _client.patch(uri, headers: headers, body: _enc(body)),
        'DELETE' => await _client.delete(uri, headers: headers),
        _ => throw ArgumentError('unsupported method $method'),
      };
      return _decode(res);
    } on SocketException {
      throw networkFailure('Cannot reach $baseUrl');
    } on HttpException catch (e) {
      throw networkFailure(e.message);
    } on TimeoutException {
      throw networkFailure(
          'Timed out after ${DateTime.now().difference(start)}');
    } on http.ClientException catch (e) {
      throw networkFailure(e.message);
    }
  }

  /// Best-effort enqueue — never throws or rejects, because the caller is
  /// already throwing the real [ApiException].
  Future<void> _queueOff(String kind, Map<String, dynamic> payload) async {
    try {
      await SyncQueue.instance.enqueue(kind, payload);
    } catch (e) {
      debugPrint('[ApiClient] outbox enqueue failed: $e');
    }
  }

  /// Replays an outbox item created by [_send] by re-issuing the exact
  /// request with queueing disabled (so a replay can never enqueue itself).
  /// Registered with `SyncQueue` from the constructor.
  ///
  /// Result mapping: success → true (item removed); network error or 5xx →
  /// false (kept, `lastError` + backoff); other HTTP rejections (4xx) →
  /// dropped with a loud log, since replaying a permanently rejected
  /// operation would poison the outbox forever.
  Future<bool> _replaySyncItem(SyncItem item) async {
    final method = item.payload['method'];
    final path = item.payload['path'];
    if (method is! String || path is! String) {
      debugPrint('[ApiClient] cannot replay ${item.id} (${item.kind}): '
          'missing method/path — register a custom handler');
      return false;
    }
    try {
      await _send(method, path, item.payload['body'], offlineQueue: false);
      return true;
    } on ApiException catch (e) {
      if (e.isNetwork || e.statusCode >= 500) return false;
      debugPrint('[ApiClient] dropping rejected outbox item '
          '${item.id} (${item.kind}): $e');
      return true;
    } catch (e) {
      debugPrint('[ApiClient] replay of ${item.id} failed: $e');
      return false;
    }
  }

  Object? _enc(Object? body) => body == null ? null : jsonEncode(body);

  dynamic _decode(http.Response res) {
    dynamic data;
    try {
      data = res.body.isEmpty ? null : jsonDecode(res.body);
    } on FormatException {
      data = null;
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return data;

    var message = 'Request failed (${res.statusCode})';
    Map<String, dynamic>? map = data is Map ? Map<String, dynamic>.from(data) : null;
    if (map != null && map['error'] is String) message = map['error'] as String;
    throw ApiException(res.statusCode, message, map);
  }

  void close() => _client.close();
}