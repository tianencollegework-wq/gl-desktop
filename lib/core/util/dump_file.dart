import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 把一段文本落成文件，返回文件路径。
///
/// 与 [ProtocolLog.dumpToFile] 同一个目录（应用文档目录）与同一套时间戳命名，
/// 导出的东西放在一起好找。
///
/// 抽出来一个通用小工具而不是塞在通话里面：以后前台服务、音频路由那几步
/// （S6.5 / S6.4）都要导出各自的诊断，落盘这段逻辑不该抄第二遍。
Future<String> writeTextDump({
  required String prefix,
  required String content,
  String extension = 'txt',
  DateTime? at,
}) async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File(
    '${dir.path}/${prefix}_${_stamp(at ?? DateTime.now())}.$extension',
  );
  await file.writeAsString(content);
  return file.path;
}

/// `20260919T210312`（不用冒号：Windows 上文件名里带冒号会出问题）
String _stamp(DateTime at) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${at.year}${two(at.month)}${two(at.day)}T'
      '${two(at.hour)}${two(at.minute)}${two(at.second)}';
}
