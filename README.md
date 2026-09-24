# solvanta

school-management client (Flutter) + production Go API (see `backend/README.md`).

## Live API wiring

The app can run fully offline (seeded `LocalStore`) or against the live Go API.
When an API is configured, `ApiClient` is enabled and repositories read through
`RemoteDataSource` (`lib/core/api/`) while still mirroring results into the
local store. Configuration priority (`lib/core/api/api_client.dart`):

1. `--dart-define=SOLVANTA_API=http://…`
2. env `SOLVANTA_API_URL`
3. default `http://127.0.0.1:8080`

Start the backend (in-memory or Postgres) per `backend/README.md`, then run the
live-parity suite — it asserts the app's seed, models, and repository reads are
byte-for-byte compatible with what the API returns:

```sh
flutter test test/api_parity_test.dart
```

On a device/emulator, bridge the host port instead of editing the URL:

```sh
adb reverse tcp:8080 tcp:8080
```

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
