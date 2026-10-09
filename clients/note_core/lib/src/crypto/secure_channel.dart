/// 受保护通道的**客户端传输接缝**（M10-T27 / FR-50，口径见 auth.md §9.6）。
///
/// 设计意图（§9.4 BR-50.3）：加解密收敛在一个 [http.BaseClient] 包装层里，
/// `AuthClient` / `SyncClient` 的调用代码与 push/pull、合并逻辑**完全不改**。
///
/// 线路口径（必须与服务端逐字节一致，Spike-003 的向量即回归门禁）：
///   * 握手 `GET /api/v1/crypto/handshake` → `serverPub` + `fingerprint`（TOFU 信任根）；
///   * `K_chan = HKDF-SHA256(ECDH(临时私钥, 服务端公钥), salt = 空, info = "sui-channel-v1")`；
///   * 正文 = `base64(ver(1) | alg(1) | nonce(12) | ct | tag(16))`，AES-256-GCM；
///   * `AAD = utf8(method + "\n" + path + "\n" + reqId)`，请求与响应**同一 AAD**；
///   * 请求头 `X-Sui-Enc: 1` / `X-Sui-Eph`（本次临时公钥）/ `X-Sui-Req-Id`。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'notebook_crypto.dart' show EnvelopeFormat, NotebookCrypto, randomBytes;
import '../repository/settings_store.dart';

/// 握手端点（本包装层**不加密**它：它是信任根分发入口）。
const kChannelHandshakePath = '/api/v1/crypto/handshake';

/// 通道相关请求头（与服务端 `securechan` 常量一一对应）。
const kHeaderChannelEnc = 'X-Sui-Enc';
const kHeaderChannelEph = 'X-Sui-Eph';
const kHeaderChannelReqID = 'X-Sui-Req-Id';

/// KDF 的 `info` 字面量（改动即破坏兼容）。
const kChannelKdfInfo = 'sui-channel-v1';

/// 启用条件（auth.md §9.1）：`https://` 走 TLS，不叠加应用层加密；`http://` 且用户未选择
/// 「强制明文」时启用。
bool shouldUseSecureChannel(String baseUrl, {bool forcePlaintext = false}) {
  if (forcePlaintext) return false;
  return baseUrl.trim().toLowerCase().startsWith('http://');
}

/// TOFU 指纹存储抽象（实现见 [SettingsChannelTrustStore]，测试可用内存实现）。
///
/// 取指纹是**异步**的：持久化后端（`SettingsStore`）本身异步。
abstract class ChannelTrustStore {
  Future<String?> get fingerprint;
  Future<void> saveFingerprint(String fingerprint);
}

/// 内存实现（测试 / 无持久化场景）。
class InMemoryChannelTrust implements ChannelTrustStore {
  InMemoryChannelTrust([this._fp]);

  String? _fp;

  @override
  Future<String?> get fingerprint async => _fp;

  @override
  Future<void> saveFingerprint(String fingerprint) async => _fp = fingerprint;
}

/// 基于 [SettingsStore] 的持久化实现（`channel.fingerprint` 键）。
class SettingsChannelTrustStore implements ChannelTrustStore {
  SettingsChannelTrustStore(this._settings);

  final SettingsStore _settings;

  @override
  Future<String?> get fingerprint => _settings.channelFingerprint();

  @override
  Future<void> saveFingerprint(String fingerprint) =>
      _settings.setChannelFingerprint(fingerprint);
}

/// **指纹变化**（疑似中间人）→ 阻断，并给出新旧指纹供用户核对（§9.2）。
class ChannelTrustException implements Exception {
  ChannelTrustException(this.expected, this.actual);

  final String expected;
  final String actual;

  @override
  String toString() => '服务端通道指纹与首次记录不一致：已记录 $expected，本次 $actual。'
      '若非你主动更换服务端，请勿继续（可能存在中间人）。';
}

/// 通道层错误（握手失败 / 响应未加密 / 解封失败）。
class ChannelException implements Exception {
  ChannelException(this.message);

  final String message;

  @override
  String toString() => '受保护通道错误：$message';
}

