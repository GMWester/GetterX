/// Helpers for Minecraft-style game versions (1.21.11, 26.3, 26.1.2, 25w14a, 1.21.5-pre1).
library;

final _releasePattern = RegExp(r'^\d+(\.\d+)+$');

/// True for full releases such as `1.21.11` or `26.3`; false for snapshots,
/// pre-releases and release candidates.
bool isReleaseGameVersion(String v) => _releasePattern.hasMatch(v.trim());

/// `1.21.11` -> `1.21`, `26.1.2` -> `26.1`, `26.3` -> `26.3`.
String minorGroup(String v) {
  final parts = v.split('.');
  if (parts.length <= 2) return v;
  return '${parts[0]}.${parts[1]}';
}

/// Compares two version strings numerically segment by segment.
/// Non-numeric suffixes (snapshots, -pre1, -rc1) sort before the plain release.
int compareVersions(String a, String b) {
  final pa = _parse(a), pb = _parse(b);
  final n = pa.nums.length > pb.nums.length ? pa.nums.length : pb.nums.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.nums.length ? pa.nums[i] : 0;
    final y = i < pb.nums.length ? pb.nums[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  if (pa.suffix.isEmpty && pb.suffix.isNotEmpty) return 1;
  if (pa.suffix.isNotEmpty && pb.suffix.isEmpty) return -1;
  return pa.suffix.compareTo(pb.suffix);
}

({List<int> nums, String suffix}) _parse(String v) {
  final m = RegExp(r'^(\d+(?:\.\d+)*)(.*)$').firstMatch(v.trim());
  if (m == null) {
    // Weekly snapshots like 25w14a: treat year/week as numbers.
    final s = RegExp(r'^(\d+)w(\d+)([a-z]*)$').firstMatch(v.trim());
    if (s != null) {
      return (nums: [int.parse(s[1]!), int.parse(s[2]!)], suffix: 'snapshot${s[3]}');
    }
    return (nums: const [], suffix: v);
  }
  return (nums: m[1]!.split('.').map(int.parse).toList(), suffix: m[2]!);
}
