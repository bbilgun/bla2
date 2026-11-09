// The HTTP client for the NetZero API and for direct uploads to S3.
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

/// Adds the ID token to every request. If getting the token fails, the request fails with that
/// [ApiException] instead of going out without a token.
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

/// Sends requests to the NetZero API with the user's token, and turns every failure into an
/// [ApiException]. Repositories are its only callers.
class ApiClient extends GetxService {
  /// [dio] and [s3] let tests supply fake HTTP clients. [onSessionExpired] runs once when the session
  /// ends because the API kept answering 401, and by default goes to the sign-in page.
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
      // S3 gets its own client with no auth interceptor, because S3 rejects a presigned request that
      // also carries an Authorization header. The long send timeout allows for photos on slow networks.
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

  /// GETs [path] and returns the decoded JSON body.
  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) =>
      _send(() => _dio.get<Map<String, dynamic>>(path, queryParameters: query));

  /// POSTs [data] as JSON. Pass [idempotencyKey] for writes that create money records, so a retry
  /// of the same save can't create a second one.
  Future<Map<String, dynamic>> post(String path, {Object? data, String? idempotencyKey}) => _send(
    () => _dio.post<Map<String, dynamic>>(
      path,
      data: data,
      options: Options(headers: {'Idempotency-Key': ?idempotencyKey}),
    ),
  );

  /// PUTs [data] as JSON.
  Future<Map<String, dynamic>> put(String path, {Object? data}) =>
      _send(() => _dio.put<Map<String, dynamic>>(path, data: data));

  /// PATCHes [data] as JSON.
  Future<Map<String, dynamic>> patch(String path, {Object? data}) =>
      _send(() => _dio.patch<Map<String, dynamic>>(path, data: data));

  /// DELETEs [path].
  Future<Map<String, dynamic>> delete(String path) => _send(() => _dio.delete<Map<String, dynamic>>(path));

  /// Uploads a file straight to S3 using a presigned POST from the API, so the bytes never pass
  /// through Lambda. Throws `FILE_TOO_LARGE` before sending anything bigger than the signed limit.
  Future<void> postPresigned(
    PresignedPost signed,
    List<int> bytes, {
    required String contentType,
    required String filename,
  }) async {
    if (bytes.length > signed.maxBytes) throw ApiException(code: 'FILE_TOO_LARGE', message: S.fileTooLarge);
    // S3 ignores any field after the file, so the signed fields go first.
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
      if (status == null) {
        throw ApiException(code: 'NETWORK', message: S.noConnection);
      }
      throw ApiException(code: 'UPLOAD_FAILED', message: S.uploadFailed, status: status);
    }
  }

  // Sends a request. A 401 gets one forced token refresh and one retry. If the retry is also refused,
  // the session is over: we sign out once, however many requests failed together, and go to sign-in.
  Future<Map<String, dynamic>> _send(Future<Response<Map<String, dynamic>>> Function() request) async {
    final generation = _auth.generation;
    try {
      return (await request()).data ?? const {};
    } on DioException catch (e) {
      final error = mapError(e);
      if (error is SessionExpiredException) {
        await _expire(generation);
        throw error;
      }
      // A request from a session that has since ended must not be re-sent with the next user's token.
      if (error.status != 401 || generation != _auth.generation) throw error;

      final String? freshToken;
      try {
        freshToken = await _auth.refreshAfterUnauthorized(_bearer(e.requestOptions));
      } on SessionExpiredException {
        await _expire(generation);
        rethrow;
      }
      // A null token means the session changed while we waited.
      if (freshToken == null || generation != _auth.generation) throw error;

      try {
        return (await request()).data ?? const {};
      } on DioException catch (retry) {
        final retryError = mapError(retry);
        if (retryError.status == 401) await _expire(generation);
        throw retryError;
      }
    }
  }

  static String? _bearer(RequestOptions options) {
    final header = options.headers['Authorization'];
    return header is String && header.startsWith('Bearer ') ? header.substring(7) : null;
  }

  // Ends the session that [generation] belongs to, once. A 401 from a session that has already ended,
  // or been replaced by another sign-in, changes nothing.
  Future<void> _expire(int generation) async {
    if (generation != _auth.generation) return;
    await (_expiring ??= _endSession().whenComplete(() => _expiring = null));
  }

  Future<void> _endSession() async {
    await _auth.expireSession();
    await _onSessionExpired();
  }

  /// Turns a Dio failure into an [ApiException] with Mongolian text. No response at all becomes
  /// `NETWORK`. A response without the API's error shape, such as one from API Gateway, becomes `HTTP_<status>`.
  @visibleForTesting
  static ApiException mapError(DioException e) {
    final inner = e.error;
    if (inner is ApiException) return inner;
    final response = e.response;
    if (response == null) {
      return ApiException(code: 'NETWORK', message: S.noConnection);
    }
    final status = response.statusCode;
    final data = response.data;
    final error = data is Map ? data['error'] : null;
    if (error is! Map) {
      if (status == 401) {
        return ApiException(code: 'UNAUTHORIZED', message: S.sessionExpired, status: status);
      }
      return ApiException(code: 'HTTP_$status', message: S.unexpectedResponse(status), status: status);
    }
    final code = error['code'] is String ? error['code'] as String : 'UNKNOWN';
    final serverMessage = error['message'] is String ? error['message'] as String : null;
    if (code == 'GROUP_NOT_FOUND') return GroupNotFoundException(serverMessage: serverMessage);

    final fields = <String, String>{};
    final details = error['details'];
    if (details is List) {
      for (final detail in details.whereType<Map<dynamic, dynamic>>()) {
        final path = detail['path'];
        if (path is String && path.isNotEmpty) fields.putIfAbsent(path, () => S.fieldError(path));
      }
    }
    return ApiException(
      code: code,
      message: S.apiError(code),
      status: status,
      fieldErrors: fields,
      details: details is List ? List<Object?>.of(details) : const [],
      serverMessage: serverMessage,
    );
  }
}
