import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart' hide FormData, MultipartFile, Response;

import '../app/config.dart';
import '../app/routes.dart';
import '../app/strings.dart';
import '../models/models.dart';
import 'api_exception.dart';
import 'auth_service.dart';

export 'api_exception.dart';

/// Adds the ID token to every request. A lookup that fails (offline, session over) fails the request
/// with that [ApiException] instead of sending it without a token.
class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this._auth);

  final AuthService _auth;

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    try {
      final token = await _auth.idToken();
      if (token != null) options.headers['Authorization'] = 'Bearer $token';
      handler.next(options);
    } on ApiException catch (e) {
      handler.reject(DioException(requestOptions: options, error: e));
    }
  }
}

/// The only class that talks HTTP to the NetZero API. Only repositories use it.
class ApiClient extends GetxService {
  /// [dio] and [s3] are for tests. [onSessionExpired] runs once when a session ends on its own
  /// (by default: go to the sign-in page).
  ApiClient(this._auth, {Dio? dio, Dio? s3, Future<void> Function()? onSessionExpired})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: AppConfig.apiUrl,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              contentType: Headers.jsonContentType,
            ),
          ),
      // Separate client for S3: no auth interceptor, no base URL. An Authorization header on a
      // presigned request makes S3 reject it. Generous send timeout: a photo on a slow connection.
      _s3 =
          s3 ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 60),
              receiveTimeout: const Duration(seconds: 30),
            ),
          ),
      _onSessionExpired = onSessionExpired ?? _toSignIn {
    _dio.interceptors.add(_AuthInterceptor(_auth));
  }

  final AuthService _auth;
  final Dio _dio;
  final Dio _s3;
  final Future<void> Function() _onSessionExpired;
  Future<void>? _expiring;

  static Future<void> _toSignIn() async {
    await Get.offAllNamed<void>(Routes.signIn);
  }

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) =>
      _send(() => _dio.get<Map<String, dynamic>>(path, queryParameters: query));

  Future<Map<String, dynamic>> post(String path, {Object? data, String? idempotencyKey}) => _send(
    () => _dio.post<Map<String, dynamic>>(
      path,
      data: data,
      options: Options(headers: {'Idempotency-Key': ?idempotencyKey}),
    ),
  );

  Future<Map<String, dynamic>> put(String path, {Object? data}) =>
      _send(() => _dio.put<Map<String, dynamic>>(path, data: data));

  Future<Map<String, dynamic>> patch(String path, {Object? data}) =>
      _send(() => _dio.patch<Map<String, dynamic>>(path, data: data));

  Future<Map<String, dynamic>> delete(String path) => _send(() => _dio.delete<Map<String, dynamic>>(path));

  /// Uploads straight to S3 with a presigned POST: every signed field first, then the file last as
  /// `file` (S3 ignores fields after the file). The file never touches Lambda.
  Future<void> postPresigned(
    PresignedPost signed,
    List<int> bytes, {
    required String contentType,
    required String filename,
  }) async {
    if (bytes.length > signed.maxBytes) throw ApiException(code: 'FILE_TOO_LARGE', message: S.fileTooLarge);
    final form = FormData()
      ..fields.addAll(signed.fields.entries)
      ..files.add(
        MapEntry(
          'file',
          MultipartFile.fromBytes(bytes, filename: filename, contentType: DioMediaType.parse(contentType)),
        ),
      );
    try {
      await _s3.post<void>(signed.uploadUrl, data: form);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      throw status == null
          ? ApiException(code: 'NETWORK', message: S.noConnection)
          : ApiException(code: 'UPLOAD_FAILED', message: S.uploadFailed, status: status);
    }
  }

  /// A 401 gets one forced token refresh and one retry. Only if that fails too is the session over:
  /// then we sign out once (however many requests failed together) and go to sign-in.
  Future<Map<String, dynamic>> _send(Future<Response<Map<String, dynamic>>> Function() request) async {
    final gen = _auth.generation;
    try {
      return (await request()).data ?? const {};
    } on DioException catch (e) {
      final error = mapError(e);
      if (error is SessionExpiredException) {
        await _expire(gen);
        throw error;
      }
      // Not ours to fix: a request from a session that has since ended must not be re-sent with the
      // next person's token.
      if (error.status != 401 || gen != _auth.generation) throw error;

      final String? fresh;
      try {
        fresh = await _auth.refreshAfterUnauthorized(_bearer(e.requestOptions));
      } on SessionExpiredException {
        await _expire(gen);
        rethrow;
      }
      // Null: the session changed while we waited (signed out, or someone else signed in).
      if (fresh == null || gen != _auth.generation) throw error;

      try {
        return (await request()).data ?? const {};
      } on DioException catch (retry) {
        final retryError = mapError(retry);
        if (retryError.status == 401) await _expire(gen);
        throw retryError;
      }
    }
  }

  static String? _bearer(RequestOptions options) {
    final header = options.headers['Authorization'];
    return header is String && header.startsWith('Bearer ') ? header.substring(7) : null;
  }

  /// Ends the session that [gen] belongs to, once. A 401 from a session that has already ended
  /// (or been replaced by another sign-in) changes nothing.
  Future<void> _expire(int gen) async {
    if (gen != _auth.generation) return;
    await (_expiring ??= _endSession().whenComplete(() => _expiring = null));
  }

  Future<void> _endSession() async {
    await _auth.expireSession();
    await _onSessionExpired();
  }

  @visibleForTesting
  static ApiException mapError(DioException e) {
    final inner = e.error;
    if (inner is ApiException) return inner;
    final res = e.response;
    if (res == null) {
      return ApiException(code: 'NETWORK', message: S.noConnection);
    }
    final data = res.data;
    final error = data is Map ? data['error'] : null;
    if (error is! Map) {
      return ApiException(
        code: res.statusCode == 401 ? 'UNAUTHORIZED' : 'HTTP_${res.statusCode}',
        message: res.statusCode == 401 ? S.sessionExpired : S.unexpectedResponse(res.statusCode),
        status: res.statusCode,
      );
    }
    final code = error['code'] is String ? error['code'] as String : 'UNKNOWN';
    final serverMessage = error['message'] is String ? error['message'] as String : null;
    if (code == 'GROUP_NOT_FOUND') return GroupNotFoundException(serverMessage: serverMessage);

    final fields = <String, String>{};
    final details = error['details'];
    if (details is List) {
      for (final d in details.whereType<Map<dynamic, dynamic>>()) {
        final path = d['path'];
        if (path is String && path.isNotEmpty) fields.putIfAbsent(path, () => S.fieldError(path));
      }
    }
    return ApiException(
      code: code,
      message: S.apiError(code),
      status: res.statusCode,
      fieldErrors: fields,
      details: details is List ? List<Object?>.of(details) : const [],
      serverMessage: serverMessage,
    );
  }
}
