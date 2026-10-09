import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// v0.11.3：**无正文请求**（GET/HEAD）走受保护通道的门禁。
///
/// 现实约束：浏览器 `fetch` 拒绝「GET/HEAD 带 body」——
/// `Failed to execute 'fetch' on 'Window': Request with GET/HEAD method cannot have body`。
/// 而同步 `pull` 就是 GET，且通道包装层原先给**每个**请求都塞了密文正文 → Web 端一同步就报错
/// （原生端 `package:http` 允许 GET 带 body，故 Dart e2e 全过，抓不到这条）。
///
/// 契约：无正文请求**不发封装**（但仍带三个通道头，以便拿到**加密响应**）；
/// 确有正文时仍发封装（既有 `secure_channel_test.dart` 覆盖）。
void main() {
  const serverUrl = 'http://host:8080';

  test('GET 走通道：不发正文、仍带通道头，且响应可解封', () async {
    final serverLong = await X25519().newKeyPair();
    final serverPub = await serverLong.extractPublicKey();
    final sum = await Sha256().hash(serverPub.bytes);
    final fp = sum.bytes
        .take(8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();

    Map<String, String>? seenHeaders;
    String? seenBody;

    final client = SecureChannelClient(
      inner: MockClient((req) async {
        if (req.url.path == kChannelHandshakePath) {
          return http.Response(
            jsonEncode({
              'ok': true,
              'alg': 'x25519',
              'serverPub': base64.encode(serverPub.bytes),
              'fingerprint': fp,
            }),
            200,
          );
        }
        // 关键断言：GET 请求**不得**带正文，但必须仍声明通道 + 带临时公钥与 reqId。
        expect(req.method, 'GET');
        expect(req.body, isEmpty, reason: 'GET 不能带 body（浏览器会直接报错）');
        expect(req.headers[kHeaderChannelEnc], '1');
        expect(req.headers[kHeaderChannelEph], isNotEmpty);
        expect(req.headers[kHeaderChannelReqID], isNotEmpty);
        seenHeaders = req.headers;
        seenBody = req.body;

        // 服务端侧：空正文 → 空明文；响应照旧用同一 K_chan 加密。
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
        final aad = channelAad(
            req.method, req.url.path, req.headers[kHeaderChannelReqID]!);
        final nonce = Uint8List.fromList(List<int>.filled(12, 3));
        final box = await AesGcm.with256bits().encrypt(
          utf8.encode(jsonEncode({'ok': true, 'pulled': 2})),
          secretKey: SecretKey(keyBytes),
          nonce: nonce,
          aad: aad,
        );
        final env = base64.encode(<int>[
          EnvelopeFormat.version,
          EnvelopeFormat.algAes256Gcm,
          ...nonce,
          ...box.cipherText,
          ...box.mac.bytes,
        ]);
        return http.Response(env, 200, headers: const {kHeaderChannelEnc: '1'});
      }),
    );

    final resp = await client.get(
      Uri.parse('$serverUrl/api/v1/sync/pull?since=1970-01-01T00:00:00.000Z'),
    );
    expect(resp.statusCode, 200);
    expect(jsonDecode(resp.body), {'ok': true, 'pulled': 2},
        reason: '无正文请求的响应仍必须被加密并可解封');
    expect(seenBody, isEmpty);
    expect(seenHeaders?[kHeaderChannelEnc], '1');
    client.close();
  });

  test('POST 仍发封装（无正文请求的特例不波及有正文请求）', () async {
    final serverLong = await X25519().newKeyPair();
    final serverPub = await serverLong.extractPublicKey();
    String? seenBody;

    final client = SecureChannelClient(
      inner: MockClient((req) async {
        if (req.url.path == kChannelHandshakePath) {
          return http.Response(
            jsonEncode({
              'ok': true,
              'alg': 'x25519',
              'serverPub': base64.encode(serverPub.bytes),
              'fingerprint': 'AAAA-BBBB-CCCC-DDDD',
            }),
            200,
          );
        }
        seenBody = req.body;
        // 空明文以外的请求：正文必须是自描述封装。
        expect(NotebookFieldCipher.isEnvelope(req.body), isTrue,
            reason: '有正文的请求仍应发密文封装');
        return http.Response(
            jsonEncode({'ok': true, 'error': 'x'}), 400,
            headers: const {}); // 明文错误响应原样透传
      }),
    );

    final resp = await client.post(
      Uri.parse('$serverUrl/api/v1/login'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'username': 'u', 'password': 'p'}),
    );
    expect(resp.statusCode, 400);
    expect(seenBody, isNotNull);
    client.close();
  });
}
