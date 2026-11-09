// A list that loads a page at a time, shared by the groups, expenses, bills and payments lists.
import 'package:get/get.dart';

import '../models/models.dart';

/// A newest-first list loaded a page at a time with a cursor.
///
/// Starting over with [reload] or [setFirstPage] makes any [loadMore] still in flight throw its page
/// away when it lands, so pages can't be appended out of order or onto a fresh list. After a failed
/// [loadMore], [shouldAutoLoad] stays false until [loadMore] is called again from the "load more"
/// button, so a list that keeps failing doesn't retry in a loop.
class CursorList<T> {
  /// [fetchPage] gets one page, starting after the given cursor, or the first page for null.
  CursorList(this._fetchPage);

  final Future<CursorPage<T>> Function(String? cursor) _fetchPage;

  /// The rows loaded so far.
  final items = <T>[].obs;
  final _loadingMore = false.obs;
  final _hasMore = false.obs;
  final _failed = false.obs;
  String? _cursor;
  int _generation = 0;

  /// Whether the next page is being fetched.
  bool get loadingMore => _loadingMore.value;

  /// Whether the server has more pages.
  bool get hasMore => _hasMore.value;

  /// Whether the last [loadMore] failed.
  bool get loadMoreFailed => _failed.value;

  /// Whether the list may fetch the next page by itself when its last row is built.
  bool get shouldAutoLoad => _hasMore.value && !_failed.value && !_loadingMore.value;

  /// Fetches the first page and replaces everything with it. On failure it throws and keeps the list.
  Future<void> reload() async {
    _generation++;
    final generation = _generation;
    final page = await _fetchPage(null);
    if (generation == _generation) setFirstPage(page);
  }

  /// Replaces everything with [page], which the caller fetched, for example together with other data.
  void setFirstPage(CursorPage<T> page) {
    _generation++;
    items.assignAll(page.items);
    _cursor = page.nextCursor;
    _hasMore.value = page.nextCursor != null;
    _failed.value = false;
    _loadingMore.value = false;
  }

  /// Appends the next page. A failure is recorded in [loadMoreFailed] and rethrown, so the caller
  /// can tell the user.
  Future<void> loadMore() async {
    final cursor = _cursor;
    if (cursor == null || _loadingMore.value) return;
    final generation = _generation;
    _loadingMore.value = true;
    _failed.value = false;
    try {
      final page = await _fetchPage(cursor);
      // The list started over while this page was loading.
      if (generation != _generation) return;
      items.addAll(page.items);
      _cursor = page.nextCursor;
      _hasMore.value = page.nextCursor != null;
    } catch (_) {
      if (generation == _generation) _failed.value = true;
      rethrow;
    } finally {
      if (generation == _generation) _loadingMore.value = false;
    }
  }

  /// Drops rows that were deleted on the server, without refetching.
  void removeWhere(bool Function(T item) test) => items.removeWhere(test);
}
