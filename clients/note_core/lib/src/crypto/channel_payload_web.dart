/// 受保护通道载荷：**Web 实现**（`v0.16.4` / FR-92）。
///
/// 浏览器没有 isolate：同线程执行，功能与**线路字节**和原生完全一致（BR-92.4）。
/// 条件导入保证 Web 构建不会引入 `dart:isolate`。
library;

import 'dart:typed_data';

import 'channel_payload_core.dart';

Future<Uint8List> sealChannelEnvelope({
  required List<int> key,
  required Uint8List plaintext,
  required Uint8List aad,
  List<int>? nonce,
}) =>
    sealChannelEnvelopeInline(
      key: key,
      plaintext: plaintext,
      aad: aad,
      nonce: nonce,
    );

Future<Uint8List> openChannelEnvelope({
  required List<int> key,
  required Uint8List envelope,
  required Uint8List aad,
}) =>
    openChannelEnvelopeInline(key: key, envelope: envelope, aad: aad);