/// AAD 口径（§9.6）：`method \n path \n reqId`。
Uint8List channelAad(String method, String path, String reqId) =>
    Uint8List.fromList(utf8.encode('$method\n$path\n$reqId'));

/// 通道感知的 `http.Client` 包装。
class SecureChannelClient extends http.BaseClient {
  SecureChannelClient({
    required http.Client inner,
    ChannelTrustStore? trust,
  })  : _inner = inner,
        _trust = trust;

  final http.Client _inner;
  final ChannelTrustStore? _trust;

  // 按**来源**（origin）缓存已核对的长期公钥与指纹：用户在同步设置里改地址后自动对新地址
  // 重新握手，不会复用旧地址的公钥（避免一类「换了服务端却仍用旧信任根」的错）。
  final Map<String, SimplePublicKey> _serverPubs = {};
  final Map<String, String> _fingerprints = {};

  /// 已核对的服务端指纹（`origin → 指纹`），供 UI 展示供用户核对（§9.2）。
  Map<String, String> get fingerprints => Map.unmodifiable(_fingerprints);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path == kChannelHandshakePath) {
      return _inner.send(request);
    }
    final server = await _serverPublicKey(request.url);

    final x25519 = X25519();
    final eph = await x25519.newKeyPair();
    final ephPub = await eph.extractPublicKey();
    final shared = await x25519.sharedSecretKey(
      keyPair: eph,
      remotePublicKey: server,
    );
    final key = await _deriveKey(await shared.extractBytes());

    final reqId = base64.encode(randomBytes(16, null));
    final plain = await request.finalize().toBytes();
    final aad = channelAad(request.method, request.url.path, reqId);

    final headers = Map<String, String>.from(request.headers)
      ..[kHeaderChannelEnc] = '1'
      ..[kHeaderChannelEph] = base64.encode(ephPub.bytes)
      ..[kHeaderChannelReqID] = reqId
      ..remove('content-length');
    final wrapped = http.Request(request.method, request.url)
      ..headers.addAll(headers);
    // **只在确有正文时才发封装**：浏览器 fetch 不允许 GET/HEAD 带 body
    // （`Request with GET/HEAD method cannot have body`），而同步 pull 正是 GET。
    // 无正文请求仍然声明通道，以便照样拿到**加密响应**（否则数据会明文回来）；
    // 服务端把「声明通道 + 空正文」视为**空明文**（见 securechan/middleware.go）。
    if (plain.isNotEmpty) {
      wrapped.bodyBytes = utf8.encode(await _seal(
        key,
        randomBytes(EnvelopeFormat.nonceLength, null),
        plain,
        aad,
      ));
    }

    final resp = await _inner.send(wrapped);
    if (_header(resp.headers, kHeaderChannelEnc) != '1') {
      // 服务端在通道层就拒绝（400/409）或未启用通道：**明文错误响应**原样返回，
      // 让上层拿到真实状态码与错误码（`invalid-channel` / `replayed` / `channel-disabled`）。
      return resp;
    }
    final cipher = await resp.stream.toBytes();
    final plainBytes = await _open(
      key,
      utf8.decode(cipher),
      channelAad(request.method, request.url.path, reqId),
    );
    final outHeaders = Map<String, String>.from(resp.headers)
      ..removeWhere((k, _) => k.toLowerCase() == kHeaderChannelEnc.toLowerCase());
    outHeaders['content-type'] = _sniffContentType(plainBytes);
    return http.StreamedResponse(
      Stream.value(plainBytes),
      resp.statusCode,
      contentLength: plainBytes.length,
      headers: outHeaders,
      reasonPhrase: resp.reasonPhrase,
      request: request,
    );
  }

  @override
  void close() => _inner.close();

  Future<SimplePublicKey> _serverPublicKey(Uri requestUrl) async {
    final origin = _originOf(requestUrl);
    final cached = _serverPubs[origin];
    if (cached != null) return cached;

    final handshake = requestUrl.replace(
      path: kChannelHandshakePath,
      query: '',
      fragment: '',
    );
    final resp = await _inner.get(handshake);
    if (resp.statusCode != 200) {
      throw ChannelException('握手失败（HTTP ${resp.statusCode}）');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final pub = data['serverPub'] as String?;
    final fp = data['fingerprint'] as String?;
    if (pub == null || pub.isEmpty || fp == null || fp.isEmpty) {
      throw ChannelException('握手响应缺少 serverPub / fingerprint');
    }
    // TOFU：首次记录；此后不一致即**阻断**（疑似中间人）。
    final known = await _trust?.fingerprint;
    if (known != null && known != fp) {
      throw ChannelTrustException(known, fp);
    }
    if (known == null) {
      await _trust?.saveFingerprint(fp);
    }
    final bytes = base64.decode(pub);
    if (bytes.length != 32) {
      throw ChannelException('serverPub 长度非法（${bytes.length}）');
    }
    _fingerprints[origin] = fp;
    return _serverPubs[origin] = SimplePublicKey(bytes, type: KeyPairType.x25519);
  }

  static String _originOf(Uri u) => '${u.scheme}://${u.authority}';

  /// 大小写**不敏感**的响应头查找：不依赖底层实现是否返回大小写不敏感的 Map。
  static String? _header(Map<String, String> headers, String name) {
    final want = name.toLowerCase();
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == want) return e.value;
    }
    return null;
  }

  Future<Uint8List> _deriveKey(List<int> shared) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: NotebookCrypto.keyLength);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(shared),
      // salt 为空：HKDF 以 HashLen 零值代入（RFC 5869 §2.2），与服务端口径一致。
      nonce: const <int>[],
      info: utf8.encode(kChannelKdfInfo),
    );
    return Uint8List.fromList(await derived.extractBytes());
  }

  Future<String> _seal(
    List<int> key,
    List<int> nonce,
    List<int> plaintext,
    List<int> aad,
  ) async {
    final box = await AesGcm.with256bits().encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: aad,
    );
    final env = <int>[
      EnvelopeFormat.version,
      EnvelopeFormat.algAes256Gcm,
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ];
    return base64.encode(env);
  }

  Future<Uint8List> _open(
    List<int> key,
    String envelope,
    List<int> aad,
  ) async {
    final List<int> raw;
    try {
      raw = base64.decode(envelope);
    } on FormatException {
      throw ChannelException('响应不是合法 base64 封装');
    }
    if (raw.length < EnvelopeFormat.minLength) {
      throw ChannelException('响应封装过短');
    }
    if (raw[0] != EnvelopeFormat.version ||
        raw[1] != EnvelopeFormat.algAes256Gcm) {
      throw ChannelException('响应封装版本 / 算法不受支持');
    }
    final nonce = raw.sublist(2, 2 + EnvelopeFormat.nonceLength);
    final tagStart = raw.length - EnvelopeFormat.tagLength;
    final ct = raw.sublist(2 + EnvelopeFormat.nonceLength, tagStart);
    final tag = raw.sublist(tagStart);
    try {
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(ct, nonce: nonce, mac: Mac(tag)),
        secretKey: SecretKey(key),
        aad: aad,
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw ChannelException('响应校验失败（密文被篡改或 AAD 不符）');
    }
  }

  /// 依据明文首字节猜内容类型：JSON 与二进制各归其位（上层只按字节 / `jsonDecode` 消费）。
  static String _sniffContentType(Uint8List plain) {
    if (plain.isEmpty) return 'application/octet-stream';
    final first = plain.first;
    if (first == 0x7b || first == 0x5b) {
      return 'application/json; charset=utf-8';
    }
    return 'application/octet-stream';
  }
}

/// 按策略构造「通道感知」的 HTTP 客户端；**返回 null 表示该地址无需通道**（https 或强制明文）。
///
/// 供 UI 层直接传给 `AuthClient` / `SyncClient`，从而**不必**让 Flutter 侧直接依赖 `http` 包。
http.Client? channelAwareClient({
  required String baseUrl,
  ChannelTrustStore? trust,
  bool forcePlaintext = false,
  http.Client? inner,
}) {
  if (!shouldUseSecureChannel(baseUrl, forcePlaintext: forcePlaintext)) {
    return null;
  }
  return SecureChannelClient(
    inner: inner ?? http.Client(),
    trust: trust,
  );
}
