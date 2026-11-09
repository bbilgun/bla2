import 'package:get/get.dart';

import '../models/models.dart';

/// A newest-first list loaded a page at a time with a cursor.
///
/// - [reload] / [setFirstPage] start over, and a [loadMore] still in flight is thrown away when it
///   lands (a generation check), so pages can't be appended out of order or onto a fresh list.
/// - After a failed [loadMore], [shouldAutoLoad] stays false until [loadMore] is called again
///   (the "load more" button), so a list that keeps failing doesn't retry in a tight loop.
class CursorList<T> {
  CursorList(this._fetchPage);

  final Future<CursorPage<T>> Function(String? cursor) _fetchPage;

  final items = <T>[].obs;
  final _loadingMore = false.obs;
  final _hasMore = false.obs;
  final _failed = false.obs;
  String? _cursor;
  int _generation = 0;

  bool get loadingMore => _loadingMore.value;
  bool get hasMore => _hasMore.value;
  bool get loadMoreFailed => _failed.value;

  /// The list may fetch the next page by itself when its last row is built.
  bool get shouldAutoLoad => _hasMore.value && !_failed.value && !_loadingMore.value;

  /// Fetches the first page and replaces everything with it. Throws on failure (the list is kept).
  Future<void> reload() async {
    final gen = ++_generation;
    final page = await _fetchPage(null);
    if (gen == _generation) setFirstPage(page);
  }

  /// Replaces everything with [page], fetched by the caller (e.g. together with other data).
  void setFirstPage(CursorPage<T> page) {
    _generation++;
    items.assignAll(page.items);
    _cursor = page.nextCursor;
    _hasMore.value = page.nextCursor != null;
    _failed.value = false;
    _loadingMore.value = false;
  }

  /// Appends the next page. Rethrows a failure after marking it, so the caller can say so.
  Future<void> loadMore() async {
    final cursor = _cursor;
    if (cursor == null || _loadingMore.value) return;
    final gen = _generation;
    _loadingMore.value = true;
    _failed.value = false;
    try {
      final page = await _fetchPage(cursor);
      if (gen != _generation) return; // the list started over meanwhile
      items.addAll(page.items);
      _cursor = page.nextCursor;
      _hasMore.value = page.nextCursor != null;
    } catch (_) {
      if (gen == _generation) _failed.value = true;
      rethrow;
    } finally {
      if (gen == _generation) _loadingMore.value = false;
    }
  }

  /// Removes one row (it was deleted on the server) without refetching.
  void removeWhere(bool Function(T item) test) => items.removeWhere(test);
}
