import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// M10-T27 / FR-50：**受保护通道客户端**门禁。
///
/// 关键点：客户端封装必须与**服务端（Go）逐字节一致**——故第一组用例直接用 Spike-003 向量
/// （由 Go 与 Dart 双方验证过）断言封装与 AAD 口径；第二组用「以同一原语扮演服务端」的
/// MockClient 验证握手 / TOFU / 往返 / 错误路径。
void main() {
  group('封装口径（Spike 向量，逐字节）', () {
    test('AES-GCM 封装与向量一致，且 AAD 不符必失败', () async {
      // poc-003/sui-crypto-v1.json：hkdf[app] → K；aesgcm / envelope 段。
      final key = _hex('04da26d6647c364b952145871cc6cf3f547700e1096d0a209b75a71762767fde');
      final nonce = _hex('000000000000000000000001');
      final aad = utf8.encode('nb-1|note-1|content');
      final plain = utf8.encode('随手记 Sui spike-003');
      const want = 'AQEAAAAAAAAAAAAAAAE7RQzjmheTxZ9NtvnqTKlpBceBXBtXhN/nZ5Ryql5t/G2uutGpaSs=';

      final box = await AesGcm.with256bits()
          .encrypt(plain, secretKey: SecretKey(key), nonce: nonce, aad: aad);
      final env = base64.encode(<int>[
        EnvelopeFormat.version,
        EnvelopeFormat.algAes256Gcm,
        ...nonce,
        ...box.cipherText,
        ...box.mac.bytes,
      ]);
      expect(env, want, reason: '通道封装必须与 Spike 向量逐字节一致');

      // AAD 口径：`method\npath\nreqId`（与 Go 端 securechan.AAD 相同拼接）。
      expect(
        utf8.decode(channelAad('POST', '/api/v1/login', 'abc')),
        'POST\n/api/v1/login\nabc',
      );
    });
  });

  group('SecureChannelClient', () {
    late SimpleKeyPair serverLong;
    late String serverFingerprint;

    setUp(() async {
      serverLong = await X25519().newKeyPair();
      final pub = await serverLong.extractPublicKey();
      final sum = await Sha256().hash(pub.bytes);
      serverFingerprint = sum.bytes
          .take(8)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join()
          .toUpperCase();
    });

    /// 以同一套原语扮演**服务端**：解封请求、按 §9.6 加密响应。
    Future<http.Response> fakeServer(http.BaseRequest req) async {
      if (req.url.path == kChannelHandshakePath) {
        final pub = await serverLong.extractPublicKey();
        return http.Response(
          jsonEncode({
            'ok': true,
            'alg': 'x25519',
            'serverPub': base64.encode(pub.bytes),
            'fingerprint': serverFingerprint,
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      if (req.headers[kHeaderChannelEnc] != '1') {
        return http.Response(jsonEncode({'ok': false, 'error': 'plain'}), 400);
      }
      final ephPub = SimplePublicKey(
        base64.decode(req.headers[kHeaderChannelEph]!),
        type: KeyPairType.x25519,
      );
      final shared = await X25519()
          .sharedSecretKey(keyPair: serverLong, remotePublicKey: ephPub);
      final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: SecretKey(await shared.extractBytes()),
        nonce: const <int>[],
        info: utf8.encode(kChannelKdfInfo),
      );
      final keyBytes = await key.extractBytes();
      final reqId = req.headers[kHeaderChannelReqID]!;
      final aad = channelAad(req.method, req.url.path, reqId);

      // 不能对已 finalize 的请求再 finalize（MockClient 已消费过）：直接读 body。
      final env = (req as http.Request).body;
      final raw = base64.decode(env);
      final nonce = raw.sublist(2, 2 + EnvelopeFormat.nonceLength);
      final tagStart = raw.length - EnvelopeFormat.tagLength;
      final plain = await AesGcm.with256bits().decrypt(
        SecretBox(
          raw.sublist(2 + EnvelopeFormat.nonceLength, tagStart),
          nonce: nonce,
          mac: Mac(raw.sublist(tagStart)),
        ),
        secretKey: SecretKey(keyBytes),
        aad: aad,
      );
      // 回一个加密响应（内容为收到的明文，便于断言往返）。
      final respNonce = Uint8List.fromList(List<int>.filled(12, 7));
      final respBox = await AesGcm.with256bits().encrypt(
        plain,
        secretKey: SecretKey(keyBytes),
        nonce: respNonce,
        aad: aad,
      );
      final respEnv = base64.encode(<int>[
        EnvelopeFormat.version,
        EnvelopeFormat.algAes256Gcm,
        ...respNonce,
        ...respBox.cipherText,
        ...respBox.mac.bytes,
      ]);
      return http.Response(respEnv, 200, headers: const {kHeaderChannelEnc: '1'});
    }

    SecureChannelClient build({ChannelTrustStore? trust}) => SecureChannelClient(
          inner: MockClient(fakeServer),
          trust: trust,
        );

    test('往返：请求被加密发出、响应被解密取回；TOFU 首次记录指纹', () async {
      final trust = InMemoryChannelTrust();
      final client = build(trust: trust);

      final resp = await client.post(
        Uri.parse('http://host:8080/api/v1/login'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'username': 'u', 'password': 'pw'}),
      );
      expect(resp.statusCode, 200);
      expect(jsonDecode(resp.body), {'username': 'u', 'password': 'pw'});
      expect(resp.headers['content-type'], contains('application/json'));

      expect(await trust.fingerprint, serverFingerprint,
          reason: '首次握手应记录指纹（TOFU）');
      expect(client.fingerprints['http://host:8080'], serverFingerprint);
    });

    test('TOFU：已记录指纹与服务端不一致 → 阻断并要求重新核对', () async {
      final trust = InMemoryChannelTrust('AA11-BB22-CC33-DD44');
      final client = build(trust: trust);

      await expectLater(
        client.get(Uri.parse('http://host:8080/api/v1/ping')),
        throwsA(isA<ChannelTrustException>()),
      );
    });

    test('服务端明文错误响应（未过通道）原样透传，不被当成密文', () async {
      final client = SecureChannelClient(
        inner: MockClient((req) async {
          if (req.url.path == kChannelHandshakePath) {
            final pub = await serverLong.extractPublicKey();
            return http.Response(
              jsonEncode({
                'ok': true,
                'alg': 'x25519',
                'serverPub': base64.encode(pub.bytes),
                'fingerprint': serverFingerprint,
              }),
              200,
            );
          }
          return http.Response(jsonEncode({'ok': false, 'error': 'replayed'}), 409);
        }),
      );
      final resp = await client.post(Uri.parse('http://h/api/v1/login'), body: 'x');
      expect(resp.statusCode, 409);
      expect(jsonDecode(resp.body), {'ok': false, 'error': 'replayed'});
    });

    test('响应密文被篡改 → 明确报错（不吐半截明文）', () async {
      final client = SecureChannelClient(
        inner: MockClient((req) async {
          if (req.url.path == kChannelHandshakePath) {
            final pub = await serverLong.extractPublicKey();
            return http.Response(
              jsonEncode({
                'ok': true,
                'alg': 'x25519',
                'serverPub': base64.encode(pub.bytes),
                'fingerprint': serverFingerprint,
              }),
              200,
            );
          }
          final raw = base64.decode('AQEAAAAAAAAAAAAAAAE7RQzjmheTxZ9NtvnqTKlpBceBXBtXhN/nZ5Ryql5t/G2uutGpaSs=');
          raw[raw.length - 1] ^= 0x01;
          return http.Response(base64.encode(raw), 200,
              headers: const {kHeaderChannelEnc: '1'});
        }),
      );
      await expectLater(
        client.get(Uri.parse('http://h/api/v1/ping')),
        throwsA(isA<ChannelException>()),
      );
    });
  });

  group('启用条件（§9.1）', () {
    test('https 不叠加应用层加密；http 默认启用；可强制明文', () {
      expect(shouldUseSecureChannel('https://sui.example'), isFalse);
      expect(shouldUseSecureChannel('http://127.0.0.1:8080'), isTrue);
      expect(shouldUseSecureChannel('http://127.0.0.1:8080', forcePlaintext: true),
          isFalse);
      expect(channelAwareClient(baseUrl: 'https://sui.example'), isNull);
      expect(channelAwareClient(baseUrl: 'http://127.0.0.1:8080'), isNotNull);
    });
  });
}

Uint8List _hex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);
