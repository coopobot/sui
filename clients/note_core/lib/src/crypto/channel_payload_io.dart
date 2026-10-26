/// 受保护通道载荷：**原生实现**（`v0.16.4` / FR-92）。
///
/// ≥ [kChannelOffMainThreshold] 的载荷交给**工作 isolate**：UI isolate 只做
/// `TransferableTypedData` **转移**（入参与出参都不复制），不再被 22 MB 的
/// AES-GCM / base64 冻结 ~3 s。
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'channel_payload_core.dart';

/// 封装请求载荷；大载荷在工作 isolate 内完成。
Future<Uint8List> sealChannelEnvelope({
  required List<int> key,
  required Uint8List plaintext,
  required Uint8List aad,
  List<int>? nonce,
}) async {
  if (plaintext.length < kChannelOffMainThreshold) {
    return sealChannelEnvelopeInline(
      key: key,
      plaintext: plaintext,
      aad: aad,
      nonce: nonce,
    );
  }
  final keyData = Uint8List.fromList(key);
  final aadData = Uint8List.fromList(aad);
  final nonceData = nonce == null ? null : Uint8List.fromList(nonce);
  // 转移所有权：主 isolate 的明文副本随即失效（调用方之后不再使用它），省掉 22 MB 复制。
  final input = TransferableTypedData.fromList([plaintext]);
  final sealed = await Isolate.run(() async {
    final plain = input.materialize().asUint8List();
    final out = await sealChannelEnvelopeInline(
      key: keyData,
      plaintext: plain,
      aad: aadData,
      nonce: nonceData,
    );
    return TransferableTypedData.fromList([out]);
  });
  return sealed.materialize().asUint8List();
}

/// 解封响应载荷；大载荷在工作 isolate 内完成。
///
/// isolate 内**不抛自定义异常**（避免跨 isolate 转发差异）：失败以 `error` 文案回传，
/// 在主 isolate 统一抛 [ChannelPayloadException]，保证与原地执行的异常类型 / 文案一致。
Future<Uint8List> openChannelEnvelope({
  required List<int> key,
  required Uint8List envelope,
  required Uint8List aad,
}) async {
  if (envelope.length < kChannelOffMainThreshold) {
    return openChannelEnvelopeInline(key: key, envelope: envelope, aad: aad);
  }
  final keyData = Uint8List.fromList(key);
  final aadData = Uint8List.fromList(aad);
  final input = TransferableTypedData.fromList([envelope]);
  final result =
      await Isolate.run<({TransferableTypedData? plain, String? error})>(
    () async {
      final raw = input.materialize().asUint8List();
      try {
        final plain =
            await openChannelEnvelopeInline(key: keyData, envelope: raw, aad: aadData);
        return (
          plain: TransferableTypedData.fromList([plain]),
          error: null,
        );
      } on ChannelPayloadException catch (e) {
        return (plain: null, error: e.message);
      }
    },
  );
  final error = result.error;
  if (error != null) throw ChannelPayloadException(error);
  return result.plain!.materialize().asUint8List();
}
