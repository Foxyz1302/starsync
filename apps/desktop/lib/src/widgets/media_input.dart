({String mediaPath, String linkUrl}) parseMediaInput(String input) {
  final trimmed = input.trim();
  final lower = trimmed.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return (mediaPath: '', linkUrl: trimmed);
  }
  return (mediaPath: trimmed, linkUrl: '');
}
