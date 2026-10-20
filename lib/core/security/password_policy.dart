/// The API's password policy (backend `security.ValidatePasswordPolicy`), so
/// a form can turn away a password the server would refuse.
///
/// Returns what is missing, or null when [password] is acceptable.
String? passwordProblem(String password) {
  if (password.length < 8) return 'Use at least 8 characters';
  if (password.length > 72) return 'Use 72 characters or fewer';
  final hasLower = password.contains(RegExp(r'[a-z]'));
  final hasUpper = password.contains(RegExp(r'[A-Z]'));
  final hasDigit = password.contains(RegExp(r'[0-9]'));
  if (!hasLower || !hasUpper || !hasDigit) {
    return 'Include upper- and lower-case letters and a digit';
  }
  return null;
}
