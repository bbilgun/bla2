/// Build-time configuration, injected with:
///   flutter run --dart-define-from-file=env/dev.json
///
/// `backend/scripts/stack-outputs.sh dev` writes env/dev.json from the deployed stack.
class AppConfig {
  static const apiUrl = String.fromEnvironment('API_URL');
  static const cognitoRegion = String.fromEnvironment('COGNITO_REGION', defaultValue: 'ap-northeast-1');
  static const userPoolId = String.fromEnvironment('COGNITO_USER_POOL_ID');
  static const clientId = String.fromEnvironment('COGNITO_CLIENT_ID');

  static bool get isConfigured => apiUrl.isNotEmpty && userPoolId.isNotEmpty && clientId.isNotEmpty;
}
