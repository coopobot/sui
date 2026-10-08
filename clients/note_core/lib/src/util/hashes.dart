/// 内容寻址摘要（sha256）白名单（M10-T30 / BR-52.1）。
///
/// 口径与 `server/internal/api/validate.go` 的 `validSHA256` 一致：**定长 64 位小写十六进制**。
/// 该口径来自两端 `sha256` 的真实输出（`hex.EncodeToString` / Dart `hex` 编码），对既有数据透明。
///
/// 用途：把摘要**拼进文件路径或 URL 之前**先过这里。只**拒绝**、不清洗——`ReplaceAll('..','')`
/// 一类补救会让正常数据与攻击输入共用一条含歧义的路径（见 `input-validation.md` §3 / §9）。
library;

final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// 是否为合法的内容寻址摘要。
bool isValidSha256(String value) => _sha256Pattern.hasMatch(value);
