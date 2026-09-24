import '../settings/app_settings.dart';

/// Offline-lite / data-saver helpers.
///
/// Everything here reads `AppSettings.instance.dataSaver` live, so flipping
/// the *Data saver* switch in settings takes effect immediately without any
/// caller re-wiring. Repositories use these three functions to prefer the
/// cached local store over the network when the user is watching their
/// data usage.
///
/// Typical use in a repository:
///
/// ```dart
/// if (shouldSkipHeavyFetch(lastFetched: lastFetch, tier: CacheTier.heavy)) {
///   return localStore.loadThings();      // serve the cache
/// }
/// return remote.fetchThings().then(save); // otherwise hit the network
/// ```

/// The data-saver / offline-lite master switch (`AppSettings.dataSaver`).
bool get offlineLite => AppSettings.instance.dataSaver;

/// Freshness buckets for [cacheTtl].
enum CacheTier {
  /// Small, cheap payloads (lists of ids, flags): 5 minutes.
  light,

  /// Everyday reads (rosters, announcements): 15 minutes.
  normal,

  /// Expensive payloads (reports, attachments, bulk exports): 60 minutes.
  heavy,
}

/// How long a cached payload of [tier] stays fresh enough to serve without
/// hitting the network.
///
/// Offline-lite multiplies every window ×8 (light 40 min, normal 2 h,
/// heavy 8 h) so a data-saver session reuses local copies far longer.
Duration cacheTtl(CacheTier tier) {
  final base = switch (tier) {
    CacheTier.light => const Duration(minutes: 5),
    CacheTier.normal => const Duration(minutes: 15),
    CacheTier.heavy => const Duration(hours: 1),
  };
  return offlineLite ? base * 8 : base;
}

/// Should a repository skip its expensive network fetch and serve cached
/// local data instead?
///
/// Always false while data saver is off. With data saver on, it is true
/// when there is no known fetch time at all (any local copy beats a heavy
/// download) or when the cache is younger than [cacheTtl] for [tier].
bool shouldSkipHeavyFetch({
  DateTime? lastFetched,
  CacheTier tier = CacheTier.normal,
}) {
  if (!offlineLite) return false;
  if (lastFetched == null) return true;
  return DateTime.now().difference(lastFetched) < cacheTtl(tier);
}
