// ApiClient: mapping errors, the one retry after a 401, and presigned uploads to S3.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netzero/app/strings.dart';
import 'package:netzero/models/models.dart';
import 'package:netzero/services/api_client.dart';
import 'package:netzero/services/auth_service.dart';
import 'package:netzero/services/cognito_backend.dart';

import 'fakes.dart';

/// Answers each request with [handler] and records what was sent.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  Future<ResponseBody> Function(RequestOptions options) handler;
  final requests = <RequestOptions>[];
  final bodies = <List<int>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    bodies.add(bytes);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

/// A JSON response.
ResponseBody jsonBody(int status, Object body) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

/// API Gateway's answer to a token it rejects.
ResponseBody unauthorized() => jsonBody(401, {'message': 'Unauthorized'});

/// The Authorization header a request was sent with.
String? bearer(RequestOptions request) => request.headers['Authorization'] as String?;

/// A Dio failure carrying a response with [status] and [data].
DioException badResponse(int status, Object? data) => DioException.badResponse(
  statusCode: status,
  requestOptions: RequestOptions(path: '/x'),
  response: Response<Object?>(
    requestOptions: RequestOptions(path: '/x'),
    statusCode: status,
    data: data,
  ),
);

void main() {
  late DateTime now;
  late FakeCognito cognito;
  late AuthService auth;
  late FakeAdapter adapter;
  late FakeAdapter s3Adapter;
  late ApiClient api;
  late int expiredNavigations;

  setUp(() async {
    now = DateTime(2026, 11, 9, 12);
    cognito = FakeCognito(
      now: () => now,
      stored: StoredSession(
        userId: 'user-a',
        tokens: tokens('t-old', expires: DateTime(2026, 11, 9, 13)),
      ),
    );
    auth = await AuthService(cognito, clock: () => now).restore();
    adapter = FakeAdapter((_) async => jsonBody(200, {'ok': true}));
    s3Adapter = FakeAdapter((_) async => ResponseBody.fromString('', 204));
    expiredNavigations = 0;
    api = ApiClient(
      auth,
      dio: Dio(BaseOptions(baseUrl: 'https://api.test'))..httpClientAdapter = adapter,
      s3: Dio()..httpClientAdapter = s3Adapter,
      onSessionExpired: () async => expiredNavigations++,
    );
  });

  group('mapError', () {
    test('no response at all is NETWORK', () {
      final error = ApiClient.mapError(
        DioException.connectionTimeout(timeout: const Duration(seconds: 10), requestOptions: RequestOptions()),
      );

      expect(error.code, 'NETWORK');
      expect(error.isNetwork, isTrue);
      expect(error.message, S.noConnection);
    });

    test('a 401 from API Gateway without an error body is UNAUTHORIZED', () {
      final error = ApiClient.mapError(badResponse(401, {'message': 'Unauthorized'}));

      expect(error.code, 'UNAUTHORIZED');
      expect(error.status, 401);
      expect(error.message, S.sessionExpired);
    });

    test('a server error body gives a Mongolian message, field errors and the raw details', () {
      final error = ApiClient.mapError(
        badResponse(409, {
          'error': {
            'code': 'BALANCES_NOT_ZERO',
            'message': 'Settle up first',
            'details': [
              {'groupId': 'g1', 'name': 'Flat'},
              {'path': 'name', 'message': 'Too long'},
            ],
          },
        }),
      );

      expect(error.code, 'BALANCES_NOT_ZERO');
      expect(error.message, S.apiError('BALANCES_NOT_ZERO'));
      expect(error.serverMessage, 'Settle up first');
      expect(error.fieldErrors, {'name': S.fieldError('name')});
      expect(error.details, hasLength(2));
    });

    test('GROUP_NOT_FOUND has its own type', () {
      final error = ApiClient.mapError(
        badResponse(404, {
          'error': {'code': 'GROUP_NOT_FOUND', 'message': 'nope'},
        }),
      );

      expect(error, isA<GroupNotFoundException>());
    });

    test('an HTML 502 becomes HTTP_502', () {
      final error = ApiClient.mapError(badResponse(502, '<html>Bad gateway</html>'));

      expect(error.code, 'HTTP_502');
      expect(error.message, S.unexpectedResponse(502));
    });

    test('an ApiException raised before sending passes through unchanged', () {
      final inner = ApiException(code: 'NETWORK', message: S.noConnection);

      expect(ApiClient.mapError(DioException(requestOptions: RequestOptions(), error: inner)), same(inner));
    });
  });

  group('after a 401', () {
    test('refreshes the token and retries once with the new one', () async {
      adapter.handler = (request) async {
        if (bearer(request) == 'Bearer t-old') return unauthorized();
        return jsonBody(200, {'id': 'x'});
      };

      expect(await api.get('/me'), {'id': 'x'});

      expect(adapter.requests.map(bearer), ['Bearer t-old', 'Bearer t-refreshed']);
      expect(cognito.refreshCalls, 1);
      expect(auth.isSignedIn, isTrue);
      expect(expiredNavigations, 0);
    });

    test('a second 401 signs out and goes to sign-in once', () async {
      adapter.handler = (_) async => unauthorized();

      await expectLater(api.get('/me'), throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)));

      // The original request and exactly one retry.
      expect(adapter.requests, hasLength(2));
      expect(auth.isSignedIn, isFalse);
      expect(expiredNavigations, 1);
      expect(auth.takeExpiredNotice(), isTrue);
    });

    test('several requests failing together sign out once', () async {
      adapter.handler = (_) async => unauthorized();

      final results = await Future.wait([
        api.get('/a').then((_) => 'ok', onError: (Object _) => 'failed'),
        api.get('/b').then((_) => 'ok', onError: (Object _) => 'failed'),
        api.get('/c').then((_) => 'ok', onError: (Object _) => 'failed'),
      ]);

      expect(results, ['failed', 'failed', 'failed']);
      expect(cognito.refreshCalls, 1);
      expect(cognito.signOutCalls, 1);
      expect(expiredNavigations, 1);
    });

    test('keeps the session when Cognito is unreachable during the refresh', () async {
      adapter.handler = (_) async => unauthorized();
      cognito.onRefresh = () async => throw TimeoutException('offline');

      await expectLater(api.get('/me'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'NETWORK')));
      expect(auth.isSignedIn, isTrue);
      expect(expiredNavigations, 0);
    });

    test('a session Cognito says is over fails before sending and signs out', () async {
      // The cached token has expired.
      now = DateTime(2026, 11, 9, 14);
      cognito.onSession = () async => throw const SessionMissingException();

      await expectLater(api.get('/me'), throwsA(isA<SessionExpiredException>()));
      expect(adapter.requests, isEmpty);
      expect(auth.isSignedIn, isFalse);
      expect(expiredNavigations, 1);
    });

    test("a 401 for a request from an ended session doesn't touch the new session", () async {
      final gate = Completer<void>();
      adapter.handler = (request) async {
        if (bearer(request) == 'Bearer t-old') {
          await gate.future;
          return unauthorized();
        }
        return jsonBody(200, {});
      };
      final stale = api.get('/me').then((_) => 'ok', onError: (Object e) => 'failed');
      await pumpEventQueue();
      await auth.signOut();
      await auth.signIn('b@x.com', 'Password123');
      gate.complete();

      expect(await stale, 'failed');
      // It was not sent again with B's token.
      expect(adapter.requests, hasLength(1));
      expect(auth.userId, 'sub-b@x.com');
      expect(expiredNavigations, 0);
    });
  });

  group('presigned POST upload', () {
    const signed = PresignedPost(
      uploadUrl: 'https://bucket.s3.ap-northeast-1.amazonaws.com/',
      fields: {
        'key': 'groups/g1/expenses/e1/u.jpg',
        'Content-Type': 'image/jpeg',
        'Policy': 'p',
        'X-Amz-Signature': 's',
      },
      key: 'groups/g1/expenses/e1/u.jpg',
      maxBytes: 100,
    );

    test('sends the signed fields first and the file last, without an Authorization header', () async {
      await api.postPresigned(signed, utf8.encode('JPEGDATA'), contentType: 'image/jpeg', filename: 'receipt.jpg');

      final request = s3Adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.toString(), signed.uploadUrl);
      expect(request.headers['Authorization'], isNull);
      expect(request.contentType, startsWith('multipart/form-data'));

      final body = latin1.decode(s3Adapter.bodies.single);
      final positions = [
        for (final name in ['key', 'Content-Type', 'Policy', 'X-Amz-Signature', 'file']) body.indexOf('name="$name"'),
      ];
      final lastField = positions.take(4).reduce((a, b) => a > b ? a : b);
      expect(positions, everyElement(greaterThanOrEqualTo(0)));
      expect(positions.last, greaterThan(lastField));
      expect(body, contains('JPEGDATA'));
    });

    test('refuses a file bigger than the signed limit before uploading', () async {
      await expectLater(
        api.postPresigned(signed, List.filled(101, 0), contentType: 'image/jpeg', filename: 'r.jpg'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'FILE_TOO_LARGE')),
      );
      expect(s3Adapter.requests, isEmpty);
    });

    test('an S3 refusal is UPLOAD_FAILED and leaves the session alone', () async {
      s3Adapter.handler = (_) async => ResponseBody.fromString('<Error>AccessDenied</Error>', 403);

      await expectLater(
        api.postPresigned(signed, [1, 2, 3], contentType: 'image/jpeg', filename: 'r.jpg'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'UPLOAD_FAILED')),
      );
      expect(auth.isSignedIn, isTrue);
    });
  });
}
