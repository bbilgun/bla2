// Build-time settings passed in with `flutter run --dart-define-from-file=env/dev.json`.
// `backend/scripts/stack-outputs.sh dev` writes that file from the deployed stack.

/// Values baked into the build by `--dart-define`. Empty strings mean "not set".
abstract final class AppConfig {
  /// Base URL of the HTTP API, without a trailing slash.
  static const apiUrl = String.fromEnvironment('API_URL');

  /// AWS region of the Cognito user pool. AmazonCognitoBackend works the region out from [userPoolId],
  /// so this only mirrors the env file.
  static const cognitoRegion = String.fromEnvironment('COGNITO_REGION', defaultValue: 'ap-northeast-1');

  /// Cognito user pool the app signs users into.
  static const userPoolId = String.fromEnvironment('COGNITO_USER_POOL_ID');

  /// Cognito app client id. It is a public client with no secret.
  static const clientId = String.fromEnvironment('COGNITO_CLIENT_ID');

  /// Sentry DSN for crash reports. Left empty, crash reporting is off.
  static const sentryDsn = String.fromEnvironment('SENTRY_DSN');

  /// Whether the build has everything it needs to talk to the backend.
  static bool get isConfigured => apiUrl.isNotEmpty && userPoolId.isNotEmpty && clientId.isNotEmpty;
}
