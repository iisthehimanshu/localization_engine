class LocalizationException implements Exception {
  final String message;
  LocalizationException(this.message);

  @override
  String toString() => 'LocalizationException: $message';
}