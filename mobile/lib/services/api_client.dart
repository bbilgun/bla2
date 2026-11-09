import 'package:dio/dio.dart';
import 'package:get/get.dart' hide Response;

import '../app/config.dart';
import '../app/routes.dart';
import '../app/strings.dart';
import 'auth_service.dart';

/// Every API failure, mapped from the server's `{ error: { code, message, details } }`.
/// [message] is always Mongolian text for the person ([S.apiError]); [serverMessage] is the
/// server's English wording, kept for debugging.
class ApiException implements Exception {
  ApiException({
    required this.code,
    required this.message,
    this.status,
    this.fieldErrors = const {},
    this.serverMessage,
  });

  final String code;
  final String message;
  final String? serverMessage;
  final int? status;

  /// Server validation errors keyed by field path ("amountCents", "split.shares.0.userId").
  final Map<String, String> fieldErrors;

  /// True when the request may or may not have reached the server (timeout, no connection).
  /// Retrying a money write with the same Idempotency-Key is safe in exactly this case.
  bool get isNetwork => code == 'NETWORK';

  @override
  String toString() => message;
}

/// You are not in this group (or it doesn't exist). The server doesn't say which, on purpose.
class GroupNotFoundException extends ApiException {
  GroupNotFoundException({super.serverMessage})
    : super(code: 'GROUP_NOT_FOUND', message: S.apiError('GROUP_NOT_FOUND'), status: 404);
}

/// The only class that talks HTTP to the NetZero API. Only repositories use it.
class ApiClient extends GetxService {
  ApiClient(this._auth)
    : _dio = Dio(
        BaseOptions(
          baseUrl: AppConfig.apiUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
          contentType: Headers.jsonContentType,
        ),
      ) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await _auth.idToken();
          if (token != null) options.headers['Authorization'] = 'Bearer $token';
          handler.next(options);
        },
      ),
    );
  }

  final AuthService _auth;
  final Dio _dio;

  /// Separate client for S3 presigned URLs: no auth interceptor, no base URL.
  /// An Authorization header on a presigned request makes S3 reject it.
  final Dio _plain = Dio();

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

  Future<Map<String, dynamic>> delete(String path) => _send(() => _dio.delete<Map<String, dynamic>>(path));

  /// Uploads bytes straight to S3 with a presigned PUT. The file never touches Lambda.
  Future<void> putPresigned(String url, List<int> bytes, Map<String, String> headers) async {
    try {
      await _plain.put<void>(
        url,
        data: Stream.fromIterable([bytes]),
        options: Options(headers: {...headers, Headers.contentLengthHeader: bytes.length}),
      );
    } on DioException catch (e) {
      throw _map(e);
    }
  }

  Future<Map<String, dynamic>> _send(Future<Response<Map<String, dynamic>>> Function() request) async {
    try {
      final res = await request();
      return res.data ?? const {};
    } on DioException catch (e) {
      final error = _map(e);
      if (error.status == 401) {
        await _auth.signOut();
        Get.offAllNamed(Routes.signIn);
      }
      throw error;
    }
  }

  ApiException _map(DioException e) {
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
    final code = error['code'] as String? ?? 'UNKNOWN';
    final serverMessage = error['message'] as String?;
    if (code == 'GROUP_NOT_FOUND') return GroupNotFoundException(serverMessage: serverMessage);

    final fields = <String, String>{};
    final details = error['details'];
    if (details is List) {
      for (final d in details.whereType<Map>()) {
        final path = d['path'];
        if (path is String && path.isNotEmpty) fields.putIfAbsent(path, () => S.fieldError(path));
      }
    }
    return ApiException(
      code: code,
      message: S.apiError(code),
      status: res.statusCode,
      fieldErrors: fields,
      serverMessage: serverMessage,
    );
  }
}
