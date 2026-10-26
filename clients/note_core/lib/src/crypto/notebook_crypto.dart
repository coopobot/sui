/// 加密笔记本的**密码学接缝**（M10-T29 / FR-51）。
///
/// 口径见 `technology/design/low-level-design/encrypted-notebook.md` §4.3 / §5：
///
/// * `K_nb = HKDF-SHA256(Argon2id(锁定密码, salt, m=64 MiB, t=3, p=1), info="sui-notebook-v1")`
///   —— 其中 Argon2id 的输出（32B）作 HKDF 的 IKM；HKDF **salt 为空**（RFC 5869 以 HashLen 零值代入）。
/// * `verifier = HKDF-SHA256(K_nb, info="sui-notebook-verifier")` —— 供**快速校验锁定密码**，
///   不含任何秘密（攻击者仍须对 salt 跑 Argon2id 做离线暴力）。
/// * 字段密文 = `base64(ver(1B) | alg(1B) | nonce(12B) | ct | tag(16B))`。
/// * **AAD** = `utf8("<notebookId>|<noteId>|<field>")`，把密文绑定到「哪本笔记本的哪条笔记的哪个字段」，
///   防止密文被**跨笔记 / 跨字段搬运**替换。
///
/// 密钥 `K_nb` **只存在于解锁后的内存**：本文件不落库、不上传、不随同步（BR-51.4 / 51.5）。
/// 逐字节互操作已由 Spike-003 验证（AES-256-GCM / HKDF / 封装与 Go 标准库一致，且与
/// RFC 7748 / 5869 / 8439 公开向量吻合）；本文件另以 Spike 固化的向量做回归门禁。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 加密字段：标题 / 正文（决定 AAD 中的字段标记）。
enum NotebookField {
  title('title'),
  content('content');

  const NotebookField(this.tag);

  /// AAD 中使用的字段标记。
  final String tag;
}

/// 自描述封装的常量（设计 §4.3）。
abstract final class EnvelopeFormat {
  /// 封装格式版本（当前 `0x01`）。
  static const version = 0x01;

  /// 算法标识：AES-256-GCM（服务端受保护通道亦只支持此算法）。
  static const algAes256Gcm = 0x01;

  /// 算法标识：ChaCha20-Poly1305（**服务端不参与**，Go 标准库无此原语；预留位）。
  static const algChacha20Poly1305 = 0x02;

  static const nonceLength = 12;
  static const tagLength = 16;

  /// 最短长度 = ver + alg + nonce + tag（空明文）。
  static const minLength = 2 + nonceLength + tagLength;
}

/// 解锁失败（`verifier` 不匹配）：**不泄露任何明文**，可重复尝试。
class NotebookUnlockException implements Exception {
  const NotebookUnlockException();

  @override
  String toString() => '锁定密码错误';
}

/// 解密失败（tag 校验不通过 / 封装非法 / 算法不支持）：拒绝解密，**不吐半截明文**。
class NotebookDecryptException implements Exception {
  const NotebookDecryptException(this.message);

  final String message;

  @override
  String toString() => '无法解密：$message';
}

/// `crypto_meta` 格式非法（损坏）：**不静默当明文处理**（避免误展示）。
class CryptoMetaFormatException implements Exception {
  const CryptoMetaFormatException(this.message);

  final String message;

  @override
  String toString() => 'crypto_meta 无效：$message';
}

/// 加密元数据（**非敏感**，随笔记本同步）：算法版本 / KDF 参数 / `salt` / `verifier`。
class CryptoMeta {
  const CryptoMeta({
    this.v = 1,
    this.kdf = kdfArgon2id,
    required this.memoryKiB,
    required this.iterations,
    required this.parallelism,
    required this.salt,
    required this.verifier,
  });

  /// KDF 名称（当前仅 argon2id）。
  static const kdfArgon2id = 'argon2id';

  final int v;
  final String kdf;

  /// 内存成本，单位 **KiB**（65536 KiB = 64 MiB）。
  final int memoryKiB;
  final int iterations;
  final int parallelism;
  final Uint8List salt;
  final Uint8List verifier;

  Map<String, dynamic> toMap() => {
        'v': v,
        'kdf': kdf,
        'm': memoryKiB,
        't': iterations,
        'p': parallelism,
        'salt': base64.encode(salt),
        'verifier': base64.encode(verifier),
      };

  String toJson() => jsonEncode(toMap());

