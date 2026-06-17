/// Thrown when localization initialization fails for a general reason that is
/// not a permission ([PermissionException]) or adapter ([AdapterException]) issue.
class LocalizationException implements Exception {
  /// Human-readable description of the failure.
  final String message;

  /// Creates a [LocalizationException] with the given [message].
  LocalizationException(this.message);

  @override
  String toString() => 'LocalizationException: $message';
}