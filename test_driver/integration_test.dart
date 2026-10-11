import 'package:integration_test/integration_test_driver.dart';

/// `flutter drive` 的宿主机驱动（**不是测试用例**）。
///
/// 为什么不用 `flutter test integration_test/...`：那条路跑完会把包**卸载**掉
/// （手机上的登录态跟着没了）。`flutter drive --keep-app-running` 只是安装、
/// 跑完留着，所以真机自检优先用它：
///
/// ```
/// flutter drive --driver=test_driver/integration_test.dart \
///   --target=integration_test/call_pip_smoke_test.dart -d <设备号> --keep-app-running
/// ```
Future<void> main() => integrationDriver();
