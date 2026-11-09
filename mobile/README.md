# NetZero mobile

Flutter + GetX client for the NetZero API. See the [root README](../README.md) for setup.

```bash
flutter run --dart-define-from-file=env/dev.json   # env/dev.json comes from backend/scripts/stack-outputs.sh dev
flutter test
```

`lib/` layout: `domain/` (cents parsing/formatting only), `models/` (hand-written fromJson), `services/`
(Cognito auth, Dio ApiClient), `repositories/` (the only users of ApiClient), `controllers/` (GetX state),
`pages/` (widgets), `app/` (routes + bindings, theme, config).
