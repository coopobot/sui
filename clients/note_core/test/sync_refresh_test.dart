import 'dart:convert';

import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// M10-T33：客户端令牌续期路径的门禁。
///
/// 覆盖 auth.md §8.5 的客户端规则：收到 `token-expired` → **单飞刷新** → **原样重放一次**；
/// 刷新令牌失效（`refresh-expired` / `refresh-revoked`）→ 回调上层提示重新登录。
///
/// 这条路径此前**零覆盖**，而它有两个易错点：
///   ① 并发请求同时过期时必须只发一次刷新——刷新令牌是单次使用的，重复使用会被服务端
///      判为重放并**吊销整个会话**（auth.md §8.3）；
///   ② 刷新成功后必须用新令牌重放原请求，否则用户会看到一次莫名其妙的同步失败。

Response jsonResponse(int status, Object body) {
  final bytes = utf8.encode(jsonEncode(body));
  return Response.bytes(
    bytes,
    status,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, dynamic> emptyPull() => {
      'ok': true,
      'notes': <Object>[],
      'notebooks': <Object>[],
      'tags': <Object>[],
    };

void main() {
  group('SyncClient 令牌续期（M10）', () {
    late AppDatabase db;
    late NoteRepository repo;

    setUp(() {
      db = AppDatabase.memory();
      repo = NoteRepository(db, deviceId: 'test-device');
    });

    tearDown(() => db.close());

    SyncClient newClient(
      MockClientHandler handler, {
      String token = 'old-access',
      String refreshToken = 'old-refresh',
      void Function(String access, String refresh)? onRefreshed,
      void Function()? onExpired,
    }) =>
        SyncClient(
          repository: repo,
          baseUrl: 'http://test',
          deviceId: 'test-device',
          token: token,
          refreshToken: refreshToken,
          httpClient: MockClient(handler),
          onTokensRefreshed: (a, r) async => onRefreshed?.call(a, r),
          onAuthExpired: () async => onExpired?.call(),
        );

    test('token-expired → 刷新一次 → 用新令牌重放原请求', () async {
      var refreshCalls = 0;
      String? refreshedAccess;
      String? refreshedRefresh;
      final authSeen = <String>[];

      final syncer = newClient(
        (req) async {
          authSeen.add('${req.headers['authorization']}');
          if (req.url.path == '/api/v1/refresh') {
            refreshCalls++;
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            expect(body['refresh_token'], 'old-refresh');
            return jsonResponse(200, {
              'ok': true,
              'access_token': 'new-access',
              'refresh_token': 'new-refresh',
              'expires_in': 1800,
            });
          }
          if (req.headers['authorization'] == 'Bearer old-access') {
            return jsonResponse(401, {'ok': false, 'error': 'token-expired'});
          }
          return jsonResponse(200, emptyPull());
        },
        onRefreshed: (a, r) {
          refreshedAccess = a;
          refreshedRefresh = r;
        },
      );

      expect(await syncer.pull(), 0, reason: '重放后应成功');

      expect(refreshCalls, 1, reason: '只刷一次');
      expect(refreshedAccess, 'new-access');
      expect(refreshedRefresh, 'new-refresh');
      expect(syncer.token, 'new-access', reason: '客户端令牌就地更新');
      expect(syncer.refreshToken, 'new-refresh');
      expect(authSeen.last, 'Bearer new-access', reason: '重放须用新令牌');
      syncer.close();
    });

    test('并发请求同时过期：刷新只发生一次（单飞）', () async {
      var refreshCalls = 0;

      final syncer = newClient((req) async {
        if (req.url.path == '/api/v1/refresh') {
          refreshCalls++;
          // 让刷新「慢」一点，确保第二个请求在刷新进行中到达
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return jsonResponse(200, {
            'ok': true,
            'access_token': 'new-access',
            'refresh_token': 'new-refresh',
            'expires_in': 1800,
          });
        }
        if (req.headers['authorization'] == 'Bearer old-access') {
          return jsonResponse(401, {'ok': false, 'error': 'token-expired'});
        }
        return jsonResponse(200, emptyPull());
      });

      await Future.wait([syncer.pull(), syncer.pull()]);

      expect(refreshCalls, 1,
          reason: '刷新令牌单次使用；并发重复刷新会被判重放并吊销会话');
      syncer.close();
    });

    test('刷新被拒（refresh-revoked）→ 回调失效且原 401 抛出', () async {
      var expired = 0;

      final syncer = newClient(
        (req) async {
          if (req.url.path == '/api/v1/refresh') {
            return jsonResponse(401, {'ok': false, 'error': 'refresh-revoked'});
          }
          return jsonResponse(401, {'ok': false, 'error': 'token-expired'});
        },
        onExpired: () => expired++,
      );

      await expectLater(
        syncer.pull(),
        throwsA(isA<HttpException>()
            .having((e) => e.statusCode, 'statusCode', 401)),
      );
      expect(expired, 1, reason: '须通知上层重新登录');
      syncer.close();
    });

    test('无刷新令牌：不请求 /refresh，直接暴露 401 并提示重登', () async {
      var refreshCalls = 0;
      var expired = 0;

      final syncer = newClient(
        (req) async {
          if (req.url.path == '/api/v1/refresh') {
            refreshCalls++;
          }
          return jsonResponse(401, {'ok': false, 'error': 'token-expired'});
        },
        refreshToken: '',
        onExpired: () => expired++,
      );

      await expectLater(syncer.pull(), throwsA(isA<HttpException>()));
      expect(refreshCalls, 0);
      expect(expired, 1);
      syncer.close();
    });

    test('invalid_token 也刷新**恰好一次**（§8.5）：可自愈不必重登，且绝不反复打转', () async {
      var refreshCalls = 0;
      var dataCalls = 0;

      final syncer = newClient((req) async {
        if (req.url.path == '/api/v1/refresh') {
          refreshCalls++;
          return jsonResponse(200, {
            'ok': true,
            'access_token': 'new-access',
            'refresh_token': 'new-refresh',
            'expires_in': 1800,
          });
        }
        dataCalls++;
        return jsonResponse(401, {'ok': false, 'error': 'invalid_token'});
      });

      // 本用例让服务端对**重放**仍判 invalid_token → 一次性重放后即收手并暴露 401。
      await expectLater(syncer.pull(), throwsA(isA<HttpException>()));
      expect(refreshCalls, 1, reason: 'invalid_token 应尝试刷新一次（§8.5）');
      expect(dataCalls, 2, reason: '原请求 + 重放各一次，不做更多重试（无死循环）');
      syncer.close();
    });

    test('invalid_token 且无刷新令牌：不尝试刷新，直接暴露 401', () async {
      var refreshCalls = 0;
      final syncer = newClient(
        (req) async {
          if (req.url.path == '/api/v1/refresh') {
            refreshCalls++;
          }
          return jsonResponse(401, {'ok': false, 'error': 'invalid_token'});
        },
        refreshToken: '',
      );

      await expectLater(syncer.pull(), throwsA(isA<HttpException>()));
      expect(refreshCalls, 0, reason: '没有刷新令牌就不该尝试刷新');
      syncer.close();
    });
  });

  group('AuthClient 令牌解析（M10）', () {
    test('login 解析 access_token / refresh_token / expires_in', () async {
      final client = AuthClient(
        httpClient: MockClient((req) async {
          expect(req.url.path, '/api/v1/login');
          return jsonResponse(200, {
            'ok': true,
            'access_token': 'a1',
            'refresh_token': 'r1',
            'expires_in': 1799,
          });
        }),
      );
      final session = await client.login(
        baseUrl: 'http://test',
        username: 'u',
        password: 'p',
      );
      expect(session.accessToken, 'a1');
      expect(session.refreshToken, 'r1');
      expect(session.expiresIn, 1799);
      expect(session.hasRefresh, isTrue);
      client.close();
    });

    test('回落旧字段 token（服务端临时兼容期）', () async {
      final client = AuthClient(
        httpClient: MockClient((req) async =>
            jsonResponse(200, {'ok': true, 'token': 'legacy'})),
      );
      final session = await client.register(
        baseUrl: 'http://test',
        username: 'u',
        password: 'p',
      );
      expect(session.accessToken, 'legacy');
      expect(session.hasRefresh, isFalse);
      client.close();
    });

    test('refresh：失败时抛出携带错误码的 HttpException', () async {
      final client = AuthClient(
        httpClient: MockClient((req) async {
          expect(req.url.path, '/api/v1/refresh');
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          expect(body['refresh_token'], 'r1');
          return jsonResponse(401, {'ok': false, 'error': 'refresh-expired'});
        }),
      );
      await expectLater(
        client.refresh(baseUrl: 'http://test', refreshToken: 'r1'),
        throwsA(isA<HttpException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.body, 'body', contains('refresh-expired'))),
      );
      client.close();
    });
  });

  group('SettingsStore 刷新令牌（M10）', () {
    test('持久化并在断开时一并清除', () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final store = SettingsStore(db);

      await store.saveSyncConfig(
        baseUrl: 'http://test/',
        token: 'acc',
        refreshToken: 'ref',
      );
      final cfg = await store.loadSyncConfig();
      expect(cfg.baseUrl, 'http://test');
      expect(cfg.token, 'acc');
      expect(cfg.refreshToken, 'ref');
      expect(cfg.canRefresh, isTrue);

      await store.clearSyncConfig();
      final cleared = await store.loadSyncConfig();
      expect(cleared.token, isEmpty);
      expect(cleared.refreshToken, isEmpty,
          reason: '断开后不得残留长期凭证（BR-49.4）');
    });
  });
}
