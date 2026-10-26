import 'dart:convert';
import 'dart:typed_data';

/// M13（FR-60 编码自动识别 / BR-61.7 解码降级）—— 详细设计 §4.2。
///
/// 顺序固定：**BOM 优先** → **无 BOM 的 UTF-16 启发式** → 否则按 UTF-8（非法字节
/// 以替换字符 U+FFFD 降级，**不**放弃整篇）。
///
/// GBK / GB18030 本轮**不做**（BR-61.7 已知边界）：没有编码表依赖，只能落到
/// 「替换字符 + 报告标注」这条降级路径上。

/// 解码结果。
class DecodedText {
  const DecodedText({
    required this.text,
    required this.encoding,
    this.degraded = false,
  });

  /// 解码后的文本（可能含 U+FFFD）。
  final String text;

  /// 实际采用的编码名（`UTF-8` / `UTF-8 BOM` / `UTF-16LE` / `UTF-16BE`
  /// / `UTF-16LE(heuristic)` / `UTF-16BE(heuristic)`）；报告与诊断用。
  final String encoding;

  /// 是否发生了「非法字节 → 替换字符」的降级（BR-61.7 / AC-251）。
  final bool degraded;
}

/// 无 BOM 的 UTF-16 启发式判定窗口（§4.2 第 2 条）。
const int _heuristicWindow = 512;

/// 触发启发式的 `0x00` 占比阈值（§4.2 第 2 条：≥ 20%）。
const double _nulRatioThreshold = 0.2;

/// 把原始字节解码为文本（BOM / 启发式 / UTF-8 降级）。
DecodedText decodeTextBytes(Uint8List bytes) {
  // ① BOM 优先。UTF-16 的 BOM 必须按**码元**（2 字节）对齐去除，
  //    不能按字节位移误伤首字符（§4.2 第 1 条）。
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return _decodeUtf8(bytes.sublist(3), label: 'UTF-8 BOM');
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _decodeUtf16(bytes.sublist(2),
        littleEndian: true, label: 'UTF-16LE');
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _decodeUtf16(bytes.sublist(2),
        littleEndian: false, label: 'UTF-16BE');
  }

  // ② 无 BOM 的 UTF-16 启发式：取前 512 字节，`0x00` 占比 ≥ 20% 才怀疑 UTF-16；
  //    再看**偶数位** / **奇数位**谁含更多 `0x00`：小码元（ASCII / 拉丁）在高字节恒为
  //    0x00，故**奇数位多 = LE**（低字节在前），**偶数位多 = BE**。
  //
  //    注：详细设计 §4.2 第 2 条的括注写的是「偶数位多 = LE」，与 UTF-16 的字节布局
  //    相反（Lehmer 码元布局：[low, high]）；此处按**实测正确**的方向实现，
  //    并在回报中作为契约偏差提出。
  final window =
      bytes.length > _heuristicWindow ? _heuristicWindow : bytes.length;
  if (window >= 4) {
    var nuls = 0;
    var evenNuls = 0;
    var oddNuls = 0;
    for (var i = 0; i < window; i++) {
      if (bytes[i] == 0x00) {
        nuls++;
        if (i.isEven) {
          evenNuls++;
        } else {
          oddNuls++;
        }
      }
    }
    if (nuls / window >= _nulRatioThreshold && evenNuls != oddNuls) {
      final little = oddNuls > evenNuls;
      return _decodeUtf16(
        bytes,
        littleEndian: little,
        label: little ? 'UTF-16LE(heuristic)' : 'UTF-16BE(heuristic)',
      );
    }
  }

  // ③ 否则按 UTF-8：先严格解码，抛 FormatException 时改 allowMalformed 降级。
  return _decodeUtf8(bytes, label: 'UTF-8');
}

/// 严格 UTF-8 解码 → 失败则替换字符降级（BR-61.7）。
DecodedText _decodeUtf8(Uint8List bytes, {required String label}) {
  try {
    return DecodedText(text: utf8.decode(bytes), encoding: label);
  } on FormatException {
    return DecodedText(
      text: utf8.decode(bytes, allowMalformed: true),
      encoding: label,
      // 严格解码失败即「存在非法字节序列」——即便替换字符数量为 0（理论上不会），
      // 也按 BR-61.7 在报告里标注。
      degraded: true,
    );
  }
}

/// UTF-16 解码（按字节序组装码元，正确处理代理对）。
///
/// 替代 `String.fromCharCodes(bytes)`：后者会把每个**字节**当成一个码元，
/// 对非 ASCII 内容是毁灭性的。
DecodedText _decodeUtf16(
  Uint8List bytes, {
  required bool littleEndian,
  required String label,
}) {
  final units = <int>[];
  var degraded = false;
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(littleEndian
        ? (bytes[i] | (bytes[i + 1] << 8))
        : ((bytes[i] << 8) | bytes[i + 1]));
  }
  // 奇数字节：末字节无法组成码元，按「非法字节序列」降级（BR-61.7）。
  if (bytes.length.isOdd) degraded = true;

  final buf = StringBuffer();
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u >= 0xD800 && u <= 0xDBFF) {
      if (i + 1 < units.length) {
        final lo = units[i + 1];
        if (lo >= 0xDC00 && lo <= 0xDFFF) {
          buf.writeCharCode(0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00));
          i++;
          continue;
        }
      }
      buf.writeCharCode(0xFFFD); // 孤立高代理 → 替换字符
      degraded = true;
      continue;
    }
    if (u >= 0xDC00 && u <= 0xDFFF) {
      buf.writeCharCode(0xFFFD); // 孤立低代理 → 替换字符
      degraded = true;
      continue;
    }
    buf.writeCharCode(u);
  }
  return DecodedText(text: buf.toString(), encoding: label, degraded: degraded);
}
