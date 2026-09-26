# Calcar mobile, thin client

Render only. No AI run, no provider logic. Foreground WebSocket only,
background is push only.

## Slice 1, scaffold

`lib/main.dart` plus one screen plus one widget test. No backend client,
no proto models, no push. Those land in slices behind this same gate.

## Run

Requires a Flutter SDK, not present on every dev box. With one installed:

```sh
cd mobile
flutter pub get
flutter analyze
flutter test
```

## CI proof

`.github/workflows/mobile-check.yml` installs stable Flutter and runs
`pub get`, `analyze`, `test`. That workflow is the verification for this
directory until a local SDK exists. The workflow installs pinned protoc
36.2, activates `protoc_plugin` via the Flutter SDK's Dart, and generates
Dart models from `proto/calcar/v1/*.proto` into `mobile/lib/gen/`
(git-ignored) before `pub get`, so no hand-copied types enter the tree.
