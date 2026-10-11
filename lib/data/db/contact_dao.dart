import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../model/contact.dart';
import '../model/time_units.dart';
import 'app_database.dart';

/// 通讯录的数据库访问（S5.1）。用 `extension`（与其它 DAO 一致）。
///
/// 同步规则与会话列表同一个思路：**非空才做删除差集**，空响应保留本地——
/// 一次空响应（token 过期、网关抽风）不该把用户的通讯录清空。
///
/// 但比会话多一条：好友与群聊来自**两个接口**，所以差集只在自己那一类里做
/// （拉好友失败不能连带把群聊删了）。
extension ContactDao on AppDatabase {
  /// 全部通讯录（好友 + 群聊 + 系统通知）
  Stream<List<Contact>> watchContacts() =>
      select(dbContacts).watch().map(_byGroupThenName);

  Future<List<Contact>> allContacts() async =>
      _byGroupThenName(await select(dbContacts).get());

  /// 好友（老端 `allContacts.filter(is_group==0)`）
  Stream<List<Contact>> watchFriends() => watchContacts().map(
    (list) => list.where((contact) => contact.isFriend).toList(),
  );

  /// 群聊（老端 `getGroupList`）
  Stream<List<Contact>> watchGroups() => watchContacts().map(
    (list) => list.where((contact) => contact.isChatGroup).toList(),
  );

  /// 系统通知会话（老端 `allContacts.filter(is_group==2)`）
  Stream<List<Contact>> watchSystems() => watchContacts().map(
    (list) => list.where((contact) => contact.isSystem).toList(),
  );

  Future<Contact?> findContact(String id) async {
    final row = await (select(
      dbContacts,
    )..where((table) => table.id.equals(id))).getSingleOrNull();
    return row == null ? null : Contact.fromRow(row);
  }

  Future<void> upsertContact(Contact contact) async {
    if (contact.id.isEmpty) return;
    await into(dbContacts).insertOnConflictUpdate(contact.toCompanion());
  }

  Future<void> upsertContacts(List<Contact> contacts) async {
    final rows = contacts.where((contact) => contact.id.isNotEmpty).toList();
    if (rows.isEmpty) return;
    await batch((batch) {
      batch.insertAllOnConflictUpdate(
        dbContacts,
        rows.map((contact) => contact.toCompanion()).toList(),
      );
    });
  }

  /// 局部更新（WS 的 `isOnline` / `editGroupName` 这类只带一两个字段的事件）
  Future<void> patchContact(String id, DbContactsCompanion patch) async {
    await (update(dbContacts)..where((table) => table.id.equals(id))).write(
      patch.copyWith(updatedAt: Value(nowMillis())),
    );
  }

  Future<void> deleteContact(String id) async {
    await (delete(dbContacts)..where((table) => table.id.equals(id))).go();
  }

  /// 服务端同步一份列表（好友或群聊）。
  ///
  /// [kinds] 是这次同步覆盖的 `is_group` 取值，用来限定差集范围：
  /// 拉好友时顺带带回的系统通知（`is_group == 2`）与好友（`0`）一起换，
  /// 但绝不碰群聊（`1`）。
  Future<void> syncContacts(
    List<Contact> contacts, {
    required Set<int> kinds,
  }) async {
    final incoming = contacts
        .where(
          (contact) => contact.id.isNotEmpty && kinds.contains(contact.isGroup),
        )
        .toList();
    if (incoming.isEmpty) {
      debugPrint('[通讯录] 服务端返回空列表，保留本地缓存（不清空通讯录）');
      return;
    }
    final ids = incoming.map((contact) => contact.id).toList();
    await batch((batch) {
      batch.insertAllOnConflictUpdate(
        dbContacts,
        incoming.map((contact) => contact.toCompanion()).toList(),
      );
      // 服务端不再返回的（同类的）项就从列表里去掉
      batch.deleteWhere(
        dbContacts,
        (table) => table.isGroup.isIn(kinds) & table.id.isNotIn(ids),
      );
    });
  }

  /// 清空（登出用：换账号不该看到上一个人的通讯录）
  Future<void> clearContacts() async => delete(dbContacts).go();

  /// 数据库里的顺序：先按 `is_group`（好友 → 群聊 → 系统），再按名字拼音，
  /// 让流每次吐出同样的顺序（界面上还会再按首字母分组一次）。
  List<Contact> _byGroupThenName(List<DbContact> rows) {
    final contacts = rows.map(Contact.fromRow).toList();
    contacts.sort((a, b) {
      final byKind = a.isGroup.compareTo(b.isGroup);
      if (byKind != 0) return byKind;
      final byPy = a.namePy.compareTo(b.namePy);
      if (byPy != 0) return byPy;
      return a.id.compareTo(b.id);
    });
    return contacts;
  }
}
