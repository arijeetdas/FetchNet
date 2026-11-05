String formatBytes(num? bytes, {int decimals = 1}) {
  if (bytes == null || bytes <= 0) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : decimals)} ${units[unit]}';
}

String formatSpeed(num? bytesPerSecond) =>
    bytesPerSecond == null || bytesPerSecond <= 0 ? '' : '${formatBytes(bytesPerSecond)}/s';

String formatDuration(num? seconds) {
  if (seconds == null || seconds <= 0) return '';
  final s = seconds.round();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
  return h > 0 ? '$h:$mm:${sec.toString().padLeft(2, '0')}' : '$mm:${sec.toString().padLeft(2, '0')}';
}

String formatEta(int? seconds) {
  if (seconds == null || seconds <= 0) return '';
  if (seconds < 60) return '${seconds}s left';
  if (seconds < 3600) return '${seconds ~/ 60}m ${seconds % 60}s left';
  return '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}m left';
}

String formatCount(int? n) {
  if (n == null) return '';
  if (n >= 1000000000) return '${(n / 1e9).toStringAsFixed(1)}B';
  if (n >= 1000000) return '${(n / 1e6).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1e3).toStringAsFixed(1)}K';
  return '$n';
}

String formatDate(DateTime d) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final now = DateTime.now();
  final time = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  if (d.year == now.year && d.month == now.month && d.day == now.day) return 'Today, $time';
  final y = now.subtract(const Duration(days: 1));
  if (d.year == y.year && d.month == y.month && d.day == y.day) return 'Yesterday, $time';
  return '${d.day} ${months[d.month - 1]}${d.year == now.year ? '' : ' ${d.year}'}, $time';
}

/// Pulls the first http(s) URL out of shared / pasted text.
String? extractUrl(String text) {
  final match = RegExp(r'https?://[^\s<>"]+', caseSensitive: false).firstMatch(text);
  if (match != null) return match.group(0)!.replaceAll(RegExp(r'[).,;!]+$'), '');
  final trimmed = text.trim();
  if (RegExp(r'^[\w-]+(\.[\w-]+)+(/\S*)?$').hasMatch(trimmed)) return 'https://$trimmed';
  return null;
}
