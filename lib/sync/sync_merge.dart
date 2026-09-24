import 'dart:convert';

typedef SyncJson = Map<String, Object?>;
String canonicalJson(Object? value) {
  Object? sorted(Object? v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: sorted(v[key])};
    }
    if (v is List) return v.map(sorted).toList();
    return v;
  }

  return jsonEncode(sorted(value));
}

const _missing = Object();
bool _same(Object? a, Object? b) =>
    identical(a, _missing) || identical(b, _missing)
    ? identical(a, b)
    : canonicalJson(a) == canonicalJson(b);

class SyncConflict {
  const SyncConflict(this.path, this.local, this.remote);
  final String path;
  final Object? local;
  final Object? remote;
}

class SyncMergeResult {
  const SyncMergeResult(this.data, this.conflicts);
  final SyncJson data;
  final List<SyncConflict> conflicts;
}

/// Null entities are durable tombstones. Unresolved conflicts must never be written.
SyncMergeResult mergeSyncData(
  SyncJson base,
  SyncJson local,
  SyncJson remote, {
  Map<String, bool> useRemote = const {},
}) {
  final conflicts = <SyncConflict>[];
  Object? merge(Object? b, Object? l, Object? r, List<String> path) {
    if (_same(l, r)) return l;
    if (_same(l, b)) return r;
    if (_same(r, b)) return l;
    if (path.lastOrNull == 'updatedAt' && l is String && r is String) {
      return l.compareTo(r) >= 0 ? l : r;
    }
    // Keep a photo and its grading parameters together.
    final record = path.length >= 2 && path[path.length - 2] == 'visitRecords';
    if (!record &&
        l is Map &&
        r is Map &&
        (b is Map || identical(b, _missing))) {
      final before = b is Map ? b : const {};
      final keys = {
        ...before.keys,
        ...l.keys,
        ...r.keys,
      }.cast<String>().toList()..sort();
      final result = <String, Object?>{};
      for (final key in keys) {
        final value = merge(
          before.containsKey(key) ? before[key] : _missing,
          l.containsKey(key) ? l[key] : _missing,
          r.containsKey(key) ? r[key] : _missing,
          [...path, key],
        );
        if (!identical(value, _missing)) result[key] = value;
      }
      return result;
    }
    final key = path.map(Uri.encodeComponent).join('/');
    if (useRemote.containsKey(key)) return useRemote[key]! ? r : l;
    conflicts.add(
      SyncConflict(
        key,
        identical(l, _missing) ? null : l,
        identical(r, _missing) ? null : r,
      ),
    );
    return l;
  }

  return SyncMergeResult(
    Map<String, Object?>.from(merge(base, local, remote, []) as Map),
    conflicts,
  );
}

SyncJson addSyncTombstones(SyncJson local, SyncJson baseline) {
  const collections = {'plans', 'works', 'points', 'groups', 'visitRecords'};
  Object? walk(Object? now, Object? before, String key) {
    if (now is! Map) return now;
    final result = <String, Object?>{};
    final old = before is Map ? before : const {};
    for (final entry in now.entries) {
      final k = entry.key as String;
      result[k] = walk(entry.value, old[k], k);
    }
    if (collections.contains(key)) {
      for (final k in old.keys.cast<String>()) {
        if (!result.containsKey(k)) result[k] = null;
      }
    }
    return result;
  }

  return Map<String, Object?>.from(walk(local, baseline, '') as Map);
}
