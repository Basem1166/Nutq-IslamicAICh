// Central configuration for runtime constants.
// Set at build/run time with `--dart-define=API_BASE_URL=...` to override.
const String kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8000/v1',
);

Uri get apiBaseUri {
  return Uri.parse(kApiBaseUrl.endsWith('/') ? kApiBaseUrl : '$kApiBaseUrl/');
}
