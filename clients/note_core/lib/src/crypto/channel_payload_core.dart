/// 受保护通道载荷的**参考实现**（`v0.16.4` / FR-92）。
///
/// 线路格式与 `v0.16.3` **逐字节一致**：
/// `base64(ver(1) | alg(1) | nonce(12) | ct | tag(16))` 的 **utf8 字节**。
///
/// 本文件只做**纯计算**（不碰网络、不碰凭证、不处理 TOFU / 重放），供受保护通道的
/// 主路径与**工作 isolate** 共用 —— 两边跑同一份代码，线路字节不可能分叉。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'notebook_crypto.dart' show EnvelopeFormat, randomBytes;

/// 通道载荷走**工作 isolate** 的阈值（字节）。
///
/// 低于阈值同线程执行（64 KiB 加密约 7 ms，比 isolate 调度还便宜）；
/// 高于阈值交给工作 isolate，避免 UI isolate 被整包加密 / base64 冻结（FR-92）。
const int kChannelOffMainThreshold = 64 * 1024;

/// 载荷封装 / 解封失败。由 `SecureChannelClient` 转成既有的 `ChannelException`，
/// 报文与 `v0.16.3` 完全一致（BR-92.3）。
class ChannelPayloadException implements Exception {
  const ChannelPayloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 参考实现：整包 AES-256-GCM → `ver|alg|nonce|ct|tag` → base64 → utf8 字节。
///
/// [nonce] 缺省时随机生成 12 字节（与既有实现一致）；测试可传入固定值以断言字节。
Future<Uint8List> sealChannelEnvelopeInline({
  required List<int> key,
  required Uint8List plaintext,
  required Uint8List aad,
  List<int>? nonce,
}) async {
  final n = nonce ?? randomBytes(EnvelopeFormat.nonceLength, null);
  final box = await AesGcm.with256bits().encrypt(
    plaintext,
    secretKey: SecretKey(key),
    nonce: n,
    aad: aad,
  );
  final env = Uint8List(
    2 + n.length + box.cipherText.length + box.mac.bytes.length,
  );
  env[0] = EnvelopeFormat.version;
  env[1] = EnvelopeFormat.algAes256Gcm;
  var off = 2;
  env.setRange(off, off + n.length, n);
  off += n.length;
  env.setRange(off, off + box.cipherText.length, box.cipherText);
  off += box.cipherText.length;
  env.setRange(off, off + box.mac.bytes.length, box.mac.bytes);
  // 线上是 base64 文本的 utf8 字节（与 v0.16.3 的 `utf8.encode(base64.encode(env))` 一致）。
  return Uint8List.fromList(utf8.encode(base64.encode(env)));
}

/// 参考实现：解封线上字节（base64 → 版本 / 算法校验 → AES-256-GCM）。
///
/// 非法封装 / 校验失败一律抛 [ChannelPayloadException]，文案与 `v0.16.3` 相同。
Future<Uint8List> openChannelEnvelopeInline({
  required List<int> key,
  required Uint8List envelope,
  required Uint8List aad,
}) async {
  final String text;
  try {
    text = utf8.decode(envelope);
  } on FormatException {
    throw const ChannelPayloadException('响应不是合法 base64 封装');
  }
  final List<int> raw;
  try {
    raw = base64.decode(text);
  } on FormatException {
    throw const ChannelPayloadException('响应不是合法 base64 封装');
  }
  if (raw.length < EnvelopeFormat.minLength) {
    throw const ChannelPayloadException('响应封装过短');
  }
  if (raw[0] != EnvelopeFormat.version ||
      raw[1] != EnvelopeFormat.algAes256Gcm) {
    throw const ChannelPayloadException('响应封装版本 / 算法不受支持');
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
    throw const ChannelPayloadException('响应校验失败（密文被篡改或 AAD 不符）');
  }
}
