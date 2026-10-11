import 'dart:math';

/// 生成消息 id（老端 `utils.js::getUuid`）。
///
/// 格式与老端一模一样：`xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`（小写十六进制）。
/// 之所以不引 uuid 包：老端就是这么拼的，服务端只把它当不透明字符串。
///
/// [random] 只给测试用（固定种子就能断言请求体）。
String uuidV4([Random? random]) {
  final rng = random ?? Random();
  String hex(int length) => List<String>.generate(
    length,
    (_) => rng.nextInt(16).toRadixString(16),
  ).join();

  final variant = ((rng.nextInt(16) & 0x3) | 0x8).toRadixString(16);
  return '${hex(8)}-${hex(4)}-4${hex(3)}-$variant${hex(3)}-${hex(12)}';
}
