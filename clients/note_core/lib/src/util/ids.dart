import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 内容寻址：计算字节的 sha256 十六进制。
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// 生成唯一 ID（UUID v4，无横线紧凑形式）。
String newId() => Uuid().generate();

/// 简易 UUID v4 生成（避免额外依赖风险，可用 crypto 随机源）。
class Uuid {
  static final Random _random = Random.secure();
  static const _hex = '0123456789abcdef';

  String generate() {
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = _random.nextInt(256);
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
    return _format(bytes);
  }

  String _format(Uint8List b) {
    final sb = StringBuffer();
    for (var i = 0; i < 16; i++) {
      if (i == 4 || i == 6 || i == 8 || i == 10) sb.write('-');
      sb
        ..write(_hex[b[i] >> 4])
        ..write(_hex[b[i] & 0x0f]);
    }
    return sb.toString();
  }
}