  /// 解析线上 / 落库的 `crypto_meta`。
  factory CryptoMeta.fromJson(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw CryptoMetaFormatException('不是合法 JSON（$e）');
    }
    if (decoded is! Map) {
      throw const CryptoMetaFormatException('不是对象');
    }
    final v = decoded['v'];
    final kdf = decoded['kdf'];
    final m = decoded['m'];
    final t = decoded['t'];
    final p = decoded['p'];
    final salt = decoded['salt'];
    final verifier = decoded['verifier'];
    if (v is! int ||
        kdf is! String ||
        m is! int ||
        t is! int ||
        p is! int ||
        salt is! String ||
        verifier is! String) {
      throw const CryptoMetaFormatException('字段缺失或类型不符');
    }
    if (kdf != kdfArgon2id) {
      throw CryptoMetaFormatException('不支持的 KDF: $kdf');
    }
    if (m <= 0 || t <= 0 || p <= 0) {
      throw const CryptoMetaFormatException('KDF 参数必须为正');
    }
    return CryptoMeta(
      v: v,
      kdf: kdf,
      memoryKiB: m,
      iterations: t,
      parallelism: p,
      salt: _decodeB64(salt, 'salt'),
      verifier: _decodeB64(verifier, 'verifier'),
    );
  }
}

/// 笔记本密钥 `K_nb`（32 字节，**只存内存**）。
class NotebookKey {
  NotebookKey(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    if (this.bytes.length != NotebookCrypto.keyLength) {
      throw ArgumentError.value(
          this.bytes.length, 'K_nb 长度', '必须 ${NotebookCrypto.keyLength} 字节');
    }
  }

  /// 密钥字节。回锁时应**丢弃本对象**（Dart 无法保证擦除内存，属已知限制）。
  final Uint8List bytes;
}

/// 密钥派生与 `verifier`（设计 §5）。
abstract final class NotebookCrypto {
  /// 默认 KDF 参数（设计 §5.1：Argon2id m=64 MiB / t=3 / p=1）。
  static const defaultMemoryKiB = 65536;
  static const defaultIterations = 3;
  static const defaultParallelism = 1;

  /// `K_nb` 与 `verifier` 长度。
  static const keyLength = 32;

  /// 新建笔记本时随机 `salt` 的长度。
  static const saltLength = 16;

  static const _kdfInfo = 'sui-notebook-v1';
  static const _verifierInfo = 'sui-notebook-verifier';

  /// 由锁定密码派生 `K_nb`（参数与 `salt` 取自 [meta]）。
  static Future<NotebookKey> deriveKey({
    required String password,
    required CryptoMeta meta,
  }) async {
    final argon = Argon2id(
      memory: meta.memoryKiB,
      parallelism: meta.parallelism,
      iterations: meta.iterations,
      hashLength: keyLength,
    );
    final stretched =
        await argon.deriveKeyFromPassword(password: password, nonce: meta.salt);
    final stretchedBytes = await stretched.extractBytes();
    return _hkdf(stretchedBytes, _kdfInfo);
  }

  /// 计算 `verifier`（`HKDF(K_nb, info="sui-notebook-verifier")`）。
  static Future<Uint8List> computeVerifier(NotebookKey key) async {
    final v = await _hkdf(key.bytes, _verifierInfo);
    return v.bytes;
  }

  /// **设为加密笔记本**（一次性）：生成随机 `salt`、派生 `K_nb`、算出 `verifier`。
  ///
  /// [random] 仅供测试注入（默认 CSPRNG）。
  static Future<({CryptoMeta meta, NotebookKey key})> create({
    required String password,
    Random? random,
    List<int>? salt,
  }) async {
    final saltBytes = salt == null
        ? randomBytes(saltLength, random)
        : Uint8List.fromList(salt);
    final draft = CryptoMeta(
      memoryKiB: defaultMemoryKiB,
      iterations: defaultIterations,
      parallelism: defaultParallelism,
      salt: saltBytes,
      verifier: Uint8List(0),
    );
    final key = await deriveKey(password: password, meta: draft);
    final verifier = await computeVerifier(key);
    return (
      meta: CryptoMeta(
        memoryKiB: defaultMemoryKiB,
        iterations: defaultIterations,
        parallelism: defaultParallelism,
        salt: saltBytes,
        verifier: verifier,
      ),
      key: key,
    );
  }

  /// 解锁：先派生再比对 `verifier`（常量时间）；不匹配抛 [NotebookUnlockException]。
  static Future<NotebookKey> unlock({
    required String password,
    required CryptoMeta meta,
  }) async {
    final key = await deriveKey(password: password, meta: meta);
    final candidate = await computeVerifier(key);
    if (!constantTimeEquals(candidate, meta.verifier)) {
      throw const NotebookUnlockException();
    }
    return key;
  }

