import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tables.dart';

part 'app_database.g.dart';

/// 本地数据库（S3.1）。
///
/// 老端把会话与消息放在 `uni.setStorageSync` 里（会话是整份数组反复读写，
/// 消息只留当前页），结果是：进聊天页必须等接口、会话列表每次都要重写整个数组。
/// 这里换成 SQLite：会话与消息都落库，界面直接读本地流，接口只做增量补齐。
///
/// 构造函数接受外部传入的 [QueryExecutor]，测试里就能换成内存库
/// （`NativeDatabase.memory()`），不用碰真实文件。
@DriftDatabase(tables: <Type>[DbConversations, DbMessages, DbContacts])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? _defaultExecutor());

  /// 真机上的落盘位置：`driftDatabase` 会放到应用数据目录（Android/iOS 都是私有目录）
  static QueryExecutor _defaultExecutor() =>
      driftDatabase(name: 'gracelink_im');

  @override
  int get schemaVersion => 3;

  /// 迁移策略。
  ///
  /// * 第 2 版（S4.4）：消息表加了 `clientId`（本机生成的消息 id）与
  ///   `status`（发送状态）两列——都有默认值，老库升上来不会丢数据。
  /// * 第 3 版（S5.1）：新增通讯录表（好友 / 群聊 / 系统通知），纯新增表。
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator migrator) => migrator.createAll(),
    onUpgrade: (Migrator migrator, int from, int to) async {
      if (from < 2) {
        await migrator.addColumn(dbMessages, dbMessages.clientId);
        await migrator.addColumn(dbMessages, dbMessages.status);
      }
      if (from < 3) {
        await migrator.createTable(dbContacts);
      }
    },
  );
}

/// 全局数据库实例。测试里用内存库覆盖它（`overrideWithValue`）。
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase();
  ref.onDispose(database.close);
  return database;
});
