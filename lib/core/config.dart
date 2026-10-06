// Central configuration for runtime constants.
// Set at build/run time with `--dart-define=API_BASE_URL=...` to override.
const String kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://rectangle-freeness-essence.ngrok-free.dev/v1',
);

Uri get apiBaseUri {
  return Uri.parse(kApiBaseUrl.endsWith('/') ? kApiBaseUrl : '$kApiBaseUrl/');
}

/// Headers sent with every search-service request. The ngrok header skips the
/// free-tier browser interstitial so responses are always the API's JSON.
const Map<String, String> kApiHeaders = {
  'ngrok-skip-browser-warning': 'true',
};