  static Future<NotebookKey> _hkdf(List<int> ikm, String info) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: keyLength);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(ikm),
      // 设计未给 salt ⇒ HKDF 以 HashLen 零值作 salt（RFC 5869 §2.2），此处传空列表。
      nonce: const <int>[],
      info: utf8.encode(info),
    );
    return NotebookKey(await derived.extractBytes());
  }
}

/// 单条字段（标题 / 正文）的加解密；解锁态使用。
class NotebookFieldCipher {
  NotebookFieldCipher(this.key);

  final NotebookKey key;

  static final AesGcm _aes = AesGcm.with256bits();

  /// AAD：`utf8("<notebookId>|<noteId>|<field>")`（设计 §4.3）。
  static List<int> aadFor({
    required String notebookId,
    required String noteId,
    required NotebookField field,
  }) =>
      utf8.encode('$notebookId|$noteId|${field.tag}');

  /// 加密为 base64 自描述封装（新随机 nonce，**每条唯一**）。
  ///
  /// [random] 仅供测试注入。
  Future<String> encrypt({
    required String notebookId,
    required String noteId,
    required NotebookField field,
    required String plaintext,
    Random? random,
  }) async {
    final nonce = randomBytes(EnvelopeFormat.nonceLength, random);
    final box = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(key.bytes),
      nonce: nonce,
      aad: aadFor(notebookId: notebookId, noteId: noteId, field: field),
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

  /// 解密；封装非法 / 算法不支持 / tag 校验失败一律抛 [NotebookDecryptException]。
  Future<String> decrypt({
    required String notebookId,
    required String noteId,
    required NotebookField field,
    required String envelope,
  }) async {
    final bytes = decodeEnvelope(envelope) ??
        (throw const NotebookDecryptException('封装非法或不是本系统的密文'));
    final alg = bytes[1];
    if (alg != EnvelopeFormat.algAes256Gcm) {
      throw NotebookDecryptException('不支持的算法标识 0x${alg.toRadixString(16)}');
    }
    final nonce = bytes.sublist(2, 2 + EnvelopeFormat.nonceLength);
    final tagStart = bytes.length - EnvelopeFormat.tagLength;
    final ct = bytes.sublist(2 + EnvelopeFormat.nonceLength, tagStart);
    final tag = bytes.sublist(tagStart);
    try {
      final clear = await _aes.decrypt(
        SecretBox(ct, nonce: nonce, mac: Mac(tag)),
        secretKey: SecretKey(key.bytes),
        aad: aadFor(notebookId: notebookId, noteId: noteId, field: field),
      );
      return utf8.decode(clear);
    } on SecretBoxAuthenticationError {
      throw const NotebookDecryptException('校验失败（密码不符或内容被篡改）');
    } on FormatException catch (e) {
      throw NotebookDecryptException('明文不是合法 UTF-8（$e）');
    }
  }

  /// 判定某个取值是否为**本系统的自描述密文封装**。
  ///
  /// 用途：避免对已加密字段二次加密；列表 / 编辑区据此走「占位」而非当明文渲染。
  static bool isEnvelope(String value) => decodeEnvelope(value) != null;

  /// 解析封装；非本系统格式返回 null（**不抛异常**，供判定使用）。
  static Uint8List? decodeEnvelope(String value) {
    if (value.isEmpty) return null;
    final List<int> bytes;
    try {
      bytes = base64.decode(value);
    } on FormatException {
      return null;
    }
    if (bytes.length < EnvelopeFormat.minLength) return null;
    if (bytes[0] != EnvelopeFormat.version) return null;
    if (bytes[1] != EnvelopeFormat.algAes256Gcm &&
        bytes[1] != EnvelopeFormat.algChacha20Poly1305) {
      return null;
    }
    return Uint8List.fromList(bytes);
  }
}

/// 生成 [length] 字节随机数（默认 CSPRNG；[random] 仅供测试注入）。
Uint8List randomBytes(int length, Random? random) {
  final rng = random ?? Random.secure();
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

/// 常量时间比较（避免用 `==` 泄露 verifier 前缀信息）。
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Uint8List _decodeB64(String value, String field) {
  try {
    return base64.decode(value);
  } on FormatException catch (e) {
    throw CryptoMetaFormatException('$field 不是合法 base64（$e）');
  }
}
