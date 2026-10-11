// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $DbConversationsTable extends DbConversations
    with TableInfo<$DbConversationsTable, DbConversation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DbConversationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _avatarMeta = const VerificationMeta('avatar');
  @override
  late final GeneratedColumn<String> avatar = GeneratedColumn<String>(
    'avatar',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _lastContentMeta = const VerificationMeta(
    'lastContent',
  );
  @override
  late final GeneratedColumn<String> lastContent = GeneratedColumn<String>(
    'last_content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _lastSendTimeMeta = const VerificationMeta(
    'lastSendTime',
  );
  @override
  late final GeneratedColumn<int> lastSendTime = GeneratedColumn<int>(
    'last_send_time',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastTypeMeta = const VerificationMeta(
    'lastType',
  );
  @override
  late final GeneratedColumn<String> lastType = GeneratedColumn<String>(
    'last_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('text'),
  );
  static const VerificationMeta _isGroupMeta = const VerificationMeta(
    'isGroup',
  );
  @override
  late final GeneratedColumn<int> isGroup = GeneratedColumn<int>(
    'is_group',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _unreadMeta = const VerificationMeta('unread');
  @override
  late final GeneratedColumn<int> unread = GeneratedColumn<int>(
    'unread',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isAtMeta = const VerificationMeta('isAt');
  @override
  late final GeneratedColumn<int> isAt = GeneratedColumn<int>(
    'is_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isTopMeta = const VerificationMeta('isTop');
  @override
  late final GeneratedColumn<int> isTop = GeneratedColumn<int>(
    'is_top',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isNoticeMeta = const VerificationMeta(
    'isNotice',
  );
  @override
  late final GeneratedColumn<int> isNotice = GeneratedColumn<int>(
    'is_notice',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<int> role = GeneratedColumn<int>(
    'role',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _depIdMeta = const VerificationMeta('depId');
  @override
  late final GeneratedColumn<int> depId = GeneratedColumn<int>(
    'dep_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isOnlineMeta = const VerificationMeta(
    'isOnline',
  );
  @override
  late final GeneratedColumn<int> isOnline = GeneratedColumn<int>(
    'is_online',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _draftMeta = const VerificationMeta('draft');
  @override
  late final GeneratedColumn<String> draft = GeneratedColumn<String>(
    'draft',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _extraMeta = const VerificationMeta('extra');
  @override
  late final GeneratedColumn<String> extra = GeneratedColumn<String>(
    'extra',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    displayName,
    avatar,
    lastContent,
    lastSendTime,
    lastType,
    isGroup,
    unread,
    isAt,
    isTop,
    isNotice,
    role,
    depId,
    isOnline,
    draft,
    extra,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'db_conversations';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbConversation> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    }
    if (data.containsKey('avatar')) {
      context.handle(
        _avatarMeta,
        avatar.isAcceptableOrUnknown(data['avatar']!, _avatarMeta),
      );
    }
    if (data.containsKey('last_content')) {
      context.handle(
        _lastContentMeta,
        lastContent.isAcceptableOrUnknown(
          data['last_content']!,
          _lastContentMeta,
        ),
      );
    }
    if (data.containsKey('last_send_time')) {
      context.handle(
        _lastSendTimeMeta,
        lastSendTime.isAcceptableOrUnknown(
          data['last_send_time']!,
          _lastSendTimeMeta,
        ),
      );
    }
    if (data.containsKey('last_type')) {
      context.handle(
        _lastTypeMeta,
        lastType.isAcceptableOrUnknown(data['last_type']!, _lastTypeMeta),
      );
    }
    if (data.containsKey('is_group')) {
      context.handle(
        _isGroupMeta,
        isGroup.isAcceptableOrUnknown(data['is_group']!, _isGroupMeta),
      );
    }
    if (data.containsKey('unread')) {
      context.handle(
        _unreadMeta,
        unread.isAcceptableOrUnknown(data['unread']!, _unreadMeta),
      );
    }
    if (data.containsKey('is_at')) {
      context.handle(
        _isAtMeta,
        isAt.isAcceptableOrUnknown(data['is_at']!, _isAtMeta),
      );
    }
    if (data.containsKey('is_top')) {
      context.handle(
        _isTopMeta,
        isTop.isAcceptableOrUnknown(data['is_top']!, _isTopMeta),
      );
    }
    if (data.containsKey('is_notice')) {
      context.handle(
        _isNoticeMeta,
        isNotice.isAcceptableOrUnknown(data['is_notice']!, _isNoticeMeta),
      );
    }
    if (data.containsKey('role')) {
      context.handle(
        _roleMeta,
        role.isAcceptableOrUnknown(data['role']!, _roleMeta),
      );
    }
    if (data.containsKey('dep_id')) {
      context.handle(
        _depIdMeta,
        depId.isAcceptableOrUnknown(data['dep_id']!, _depIdMeta),
      );
    }
    if (data.containsKey('is_online')) {
      context.handle(
        _isOnlineMeta,
        isOnline.isAcceptableOrUnknown(data['is_online']!, _isOnlineMeta),
      );
    }
    if (data.containsKey('draft')) {
      context.handle(
        _draftMeta,
        draft.isAcceptableOrUnknown(data['draft']!, _draftMeta),
      );
    }
    if (data.containsKey('extra')) {
      context.handle(
        _extraMeta,
        extra.isAcceptableOrUnknown(data['extra']!, _extraMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbConversation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbConversation(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      avatar: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}avatar'],
      )!,
      lastContent: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_content'],
      )!,
      lastSendTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_send_time'],
      )!,
      lastType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_type'],
      )!,
      isGroup: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_group'],
      )!,
      unread: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}unread'],
      )!,
      isAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_at'],
      )!,
      isTop: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_top'],
      )!,
      isNotice: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_notice'],
      )!,
      role: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}role'],
      )!,
      depId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}dep_id'],
      )!,
      isOnline: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_online'],
      )!,
      draft: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}draft'],
      )!,
      extra: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}extra'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $DbConversationsTable createAlias(String alias) {
    return $DbConversationsTable(attachedDatabase, alias);
  }
}

class DbConversation extends DataClass implements Insertable<DbConversation> {
  /// 会话 id：单聊是对方 `user_id`，群聊是 `group_id`，系统消息是 `system`
  final String id;
  final String displayName;
  final String avatar;

  /// 最后一条消息的预览文案（老端还会把它换成「[图片]」这类占位）
  final String lastContent;

  /// 最后一条消息时间，**毫秒**（见 `time_units.dart` 的归一化说明）
  final int lastSendTime;

  /// 最后一条消息类型（`text` / `image` / `webrtc` …）
  final String lastType;

  /// 是否群聊（老端 `is_group`：1 群、2 群且未读额外累加）
  final int isGroup;

  /// 未读数
  final int unread;

  /// 被 @ 的条数（老端 `is_at`）
  final int isAt;

  /// 置顶（1 置顶）
  final int isTop;

  /// 是否提醒（0 免打扰、1 提醒）
  final int isNotice;

  /// 群内角色（`< 3` 表示有撤回权限）
  final int role;

  /// 老端 `dep_id`（部门/组织维度）
  final int depId;

  /// 在线状态（`isOnline` 事件更新）
  final int isOnline;

  /// 草稿
  ///
  /// 老端把草稿存在 `draft_<会话 id>` 这个独立的 storage key 里；落库时直接做成
  /// 会话的一个列（语义完全一致，少一次关联查询）。同步接口不会下发 draft，
  /// 所以 [DbConversations] 的同步用 `toSyncCompanion()`（不含 draft）以免覆盖它。
  final String draft;

  /// 服务端给的其它字段（JSON），不在界面上用但不丢
  final String extra;

  /// 本地更新时间（毫秒），用于排查同步问题
  final int updatedAt;
  const DbConversation({
    required this.id,
    required this.displayName,
    required this.avatar,
    required this.lastContent,
    required this.lastSendTime,
    required this.lastType,
    required this.isGroup,
    required this.unread,
    required this.isAt,
    required this.isTop,
    required this.isNotice,
    required this.role,
    required this.depId,
    required this.isOnline,
    required this.draft,
    required this.extra,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['display_name'] = Variable<String>(displayName);
    map['avatar'] = Variable<String>(avatar);
    map['last_content'] = Variable<String>(lastContent);
    map['last_send_time'] = Variable<int>(lastSendTime);
    map['last_type'] = Variable<String>(lastType);
    map['is_group'] = Variable<int>(isGroup);
    map['unread'] = Variable<int>(unread);
    map['is_at'] = Variable<int>(isAt);
    map['is_top'] = Variable<int>(isTop);
    map['is_notice'] = Variable<int>(isNotice);
    map['role'] = Variable<int>(role);
    map['dep_id'] = Variable<int>(depId);
    map['is_online'] = Variable<int>(isOnline);
    map['draft'] = Variable<String>(draft);
    map['extra'] = Variable<String>(extra);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  DbConversationsCompanion toCompanion(bool nullToAbsent) {
    return DbConversationsCompanion(
      id: Value(id),
      displayName: Value(displayName),
      avatar: Value(avatar),
      lastContent: Value(lastContent),
      lastSendTime: Value(lastSendTime),
      lastType: Value(lastType),
      isGroup: Value(isGroup),
      unread: Value(unread),
      isAt: Value(isAt),
      isTop: Value(isTop),
      isNotice: Value(isNotice),
      role: Value(role),
      depId: Value(depId),
      isOnline: Value(isOnline),
      draft: Value(draft),
      extra: Value(extra),
      updatedAt: Value(updatedAt),
    );
  }

  factory DbConversation.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbConversation(
      id: serializer.fromJson<String>(json['id']),
      displayName: serializer.fromJson<String>(json['displayName']),
      avatar: serializer.fromJson<String>(json['avatar']),
      lastContent: serializer.fromJson<String>(json['lastContent']),
      lastSendTime: serializer.fromJson<int>(json['lastSendTime']),
      lastType: serializer.fromJson<String>(json['lastType']),
      isGroup: serializer.fromJson<int>(json['isGroup']),
      unread: serializer.fromJson<int>(json['unread']),
      isAt: serializer.fromJson<int>(json['isAt']),
      isTop: serializer.fromJson<int>(json['isTop']),
      isNotice: serializer.fromJson<int>(json['isNotice']),
      role: serializer.fromJson<int>(json['role']),
      depId: serializer.fromJson<int>(json['depId']),
      isOnline: serializer.fromJson<int>(json['isOnline']),
      draft: serializer.fromJson<String>(json['draft']),
      extra: serializer.fromJson<String>(json['extra']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'displayName': serializer.toJson<String>(displayName),
      'avatar': serializer.toJson<String>(avatar),
      'lastContent': serializer.toJson<String>(lastContent),
      'lastSendTime': serializer.toJson<int>(lastSendTime),
      'lastType': serializer.toJson<String>(lastType),
      'isGroup': serializer.toJson<int>(isGroup),
      'unread': serializer.toJson<int>(unread),
      'isAt': serializer.toJson<int>(isAt),
      'isTop': serializer.toJson<int>(isTop),
      'isNotice': serializer.toJson<int>(isNotice),
      'role': serializer.toJson<int>(role),
      'depId': serializer.toJson<int>(depId),
      'isOnline': serializer.toJson<int>(isOnline),
      'draft': serializer.toJson<String>(draft),
      'extra': serializer.toJson<String>(extra),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  DbConversation copyWith({
    String? id,
    String? displayName,
    String? avatar,
    String? lastContent,
    int? lastSendTime,
    String? lastType,
    int? isGroup,
    int? unread,
    int? isAt,
    int? isTop,
    int? isNotice,
    int? role,
    int? depId,
    int? isOnline,
    String? draft,
    String? extra,
    int? updatedAt,
  }) => DbConversation(
    id: id ?? this.id,
    displayName: displayName ?? this.displayName,
    avatar: avatar ?? this.avatar,
    lastContent: lastContent ?? this.lastContent,
    lastSendTime: lastSendTime ?? this.lastSendTime,
    lastType: lastType ?? this.lastType,
    isGroup: isGroup ?? this.isGroup,
    unread: unread ?? this.unread,
    isAt: isAt ?? this.isAt,
    isTop: isTop ?? this.isTop,
    isNotice: isNotice ?? this.isNotice,
    role: role ?? this.role,
    depId: depId ?? this.depId,
    isOnline: isOnline ?? this.isOnline,
    draft: draft ?? this.draft,
    extra: extra ?? this.extra,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  DbConversation copyWithCompanion(DbConversationsCompanion data) {
    return DbConversation(
      id: data.id.present ? data.id.value : this.id,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      avatar: data.avatar.present ? data.avatar.value : this.avatar,
      lastContent: data.lastContent.present
          ? data.lastContent.value
          : this.lastContent,
      lastSendTime: data.lastSendTime.present
          ? data.lastSendTime.value
          : this.lastSendTime,
      lastType: data.lastType.present ? data.lastType.value : this.lastType,
      isGroup: data.isGroup.present ? data.isGroup.value : this.isGroup,
      unread: data.unread.present ? data.unread.value : this.unread,
      isAt: data.isAt.present ? data.isAt.value : this.isAt,
      isTop: data.isTop.present ? data.isTop.value : this.isTop,
      isNotice: data.isNotice.present ? data.isNotice.value : this.isNotice,
      role: data.role.present ? data.role.value : this.role,
      depId: data.depId.present ? data.depId.value : this.depId,
      isOnline: data.isOnline.present ? data.isOnline.value : this.isOnline,
      draft: data.draft.present ? data.draft.value : this.draft,
      extra: data.extra.present ? data.extra.value : this.extra,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbConversation(')
          ..write('id: $id, ')
          ..write('displayName: $displayName, ')
          ..write('avatar: $avatar, ')
          ..write('lastContent: $lastContent, ')
          ..write('lastSendTime: $lastSendTime, ')
          ..write('lastType: $lastType, ')
          ..write('isGroup: $isGroup, ')
          ..write('unread: $unread, ')
          ..write('isAt: $isAt, ')
          ..write('isTop: $isTop, ')
          ..write('isNotice: $isNotice, ')
          ..write('role: $role, ')
          ..write('depId: $depId, ')
          ..write('isOnline: $isOnline, ')
          ..write('draft: $draft, ')
          ..write('extra: $extra, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    avatar,
    lastContent,
    lastSendTime,
    lastType,
    isGroup,
    unread,
    isAt,
    isTop,
    isNotice,
    role,
    depId,
    isOnline,
    draft,
    extra,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbConversation &&
          other.id == this.id &&
          other.displayName == this.displayName &&
          other.avatar == this.avatar &&
          other.lastContent == this.lastContent &&
          other.lastSendTime == this.lastSendTime &&
          other.lastType == this.lastType &&
          other.isGroup == this.isGroup &&
          other.unread == this.unread &&
          other.isAt == this.isAt &&
          other.isTop == this.isTop &&
          other.isNotice == this.isNotice &&
          other.role == this.role &&
          other.depId == this.depId &&
          other.isOnline == this.isOnline &&
          other.draft == this.draft &&
          other.extra == this.extra &&
          other.updatedAt == this.updatedAt);
}

class DbConversationsCompanion extends UpdateCompanion<DbConversation> {
  final Value<String> id;
  final Value<String> displayName;
  final Value<String> avatar;
  final Value<String> lastContent;
  final Value<int> lastSendTime;
  final Value<String> lastType;
  final Value<int> isGroup;
  final Value<int> unread;
  final Value<int> isAt;
  final Value<int> isTop;
  final Value<int> isNotice;
  final Value<int> role;
  final Value<int> depId;
  final Value<int> isOnline;
  final Value<String> draft;
  final Value<String> extra;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const DbConversationsCompanion({
    this.id = const Value.absent(),
    this.displayName = const Value.absent(),
    this.avatar = const Value.absent(),
    this.lastContent = const Value.absent(),
    this.lastSendTime = const Value.absent(),
    this.lastType = const Value.absent(),
    this.isGroup = const Value.absent(),
    this.unread = const Value.absent(),
    this.isAt = const Value.absent(),
    this.isTop = const Value.absent(),
    this.isNotice = const Value.absent(),
    this.role = const Value.absent(),
    this.depId = const Value.absent(),
    this.isOnline = const Value.absent(),
    this.draft = const Value.absent(),
    this.extra = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DbConversationsCompanion.insert({
    required String id,
    this.displayName = const Value.absent(),
    this.avatar = const Value.absent(),
    this.lastContent = const Value.absent(),
    this.lastSendTime = const Value.absent(),
    this.lastType = const Value.absent(),
    this.isGroup = const Value.absent(),
    this.unread = const Value.absent(),
    this.isAt = const Value.absent(),
    this.isTop = const Value.absent(),
    this.isNotice = const Value.absent(),
    this.role = const Value.absent(),
    this.depId = const Value.absent(),
    this.isOnline = const Value.absent(),
    this.draft = const Value.absent(),
    this.extra = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id);
  static Insertable<DbConversation> custom({
    Expression<String>? id,
    Expression<String>? displayName,
    Expression<String>? avatar,
    Expression<String>? lastContent,
    Expression<int>? lastSendTime,
    Expression<String>? lastType,
    Expression<int>? isGroup,
    Expression<int>? unread,
    Expression<int>? isAt,
    Expression<int>? isTop,
    Expression<int>? isNotice,
    Expression<int>? role,
    Expression<int>? depId,
    Expression<int>? isOnline,
    Expression<String>? draft,
    Expression<String>? extra,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (displayName != null) 'display_name': displayName,
      if (avatar != null) 'avatar': avatar,
      if (lastContent != null) 'last_content': lastContent,
      if (lastSendTime != null) 'last_send_time': lastSendTime,
      if (lastType != null) 'last_type': lastType,
      if (isGroup != null) 'is_group': isGroup,
      if (unread != null) 'unread': unread,
      if (isAt != null) 'is_at': isAt,
      if (isTop != null) 'is_top': isTop,
      if (isNotice != null) 'is_notice': isNotice,
      if (role != null) 'role': role,
      if (depId != null) 'dep_id': depId,
      if (isOnline != null) 'is_online': isOnline,
      if (draft != null) 'draft': draft,
      if (extra != null) 'extra': extra,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DbConversationsCompanion copyWith({
    Value<String>? id,
    Value<String>? displayName,
    Value<String>? avatar,
    Value<String>? lastContent,
    Value<int>? lastSendTime,
    Value<String>? lastType,
    Value<int>? isGroup,
    Value<int>? unread,
    Value<int>? isAt,
    Value<int>? isTop,
    Value<int>? isNotice,
    Value<int>? role,
    Value<int>? depId,
    Value<int>? isOnline,
    Value<String>? draft,
    Value<String>? extra,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return DbConversationsCompanion(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      avatar: avatar ?? this.avatar,
      lastContent: lastContent ?? this.lastContent,
      lastSendTime: lastSendTime ?? this.lastSendTime,
      lastType: lastType ?? this.lastType,
      isGroup: isGroup ?? this.isGroup,
      unread: unread ?? this.unread,
      isAt: isAt ?? this.isAt,
      isTop: isTop ?? this.isTop,
      isNotice: isNotice ?? this.isNotice,
      role: role ?? this.role,
      depId: depId ?? this.depId,
      isOnline: isOnline ?? this.isOnline,
      draft: draft ?? this.draft,
      extra: extra ?? this.extra,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (avatar.present) {
      map['avatar'] = Variable<String>(avatar.value);
    }
    if (lastContent.present) {
      map['last_content'] = Variable<String>(lastContent.value);
    }
    if (lastSendTime.present) {
      map['last_send_time'] = Variable<int>(lastSendTime.value);
    }
    if (lastType.present) {
      map['last_type'] = Variable<String>(lastType.value);
    }
    if (isGroup.present) {
      map['is_group'] = Variable<int>(isGroup.value);
    }
    if (unread.present) {
      map['unread'] = Variable<int>(unread.value);
    }
    if (isAt.present) {
      map['is_at'] = Variable<int>(isAt.value);
    }
    if (isTop.present) {
      map['is_top'] = Variable<int>(isTop.value);
    }
    if (isNotice.present) {
      map['is_notice'] = Variable<int>(isNotice.value);
    }
    if (role.present) {
      map['role'] = Variable<int>(role.value);
    }
    if (depId.present) {
      map['dep_id'] = Variable<int>(depId.value);
    }
    if (isOnline.present) {
      map['is_online'] = Variable<int>(isOnline.value);
    }
    if (draft.present) {
      map['draft'] = Variable<String>(draft.value);
    }
    if (extra.present) {
      map['extra'] = Variable<String>(extra.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DbConversationsCompanion(')
          ..write('id: $id, ')
          ..write('displayName: $displayName, ')
          ..write('avatar: $avatar, ')
          ..write('lastContent: $lastContent, ')
          ..write('lastSendTime: $lastSendTime, ')
          ..write('lastType: $lastType, ')
          ..write('isGroup: $isGroup, ')
          ..write('unread: $unread, ')
          ..write('isAt: $isAt, ')
          ..write('isTop: $isTop, ')
          ..write('isNotice: $isNotice, ')
          ..write('role: $role, ')
          ..write('depId: $depId, ')
          ..write('isOnline: $isOnline, ')
          ..write('draft: $draft, ')
          ..write('extra: $extra, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DbMessagesTable extends DbMessages
    with TableInfo<$DbMessagesTable, DbMessage> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DbMessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _localIdMeta = const VerificationMeta(
    'localId',
  );
  @override
  late final GeneratedColumn<int> localId = GeneratedColumn<int>(
    'local_id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<int> serverId = GeneratedColumn<int>(
    'server_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _msgIdMeta = const VerificationMeta('msgId');
  @override
  late final GeneratedColumn<String> msgId = GeneratedColumn<String>(
    'msg_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _clientIdMeta = const VerificationMeta(
    'clientId',
  );
  @override
  late final GeneratedColumn<String> clientId = GeneratedColumn<String>(
    'client_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('sent'),
  );
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fromUserIdMeta = const VerificationMeta(
    'fromUserId',
  );
  @override
  late final GeneratedColumn<String> fromUserId = GeneratedColumn<String>(
    'from_user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _fromUserNameMeta = const VerificationMeta(
    'fromUserName',
  );
  @override
  late final GeneratedColumn<String> fromUserName = GeneratedColumn<String>(
    'from_user_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _fromUserAvatarMeta = const VerificationMeta(
    'fromUserAvatar',
  );
  @override
  late final GeneratedColumn<String> fromUserAvatar = GeneratedColumn<String>(
    'from_user_avatar',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _toContactIdMeta = const VerificationMeta(
    'toContactId',
  );
  @override
  late final GeneratedColumn<String> toContactId = GeneratedColumn<String>(
    'to_contact_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _toUserMeta = const VerificationMeta('toUser');
  @override
  late final GeneratedColumn<String> toUser = GeneratedColumn<String>(
    'to_user',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('text'),
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _sendTimeMeta = const VerificationMeta(
    'sendTime',
  );
  @override
  late final GeneratedColumn<int> sendTime = GeneratedColumn<int>(
    'send_time',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _atUsersMeta = const VerificationMeta(
    'atUsers',
  );
  @override
  late final GeneratedColumn<String> atUsers = GeneratedColumn<String>(
    'at_users',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _extMeta = const VerificationMeta('ext');
  @override
  late final GeneratedColumn<String> ext = GeneratedColumn<String>(
    'ext',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  static const VerificationMeta _isGroupMeta = const VerificationMeta(
    'isGroup',
  );
  @override
  late final GeneratedColumn<int> isGroup = GeneratedColumn<int>(
    'is_group',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isReadMeta = const VerificationMeta('isRead');
  @override
  late final GeneratedColumn<int> isRead = GeneratedColumn<int>(
    'is_read',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isUndoMeta = const VerificationMeta('isUndo');
  @override
  late final GeneratedColumn<int> isUndo = GeneratedColumn<int>(
    'is_undo',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isMobileMeta = const VerificationMeta(
    'isMobile',
  );
  @override
  late final GeneratedColumn<int> isMobile = GeneratedColumn<int>(
    'is_mobile',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _extraMeta = const VerificationMeta('extra');
  @override
  late final GeneratedColumn<String> extra = GeneratedColumn<String>(
    'extra',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  @override
  List<GeneratedColumn> get $columns => [
    localId,
    serverId,
    msgId,
    clientId,
    status,
    conversationId,
    fromUserId,
    fromUserName,
    fromUserAvatar,
    toContactId,
    toUser,
    type,
    content,
    sendTime,
    atUsers,
    ext,
    isGroup,
    isRead,
    isUndo,
    isMobile,
    extra,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'db_messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbMessage> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('local_id')) {
      context.handle(
        _localIdMeta,
        localId.isAcceptableOrUnknown(data['local_id']!, _localIdMeta),
      );
    }
    if (data.containsKey('server_id')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['server_id']!, _serverIdMeta),
      );
    }
    if (data.containsKey('msg_id')) {
      context.handle(
        _msgIdMeta,
        msgId.isAcceptableOrUnknown(data['msg_id']!, _msgIdMeta),
      );
    }
    if (data.containsKey('client_id')) {
      context.handle(
        _clientIdMeta,
        clientId.isAcceptableOrUnknown(data['client_id']!, _clientIdMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('from_user_id')) {
      context.handle(
        _fromUserIdMeta,
        fromUserId.isAcceptableOrUnknown(
          data['from_user_id']!,
          _fromUserIdMeta,
        ),
      );
    }
    if (data.containsKey('from_user_name')) {
      context.handle(
        _fromUserNameMeta,
        fromUserName.isAcceptableOrUnknown(
          data['from_user_name']!,
          _fromUserNameMeta,
        ),
      );
    }
    if (data.containsKey('from_user_avatar')) {
      context.handle(
        _fromUserAvatarMeta,
        fromUserAvatar.isAcceptableOrUnknown(
          data['from_user_avatar']!,
          _fromUserAvatarMeta,
        ),
      );
    }
    if (data.containsKey('to_contact_id')) {
      context.handle(
        _toContactIdMeta,
        toContactId.isAcceptableOrUnknown(
          data['to_contact_id']!,
          _toContactIdMeta,
        ),
      );
    }
    if (data.containsKey('to_user')) {
      context.handle(
        _toUserMeta,
        toUser.isAcceptableOrUnknown(data['to_user']!, _toUserMeta),
      );
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    }
    if (data.containsKey('send_time')) {
      context.handle(
        _sendTimeMeta,
        sendTime.isAcceptableOrUnknown(data['send_time']!, _sendTimeMeta),
      );
    }
    if (data.containsKey('at_users')) {
      context.handle(
        _atUsersMeta,
        atUsers.isAcceptableOrUnknown(data['at_users']!, _atUsersMeta),
      );
    }
    if (data.containsKey('ext')) {
      context.handle(
        _extMeta,
        ext.isAcceptableOrUnknown(data['ext']!, _extMeta),
      );
    }
    if (data.containsKey('is_group')) {
      context.handle(
        _isGroupMeta,
        isGroup.isAcceptableOrUnknown(data['is_group']!, _isGroupMeta),
      );
    }
    if (data.containsKey('is_read')) {
      context.handle(
        _isReadMeta,
        isRead.isAcceptableOrUnknown(data['is_read']!, _isReadMeta),
      );
    }
    if (data.containsKey('is_undo')) {
      context.handle(
        _isUndoMeta,
        isUndo.isAcceptableOrUnknown(data['is_undo']!, _isUndoMeta),
      );
    }
    if (data.containsKey('is_mobile')) {
      context.handle(
        _isMobileMeta,
        isMobile.isAcceptableOrUnknown(data['is_mobile']!, _isMobileMeta),
      );
    }
    if (data.containsKey('extra')) {
      context.handle(
        _extraMeta,
        extra.isAcceptableOrUnknown(data['extra']!, _extraMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {localId};
  @override
  DbMessage map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbMessage(
      localId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}local_id'],
      )!,
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}server_id'],
      ),
      msgId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}msg_id'],
      ),
      clientId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}client_id'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      fromUserId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}from_user_id'],
      )!,
      fromUserName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}from_user_name'],
      )!,
      fromUserAvatar: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}from_user_avatar'],
      )!,
      toContactId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}to_contact_id'],
      )!,
      toUser: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}to_user'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      sendTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}send_time'],
      )!,
      atUsers: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}at_users'],
      )!,
      ext: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ext'],
      )!,
      isGroup: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_group'],
      )!,
      isRead: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_read'],
      )!,
      isUndo: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_undo'],
      )!,
      isMobile: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_mobile'],
      )!,
      extra: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}extra'],
      )!,
    );
  }

  @override
  $DbMessagesTable createAlias(String alias) {
    return $DbMessagesTable(attachedDatabase, alias);
  }
}

class DbMessage extends DataClass implements Insertable<DbMessage> {
  final int localId;

  /// 服务端消息主键（老端到处用的 `item.id`，通话信令里作为 `main_id`）
  final int? serverId;

  /// 业务消息 id（客户端生成的 uuid；老端用它做去重）
  final String? msgId;

  /// 本机生成的消息 id（老端 `$util.getUuid()`，发出去时放在 `id` 字段里）。
  ///
  /// 与 [msgId] 分开存的原因：服务端到底把哪个字段回传给我们还没实测过
  /// （老端把 uuid 写在 `id` 上，又用 `id` 匹配接口返回）。发出去的乐观消息
  /// 用这个字段认领"服务端回显的同一条消息"，避免出现两条一样的。
  final String? clientId;

  /// 发送状态：`sent`（默认）/ `going`（发出去等回执）/ `failed`（失败可重发）
  ///
  /// 老端把状态放在内存里的 `message.status`，退出聊天页就没了；落库之后
  /// 重进聊天页仍然能看到"发送失败"并点重发。
  final String status;

  /// 归属会话（与 [DbConversations.id] 一致）
  final String conversationId;
  final String fromUserId;
  final String fromUserName;
  final String fromUserAvatar;

  /// 消息体里的 `toContactId`（自己发的时候是对方 id）
  final String toContactId;

  /// 消息体里的 `toUser`
  final String toUser;
  final String type;
  final String content;

  /// 消息时间，**毫秒**（服务端可能给秒，入库前统一归一化）
  final int sendTime;

  /// 被 @ 的 user_id 列表（JSON 数组）
  final String atUsers;

  /// 老端 `extends`（JSON）：图片尺寸、语音时长、通话 event/code 都在这里
  final String ext;
  final int isGroup;

  /// 本地是否已读（用于进聊天页时判断要不要上报已读）
  final int isRead;

  /// 是否已撤回（老端 `is_undo`）
  final int isUndo;

  /// 是否本机发出（老端 `extends.isMobile == 1`）：多端同步时用来避免重复处理
  final int isMobile;

  /// 服务端给的其它字段（JSON）
  final String extra;
  const DbMessage({
    required this.localId,
    this.serverId,
    this.msgId,
    this.clientId,
    required this.status,
    required this.conversationId,
    required this.fromUserId,
    required this.fromUserName,
    required this.fromUserAvatar,
    required this.toContactId,
    required this.toUser,
    required this.type,
    required this.content,
    required this.sendTime,
    required this.atUsers,
    required this.ext,
    required this.isGroup,
    required this.isRead,
    required this.isUndo,
    required this.isMobile,
    required this.extra,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['local_id'] = Variable<int>(localId);
    if (!nullToAbsent || serverId != null) {
      map['server_id'] = Variable<int>(serverId);
    }
    if (!nullToAbsent || msgId != null) {
      map['msg_id'] = Variable<String>(msgId);
    }
    if (!nullToAbsent || clientId != null) {
      map['client_id'] = Variable<String>(clientId);
    }
    map['status'] = Variable<String>(status);
    map['conversation_id'] = Variable<String>(conversationId);
    map['from_user_id'] = Variable<String>(fromUserId);
    map['from_user_name'] = Variable<String>(fromUserName);
    map['from_user_avatar'] = Variable<String>(fromUserAvatar);
    map['to_contact_id'] = Variable<String>(toContactId);
    map['to_user'] = Variable<String>(toUser);
    map['type'] = Variable<String>(type);
    map['content'] = Variable<String>(content);
    map['send_time'] = Variable<int>(sendTime);
    map['at_users'] = Variable<String>(atUsers);
    map['ext'] = Variable<String>(ext);
    map['is_group'] = Variable<int>(isGroup);
    map['is_read'] = Variable<int>(isRead);
    map['is_undo'] = Variable<int>(isUndo);
    map['is_mobile'] = Variable<int>(isMobile);
    map['extra'] = Variable<String>(extra);
    return map;
  }

  DbMessagesCompanion toCompanion(bool nullToAbsent) {
    return DbMessagesCompanion(
      localId: Value(localId),
      serverId: serverId == null && nullToAbsent
          ? const Value.absent()
          : Value(serverId),
      msgId: msgId == null && nullToAbsent
          ? const Value.absent()
          : Value(msgId),
      clientId: clientId == null && nullToAbsent
          ? const Value.absent()
          : Value(clientId),
      status: Value(status),
      conversationId: Value(conversationId),
      fromUserId: Value(fromUserId),
      fromUserName: Value(fromUserName),
      fromUserAvatar: Value(fromUserAvatar),
      toContactId: Value(toContactId),
      toUser: Value(toUser),
      type: Value(type),
      content: Value(content),
      sendTime: Value(sendTime),
      atUsers: Value(atUsers),
      ext: Value(ext),
      isGroup: Value(isGroup),
      isRead: Value(isRead),
      isUndo: Value(isUndo),
      isMobile: Value(isMobile),
      extra: Value(extra),
    );
  }

  factory DbMessage.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbMessage(
      localId: serializer.fromJson<int>(json['localId']),
      serverId: serializer.fromJson<int?>(json['serverId']),
      msgId: serializer.fromJson<String?>(json['msgId']),
      clientId: serializer.fromJson<String?>(json['clientId']),
      status: serializer.fromJson<String>(json['status']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      fromUserId: serializer.fromJson<String>(json['fromUserId']),
      fromUserName: serializer.fromJson<String>(json['fromUserName']),
      fromUserAvatar: serializer.fromJson<String>(json['fromUserAvatar']),
      toContactId: serializer.fromJson<String>(json['toContactId']),
      toUser: serializer.fromJson<String>(json['toUser']),
      type: serializer.fromJson<String>(json['type']),
      content: serializer.fromJson<String>(json['content']),
      sendTime: serializer.fromJson<int>(json['sendTime']),
      atUsers: serializer.fromJson<String>(json['atUsers']),
      ext: serializer.fromJson<String>(json['ext']),
      isGroup: serializer.fromJson<int>(json['isGroup']),
      isRead: serializer.fromJson<int>(json['isRead']),
      isUndo: serializer.fromJson<int>(json['isUndo']),
      isMobile: serializer.fromJson<int>(json['isMobile']),
      extra: serializer.fromJson<String>(json['extra']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'localId': serializer.toJson<int>(localId),
      'serverId': serializer.toJson<int?>(serverId),
      'msgId': serializer.toJson<String?>(msgId),
      'clientId': serializer.toJson<String?>(clientId),
      'status': serializer.toJson<String>(status),
      'conversationId': serializer.toJson<String>(conversationId),
      'fromUserId': serializer.toJson<String>(fromUserId),
      'fromUserName': serializer.toJson<String>(fromUserName),
      'fromUserAvatar': serializer.toJson<String>(fromUserAvatar),
      'toContactId': serializer.toJson<String>(toContactId),
      'toUser': serializer.toJson<String>(toUser),
      'type': serializer.toJson<String>(type),
      'content': serializer.toJson<String>(content),
      'sendTime': serializer.toJson<int>(sendTime),
      'atUsers': serializer.toJson<String>(atUsers),
      'ext': serializer.toJson<String>(ext),
      'isGroup': serializer.toJson<int>(isGroup),
      'isRead': serializer.toJson<int>(isRead),
      'isUndo': serializer.toJson<int>(isUndo),
      'isMobile': serializer.toJson<int>(isMobile),
      'extra': serializer.toJson<String>(extra),
    };
  }

  DbMessage copyWith({
    int? localId,
    Value<int?> serverId = const Value.absent(),
    Value<String?> msgId = const Value.absent(),
    Value<String?> clientId = const Value.absent(),
    String? status,
    String? conversationId,
    String? fromUserId,
    String? fromUserName,
    String? fromUserAvatar,
    String? toContactId,
    String? toUser,
    String? type,
    String? content,
    int? sendTime,
    String? atUsers,
    String? ext,
    int? isGroup,
    int? isRead,
    int? isUndo,
    int? isMobile,
    String? extra,
  }) => DbMessage(
    localId: localId ?? this.localId,
    serverId: serverId.present ? serverId.value : this.serverId,
    msgId: msgId.present ? msgId.value : this.msgId,
    clientId: clientId.present ? clientId.value : this.clientId,
    status: status ?? this.status,
    conversationId: conversationId ?? this.conversationId,
    fromUserId: fromUserId ?? this.fromUserId,
    fromUserName: fromUserName ?? this.fromUserName,
    fromUserAvatar: fromUserAvatar ?? this.fromUserAvatar,
    toContactId: toContactId ?? this.toContactId,
    toUser: toUser ?? this.toUser,
    type: type ?? this.type,
    content: content ?? this.content,
    sendTime: sendTime ?? this.sendTime,
    atUsers: atUsers ?? this.atUsers,
    ext: ext ?? this.ext,
    isGroup: isGroup ?? this.isGroup,
    isRead: isRead ?? this.isRead,
    isUndo: isUndo ?? this.isUndo,
    isMobile: isMobile ?? this.isMobile,
    extra: extra ?? this.extra,
  );
  DbMessage copyWithCompanion(DbMessagesCompanion data) {
    return DbMessage(
      localId: data.localId.present ? data.localId.value : this.localId,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
      msgId: data.msgId.present ? data.msgId.value : this.msgId,
      clientId: data.clientId.present ? data.clientId.value : this.clientId,
      status: data.status.present ? data.status.value : this.status,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      fromUserId: data.fromUserId.present
          ? data.fromUserId.value
          : this.fromUserId,
      fromUserName: data.fromUserName.present
          ? data.fromUserName.value
          : this.fromUserName,
      fromUserAvatar: data.fromUserAvatar.present
          ? data.fromUserAvatar.value
          : this.fromUserAvatar,
      toContactId: data.toContactId.present
          ? data.toContactId.value
          : this.toContactId,
      toUser: data.toUser.present ? data.toUser.value : this.toUser,
      type: data.type.present ? data.type.value : this.type,
      content: data.content.present ? data.content.value : this.content,
      sendTime: data.sendTime.present ? data.sendTime.value : this.sendTime,
      atUsers: data.atUsers.present ? data.atUsers.value : this.atUsers,
      ext: data.ext.present ? data.ext.value : this.ext,
      isGroup: data.isGroup.present ? data.isGroup.value : this.isGroup,
      isRead: data.isRead.present ? data.isRead.value : this.isRead,
      isUndo: data.isUndo.present ? data.isUndo.value : this.isUndo,
      isMobile: data.isMobile.present ? data.isMobile.value : this.isMobile,
      extra: data.extra.present ? data.extra.value : this.extra,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbMessage(')
          ..write('localId: $localId, ')
          ..write('serverId: $serverId, ')
          ..write('msgId: $msgId, ')
          ..write('clientId: $clientId, ')
          ..write('status: $status, ')
          ..write('conversationId: $conversationId, ')
          ..write('fromUserId: $fromUserId, ')
          ..write('fromUserName: $fromUserName, ')
          ..write('fromUserAvatar: $fromUserAvatar, ')
          ..write('toContactId: $toContactId, ')
          ..write('toUser: $toUser, ')
          ..write('type: $type, ')
          ..write('content: $content, ')
          ..write('sendTime: $sendTime, ')
          ..write('atUsers: $atUsers, ')
          ..write('ext: $ext, ')
          ..write('isGroup: $isGroup, ')
          ..write('isRead: $isRead, ')
          ..write('isUndo: $isUndo, ')
          ..write('isMobile: $isMobile, ')
          ..write('extra: $extra')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    localId,
    serverId,
    msgId,
    clientId,
    status,
    conversationId,
    fromUserId,
    fromUserName,
    fromUserAvatar,
    toContactId,
    toUser,
    type,
    content,
    sendTime,
    atUsers,
    ext,
    isGroup,
    isRead,
    isUndo,
    isMobile,
    extra,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbMessage &&
          other.localId == this.localId &&
          other.serverId == this.serverId &&
          other.msgId == this.msgId &&
          other.clientId == this.clientId &&
          other.status == this.status &&
          other.conversationId == this.conversationId &&
          other.fromUserId == this.fromUserId &&
          other.fromUserName == this.fromUserName &&
          other.fromUserAvatar == this.fromUserAvatar &&
          other.toContactId == this.toContactId &&
          other.toUser == this.toUser &&
          other.type == this.type &&
          other.content == this.content &&
          other.sendTime == this.sendTime &&
          other.atUsers == this.atUsers &&
          other.ext == this.ext &&
          other.isGroup == this.isGroup &&
          other.isRead == this.isRead &&
          other.isUndo == this.isUndo &&
          other.isMobile == this.isMobile &&
          other.extra == this.extra);
}

class DbMessagesCompanion extends UpdateCompanion<DbMessage> {
  final Value<int> localId;
  final Value<int?> serverId;
  final Value<String?> msgId;
  final Value<String?> clientId;
  final Value<String> status;
  final Value<String> conversationId;
  final Value<String> fromUserId;
  final Value<String> fromUserName;
  final Value<String> fromUserAvatar;
  final Value<String> toContactId;
  final Value<String> toUser;
  final Value<String> type;
  final Value<String> content;
  final Value<int> sendTime;
  final Value<String> atUsers;
  final Value<String> ext;
  final Value<int> isGroup;
  final Value<int> isRead;
  final Value<int> isUndo;
  final Value<int> isMobile;
  final Value<String> extra;
  const DbMessagesCompanion({
    this.localId = const Value.absent(),
    this.serverId = const Value.absent(),
    this.msgId = const Value.absent(),
    this.clientId = const Value.absent(),
    this.status = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.fromUserId = const Value.absent(),
    this.fromUserName = const Value.absent(),
    this.fromUserAvatar = const Value.absent(),
    this.toContactId = const Value.absent(),
    this.toUser = const Value.absent(),
    this.type = const Value.absent(),
    this.content = const Value.absent(),
    this.sendTime = const Value.absent(),
    this.atUsers = const Value.absent(),
    this.ext = const Value.absent(),
    this.isGroup = const Value.absent(),
    this.isRead = const Value.absent(),
    this.isUndo = const Value.absent(),
    this.isMobile = const Value.absent(),
    this.extra = const Value.absent(),
  });
  DbMessagesCompanion.insert({
    this.localId = const Value.absent(),
    this.serverId = const Value.absent(),
    this.msgId = const Value.absent(),
    this.clientId = const Value.absent(),
    this.status = const Value.absent(),
    required String conversationId,
    this.fromUserId = const Value.absent(),
    this.fromUserName = const Value.absent(),
    this.fromUserAvatar = const Value.absent(),
    this.toContactId = const Value.absent(),
    this.toUser = const Value.absent(),
    this.type = const Value.absent(),
    this.content = const Value.absent(),
    this.sendTime = const Value.absent(),
    this.atUsers = const Value.absent(),
    this.ext = const Value.absent(),
    this.isGroup = const Value.absent(),
    this.isRead = const Value.absent(),
    this.isUndo = const Value.absent(),
    this.isMobile = const Value.absent(),
    this.extra = const Value.absent(),
  }) : conversationId = Value(conversationId);
  static Insertable<DbMessage> custom({
    Expression<int>? localId,
    Expression<int>? serverId,
    Expression<String>? msgId,
    Expression<String>? clientId,
    Expression<String>? status,
    Expression<String>? conversationId,
    Expression<String>? fromUserId,
    Expression<String>? fromUserName,
    Expression<String>? fromUserAvatar,
    Expression<String>? toContactId,
    Expression<String>? toUser,
    Expression<String>? type,
    Expression<String>? content,
    Expression<int>? sendTime,
    Expression<String>? atUsers,
    Expression<String>? ext,
    Expression<int>? isGroup,
    Expression<int>? isRead,
    Expression<int>? isUndo,
    Expression<int>? isMobile,
    Expression<String>? extra,
  }) {
    return RawValuesInsertable({
      if (localId != null) 'local_id': localId,
      if (serverId != null) 'server_id': serverId,
      if (msgId != null) 'msg_id': msgId,
      if (clientId != null) 'client_id': clientId,
      if (status != null) 'status': status,
      if (conversationId != null) 'conversation_id': conversationId,
      if (fromUserId != null) 'from_user_id': fromUserId,
      if (fromUserName != null) 'from_user_name': fromUserName,
      if (fromUserAvatar != null) 'from_user_avatar': fromUserAvatar,
      if (toContactId != null) 'to_contact_id': toContactId,
      if (toUser != null) 'to_user': toUser,
      if (type != null) 'type': type,
      if (content != null) 'content': content,
      if (sendTime != null) 'send_time': sendTime,
      if (atUsers != null) 'at_users': atUsers,
      if (ext != null) 'ext': ext,
      if (isGroup != null) 'is_group': isGroup,
      if (isRead != null) 'is_read': isRead,
      if (isUndo != null) 'is_undo': isUndo,
      if (isMobile != null) 'is_mobile': isMobile,
      if (extra != null) 'extra': extra,
    });
  }

  DbMessagesCompanion copyWith({
    Value<int>? localId,
    Value<int?>? serverId,
    Value<String?>? msgId,
    Value<String?>? clientId,
    Value<String>? status,
    Value<String>? conversationId,
    Value<String>? fromUserId,
    Value<String>? fromUserName,
    Value<String>? fromUserAvatar,
    Value<String>? toContactId,
    Value<String>? toUser,
    Value<String>? type,
    Value<String>? content,
    Value<int>? sendTime,
    Value<String>? atUsers,
    Value<String>? ext,
    Value<int>? isGroup,
    Value<int>? isRead,
    Value<int>? isUndo,
    Value<int>? isMobile,
    Value<String>? extra,
  }) {
    return DbMessagesCompanion(
      localId: localId ?? this.localId,
      serverId: serverId ?? this.serverId,
      msgId: msgId ?? this.msgId,
      clientId: clientId ?? this.clientId,
      status: status ?? this.status,
      conversationId: conversationId ?? this.conversationId,
      fromUserId: fromUserId ?? this.fromUserId,
      fromUserName: fromUserName ?? this.fromUserName,
      fromUserAvatar: fromUserAvatar ?? this.fromUserAvatar,
      toContactId: toContactId ?? this.toContactId,
      toUser: toUser ?? this.toUser,
      type: type ?? this.type,
      content: content ?? this.content,
      sendTime: sendTime ?? this.sendTime,
      atUsers: atUsers ?? this.atUsers,
      ext: ext ?? this.ext,
      isGroup: isGroup ?? this.isGroup,
      isRead: isRead ?? this.isRead,
      isUndo: isUndo ?? this.isUndo,
      isMobile: isMobile ?? this.isMobile,
      extra: extra ?? this.extra,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (localId.present) {
      map['local_id'] = Variable<int>(localId.value);
    }
    if (serverId.present) {
      map['server_id'] = Variable<int>(serverId.value);
    }
    if (msgId.present) {
      map['msg_id'] = Variable<String>(msgId.value);
    }
    if (clientId.present) {
      map['client_id'] = Variable<String>(clientId.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (fromUserId.present) {
      map['from_user_id'] = Variable<String>(fromUserId.value);
    }
    if (fromUserName.present) {
      map['from_user_name'] = Variable<String>(fromUserName.value);
    }
    if (fromUserAvatar.present) {
      map['from_user_avatar'] = Variable<String>(fromUserAvatar.value);
    }
    if (toContactId.present) {
      map['to_contact_id'] = Variable<String>(toContactId.value);
    }
    if (toUser.present) {
      map['to_user'] = Variable<String>(toUser.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (sendTime.present) {
      map['send_time'] = Variable<int>(sendTime.value);
    }
    if (atUsers.present) {
      map['at_users'] = Variable<String>(atUsers.value);
    }
    if (ext.present) {
      map['ext'] = Variable<String>(ext.value);
    }
    if (isGroup.present) {
      map['is_group'] = Variable<int>(isGroup.value);
    }
    if (isRead.present) {
      map['is_read'] = Variable<int>(isRead.value);
    }
    if (isUndo.present) {
      map['is_undo'] = Variable<int>(isUndo.value);
    }
    if (isMobile.present) {
      map['is_mobile'] = Variable<int>(isMobile.value);
    }
    if (extra.present) {
      map['extra'] = Variable<String>(extra.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DbMessagesCompanion(')
          ..write('localId: $localId, ')
          ..write('serverId: $serverId, ')
          ..write('msgId: $msgId, ')
          ..write('clientId: $clientId, ')
          ..write('status: $status, ')
          ..write('conversationId: $conversationId, ')
          ..write('fromUserId: $fromUserId, ')
          ..write('fromUserName: $fromUserName, ')
          ..write('fromUserAvatar: $fromUserAvatar, ')
          ..write('toContactId: $toContactId, ')
          ..write('toUser: $toUser, ')
          ..write('type: $type, ')
          ..write('content: $content, ')
          ..write('sendTime: $sendTime, ')
          ..write('atUsers: $atUsers, ')
          ..write('ext: $ext, ')
          ..write('isGroup: $isGroup, ')
          ..write('isRead: $isRead, ')
          ..write('isUndo: $isUndo, ')
          ..write('isMobile: $isMobile, ')
          ..write('extra: $extra')
          ..write(')'))
        .toString();
  }
}

class $DbContactsTable extends DbContacts
    with TableInfo<$DbContactsTable, DbContact> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DbContactsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _realNameMeta = const VerificationMeta(
    'realName',
  );
  @override
  late final GeneratedColumn<String> realName = GeneratedColumn<String>(
    'real_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _avatarMeta = const VerificationMeta('avatar');
  @override
  late final GeneratedColumn<String> avatar = GeneratedColumn<String>(
    'avatar',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _isGroupMeta = const VerificationMeta(
    'isGroup',
  );
  @override
  late final GeneratedColumn<int> isGroup = GeneratedColumn<int>(
    'is_group',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _indexLetterMeta = const VerificationMeta(
    'indexLetter',
  );
  @override
  late final GeneratedColumn<String> indexLetter = GeneratedColumn<String>(
    'index_letter',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _namePyMeta = const VerificationMeta('namePy');
  @override
  late final GeneratedColumn<String> namePy = GeneratedColumn<String>(
    'name_py',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _accountMeta = const VerificationMeta(
    'account',
  );
  @override
  late final GeneratedColumn<String> account = GeneratedColumn<String>(
    'account',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _isOnlineMeta = const VerificationMeta(
    'isOnline',
  );
  @override
  late final GeneratedColumn<int> isOnline = GeneratedColumn<int>(
    'is_online',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<int> role = GeneratedColumn<int>(
    'role',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _ownerIdMeta = const VerificationMeta(
    'ownerId',
  );
  @override
  late final GeneratedColumn<String> ownerId = GeneratedColumn<String>(
    'owner_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _extraMeta = const VerificationMeta('extra');
  @override
  late final GeneratedColumn<String> extra = GeneratedColumn<String>(
    'extra',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    displayName,
    realName,
    avatar,
    isGroup,
    indexLetter,
    namePy,
    account,
    isOnline,
    role,
    ownerId,
    extra,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'db_contacts';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbContact> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    }
    if (data.containsKey('real_name')) {
      context.handle(
        _realNameMeta,
        realName.isAcceptableOrUnknown(data['real_name']!, _realNameMeta),
      );
    }
    if (data.containsKey('avatar')) {
      context.handle(
        _avatarMeta,
        avatar.isAcceptableOrUnknown(data['avatar']!, _avatarMeta),
      );
    }
    if (data.containsKey('is_group')) {
      context.handle(
        _isGroupMeta,
        isGroup.isAcceptableOrUnknown(data['is_group']!, _isGroupMeta),
      );
    }
    if (data.containsKey('index_letter')) {
      context.handle(
        _indexLetterMeta,
        indexLetter.isAcceptableOrUnknown(
          data['index_letter']!,
          _indexLetterMeta,
        ),
      );
    }
    if (data.containsKey('name_py')) {
      context.handle(
        _namePyMeta,
        namePy.isAcceptableOrUnknown(data['name_py']!, _namePyMeta),
      );
    }
    if (data.containsKey('account')) {
      context.handle(
        _accountMeta,
        account.isAcceptableOrUnknown(data['account']!, _accountMeta),
      );
    }
    if (data.containsKey('is_online')) {
      context.handle(
        _isOnlineMeta,
        isOnline.isAcceptableOrUnknown(data['is_online']!, _isOnlineMeta),
      );
    }
    if (data.containsKey('role')) {
      context.handle(
        _roleMeta,
        role.isAcceptableOrUnknown(data['role']!, _roleMeta),
      );
    }
    if (data.containsKey('owner_id')) {
      context.handle(
        _ownerIdMeta,
        ownerId.isAcceptableOrUnknown(data['owner_id']!, _ownerIdMeta),
      );
    }
    if (data.containsKey('extra')) {
      context.handle(
        _extraMeta,
        extra.isAcceptableOrUnknown(data['extra']!, _extraMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbContact map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbContact(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      realName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}real_name'],
      )!,
      avatar: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}avatar'],
      )!,
      isGroup: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_group'],
      )!,
      indexLetter: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}index_letter'],
      )!,
      namePy: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name_py'],
      )!,
      account: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account'],
      )!,
      isOnline: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_online'],
      )!,
      role: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}role'],
      )!,
      ownerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner_id'],
      )!,
      extra: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}extra'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $DbContactsTable createAlias(String alias) {
    return $DbContactsTable(attachedDatabase, alias);
  }
}

class DbContact extends DataClass implements Insertable<DbContact> {
  /// 好友是 `user_id`，群聊是 `group_id`，系统通知是 `system`
  final String id;

  /// 界面显示名。老端好友列表里直接用服务端的 `displayName`
  /// （设置备注后服务端会把这个字段换成备注名），所以列名保持一致。
  final String displayName;

  /// 真实姓名（老端 `realname`：用户详情、搜索页都用它）
  final String realName;
  final String avatar;

  /// 0 好友、1 群聊、2 系统通知
  final int isGroup;

  /// 服务端给的拼音首字母（老端 `item.index`，通讯录分组直接用它）
  final String indexLetter;

  /// 名字全拼（老端 `name_py`，搜索与索引兜底用）
  final String namePy;

  /// 账号（群聊列表页的搜索条件里有它）
  final String account;

  /// 在线状态（WS `isOnline`）
  final int isOnline;

  /// 群内角色（群主 1 / 管理员 2 / 成员 3，群聊列表页据此筛选）
  final int role;

  /// 群主 id（老端群聊列表里给群主画个小人图标）
  final String ownerId;

  /// 服务端给的其它字段（JSON）
  final String extra;

  /// 本地更新时间（毫秒）
  final int updatedAt;
  const DbContact({
    required this.id,
    required this.displayName,
    required this.realName,
    required this.avatar,
    required this.isGroup,
    required this.indexLetter,
    required this.namePy,
    required this.account,
    required this.isOnline,
    required this.role,
    required this.ownerId,
    required this.extra,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['display_name'] = Variable<String>(displayName);
    map['real_name'] = Variable<String>(realName);
    map['avatar'] = Variable<String>(avatar);
    map['is_group'] = Variable<int>(isGroup);
    map['index_letter'] = Variable<String>(indexLetter);
    map['name_py'] = Variable<String>(namePy);
    map['account'] = Variable<String>(account);
    map['is_online'] = Variable<int>(isOnline);
    map['role'] = Variable<int>(role);
    map['owner_id'] = Variable<String>(ownerId);
    map['extra'] = Variable<String>(extra);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  DbContactsCompanion toCompanion(bool nullToAbsent) {
    return DbContactsCompanion(
      id: Value(id),
      displayName: Value(displayName),
      realName: Value(realName),
      avatar: Value(avatar),
      isGroup: Value(isGroup),
      indexLetter: Value(indexLetter),
      namePy: Value(namePy),
      account: Value(account),
      isOnline: Value(isOnline),
      role: Value(role),
      ownerId: Value(ownerId),
      extra: Value(extra),
      updatedAt: Value(updatedAt),
    );
  }

  factory DbContact.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbContact(
      id: serializer.fromJson<String>(json['id']),
      displayName: serializer.fromJson<String>(json['displayName']),
      realName: serializer.fromJson<String>(json['realName']),
      avatar: serializer.fromJson<String>(json['avatar']),
      isGroup: serializer.fromJson<int>(json['isGroup']),
      indexLetter: serializer.fromJson<String>(json['indexLetter']),
      namePy: serializer.fromJson<String>(json['namePy']),
      account: serializer.fromJson<String>(json['account']),
      isOnline: serializer.fromJson<int>(json['isOnline']),
      role: serializer.fromJson<int>(json['role']),
      ownerId: serializer.fromJson<String>(json['ownerId']),
      extra: serializer.fromJson<String>(json['extra']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'displayName': serializer.toJson<String>(displayName),
      'realName': serializer.toJson<String>(realName),
      'avatar': serializer.toJson<String>(avatar),
      'isGroup': serializer.toJson<int>(isGroup),
      'indexLetter': serializer.toJson<String>(indexLetter),
      'namePy': serializer.toJson<String>(namePy),
      'account': serializer.toJson<String>(account),
      'isOnline': serializer.toJson<int>(isOnline),
      'role': serializer.toJson<int>(role),
      'ownerId': serializer.toJson<String>(ownerId),
      'extra': serializer.toJson<String>(extra),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  DbContact copyWith({
    String? id,
    String? displayName,
    String? realName,
    String? avatar,
    int? isGroup,
    String? indexLetter,
    String? namePy,
    String? account,
    int? isOnline,
    int? role,
    String? ownerId,
    String? extra,
    int? updatedAt,
  }) => DbContact(
    id: id ?? this.id,
    displayName: displayName ?? this.displayName,
    realName: realName ?? this.realName,
    avatar: avatar ?? this.avatar,
    isGroup: isGroup ?? this.isGroup,
    indexLetter: indexLetter ?? this.indexLetter,
    namePy: namePy ?? this.namePy,
    account: account ?? this.account,
    isOnline: isOnline ?? this.isOnline,
    role: role ?? this.role,
    ownerId: ownerId ?? this.ownerId,
    extra: extra ?? this.extra,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  DbContact copyWithCompanion(DbContactsCompanion data) {
    return DbContact(
      id: data.id.present ? data.id.value : this.id,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      realName: data.realName.present ? data.realName.value : this.realName,
      avatar: data.avatar.present ? data.avatar.value : this.avatar,
      isGroup: data.isGroup.present ? data.isGroup.value : this.isGroup,
      indexLetter: data.indexLetter.present
          ? data.indexLetter.value
          : this.indexLetter,
      namePy: data.namePy.present ? data.namePy.value : this.namePy,
      account: data.account.present ? data.account.value : this.account,
      isOnline: data.isOnline.present ? data.isOnline.value : this.isOnline,
      role: data.role.present ? data.role.value : this.role,
      ownerId: data.ownerId.present ? data.ownerId.value : this.ownerId,
      extra: data.extra.present ? data.extra.value : this.extra,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbContact(')
          ..write('id: $id, ')
          ..write('displayName: $displayName, ')
          ..write('realName: $realName, ')
          ..write('avatar: $avatar, ')
          ..write('isGroup: $isGroup, ')
          ..write('indexLetter: $indexLetter, ')
          ..write('namePy: $namePy, ')
          ..write('account: $account, ')
          ..write('isOnline: $isOnline, ')
          ..write('role: $role, ')
          ..write('ownerId: $ownerId, ')
          ..write('extra: $extra, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    realName,
    avatar,
    isGroup,
    indexLetter,
    namePy,
    account,
    isOnline,
    role,
    ownerId,
    extra,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbContact &&
          other.id == this.id &&
          other.displayName == this.displayName &&
          other.realName == this.realName &&
          other.avatar == this.avatar &&
          other.isGroup == this.isGroup &&
          other.indexLetter == this.indexLetter &&
          other.namePy == this.namePy &&
          other.account == this.account &&
          other.isOnline == this.isOnline &&
          other.role == this.role &&
          other.ownerId == this.ownerId &&
          other.extra == this.extra &&
          other.updatedAt == this.updatedAt);
}

class DbContactsCompanion extends UpdateCompanion<DbContact> {
  final Value<String> id;
  final Value<String> displayName;
  final Value<String> realName;
  final Value<String> avatar;
  final Value<int> isGroup;
  final Value<String> indexLetter;
  final Value<String> namePy;
  final Value<String> account;
  final Value<int> isOnline;
  final Value<int> role;
  final Value<String> ownerId;
  final Value<String> extra;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const DbContactsCompanion({
    this.id = const Value.absent(),
    this.displayName = const Value.absent(),
    this.realName = const Value.absent(),
    this.avatar = const Value.absent(),
    this.isGroup = const Value.absent(),
    this.indexLetter = const Value.absent(),
    this.namePy = const Value.absent(),
    this.account = const Value.absent(),
    this.isOnline = const Value.absent(),
    this.role = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.extra = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DbContactsCompanion.insert({
    required String id,
    this.displayName = const Value.absent(),
    this.realName = const Value.absent(),
    this.avatar = const Value.absent(),
    this.isGroup = const Value.absent(),
    this.indexLetter = const Value.absent(),
    this.namePy = const Value.absent(),
    this.account = const Value.absent(),
    this.isOnline = const Value.absent(),
    this.role = const Value.absent(),
    this.ownerId = const Value.absent(),
    this.extra = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id);
  static Insertable<DbContact> custom({
    Expression<String>? id,
    Expression<String>? displayName,
    Expression<String>? realName,
    Expression<String>? avatar,
    Expression<int>? isGroup,
    Expression<String>? indexLetter,
    Expression<String>? namePy,
    Expression<String>? account,
    Expression<int>? isOnline,
    Expression<int>? role,
    Expression<String>? ownerId,
    Expression<String>? extra,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (displayName != null) 'display_name': displayName,
      if (realName != null) 'real_name': realName,
      if (avatar != null) 'avatar': avatar,
      if (isGroup != null) 'is_group': isGroup,
      if (indexLetter != null) 'index_letter': indexLetter,
      if (namePy != null) 'name_py': namePy,
      if (account != null) 'account': account,
      if (isOnline != null) 'is_online': isOnline,
      if (role != null) 'role': role,
      if (ownerId != null) 'owner_id': ownerId,
      if (extra != null) 'extra': extra,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DbContactsCompanion copyWith({
    Value<String>? id,
    Value<String>? displayName,
    Value<String>? realName,
    Value<String>? avatar,
    Value<int>? isGroup,
    Value<String>? indexLetter,
    Value<String>? namePy,
    Value<String>? account,
    Value<int>? isOnline,
    Value<int>? role,
    Value<String>? ownerId,
    Value<String>? extra,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return DbContactsCompanion(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      realName: realName ?? this.realName,
      avatar: avatar ?? this.avatar,
      isGroup: isGroup ?? this.isGroup,
      indexLetter: indexLetter ?? this.indexLetter,
      namePy: namePy ?? this.namePy,
      account: account ?? this.account,
      isOnline: isOnline ?? this.isOnline,
      role: role ?? this.role,
      ownerId: ownerId ?? this.ownerId,
      extra: extra ?? this.extra,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (realName.present) {
      map['real_name'] = Variable<String>(realName.value);
    }
    if (avatar.present) {
      map['avatar'] = Variable<String>(avatar.value);
    }
    if (isGroup.present) {
      map['is_group'] = Variable<int>(isGroup.value);
    }
    if (indexLetter.present) {
      map['index_letter'] = Variable<String>(indexLetter.value);
    }
    if (namePy.present) {
      map['name_py'] = Variable<String>(namePy.value);
    }
    if (account.present) {
      map['account'] = Variable<String>(account.value);
    }
    if (isOnline.present) {
      map['is_online'] = Variable<int>(isOnline.value);
    }
    if (role.present) {
      map['role'] = Variable<int>(role.value);
    }
    if (ownerId.present) {
      map['owner_id'] = Variable<String>(ownerId.value);
    }
    if (extra.present) {
      map['extra'] = Variable<String>(extra.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DbContactsCompanion(')
          ..write('id: $id, ')
          ..write('displayName: $displayName, ')
          ..write('realName: $realName, ')
          ..write('avatar: $avatar, ')
          ..write('isGroup: $isGroup, ')
          ..write('indexLetter: $indexLetter, ')
          ..write('namePy: $namePy, ')
          ..write('account: $account, ')
          ..write('isOnline: $isOnline, ')
          ..write('role: $role, ')
          ..write('ownerId: $ownerId, ')
          ..write('extra: $extra, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $DbConversationsTable dbConversations = $DbConversationsTable(
    this,
  );
  late final $DbMessagesTable dbMessages = $DbMessagesTable(this);
  late final $DbContactsTable dbContacts = $DbContactsTable(this);
  late final Index idxMessagesConversation = Index(
    'idx_messages_conversation',
    'CREATE INDEX idx_messages_conversation ON db_messages (conversation_id, send_time)',
  );
  late final Index idxMessagesMsgId = Index(
    'idx_messages_msg_id',
    'CREATE UNIQUE INDEX idx_messages_msg_id ON db_messages (msg_id)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    dbConversations,
    dbMessages,
    dbContacts,
    idxMessagesConversation,
    idxMessagesMsgId,
  ];
}

typedef $$DbConversationsTableCreateCompanionBuilder =
    DbConversationsCompanion Function({
      required String id,
      Value<String> displayName,
      Value<String> avatar,
      Value<String> lastContent,
      Value<int> lastSendTime,
      Value<String> lastType,
      Value<int> isGroup,
      Value<int> unread,
      Value<int> isAt,
      Value<int> isTop,
      Value<int> isNotice,
      Value<int> role,
      Value<int> depId,
      Value<int> isOnline,
      Value<String> draft,
      Value<String> extra,
      Value<int> updatedAt,
      Value<int> rowid,
    });
typedef $$DbConversationsTableUpdateCompanionBuilder =
    DbConversationsCompanion Function({
      Value<String> id,
      Value<String> displayName,
      Value<String> avatar,
      Value<String> lastContent,
      Value<int> lastSendTime,
      Value<String> lastType,
      Value<int> isGroup,
      Value<int> unread,
      Value<int> isAt,
      Value<int> isTop,
      Value<int> isNotice,
      Value<int> role,
      Value<int> depId,
      Value<int> isOnline,
      Value<String> draft,
      Value<String> extra,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$DbConversationsTableFilterComposer
    extends Composer<_$AppDatabase, $DbConversationsTable> {
  $$DbConversationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get avatar => $composableBuilder(
    column: $table.avatar,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastContent => $composableBuilder(
    column: $table.lastContent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastSendTime => $composableBuilder(
    column: $table.lastSendTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastType => $composableBuilder(
    column: $table.lastType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isGroup => $composableBuilder(
    column: $table.isGroup,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get unread => $composableBuilder(
    column: $table.unread,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isAt => $composableBuilder(
    column: $table.isAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isTop => $composableBuilder(
    column: $table.isTop,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isNotice => $composableBuilder(
    column: $table.isNotice,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get depId => $composableBuilder(
    column: $table.depId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isOnline => $composableBuilder(
    column: $table.isOnline,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get draft => $composableBuilder(
    column: $table.draft,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get extra => $composableBuilder(
    column: $table.extra,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DbConversationsTableOrderingComposer
    extends Composer<_$AppDatabase, $DbConversationsTable> {
  $$DbConversationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get avatar => $composableBuilder(
    column: $table.avatar,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastContent => $composableBuilder(
    column: $table.lastContent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastSendTime => $composableBuilder(
    column: $table.lastSendTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastType => $composableBuilder(
    column: $table.lastType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isGroup => $composableBuilder(
    column: $table.isGroup,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get unread => $composableBuilder(
    column: $table.unread,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isAt => $composableBuilder(
    column: $table.isAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isTop => $composableBuilder(
    column: $table.isTop,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isNotice => $composableBuilder(
    column: $table.isNotice,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get depId => $composableBuilder(
    column: $table.depId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isOnline => $composableBuilder(
    column: $table.isOnline,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get draft => $composableBuilder(
    column: $table.draft,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extra => $composableBuilder(
    column: $table.extra,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DbConversationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $DbConversationsTable> {
  $$DbConversationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get avatar =>
      $composableBuilder(column: $table.avatar, builder: (column) => column);

  GeneratedColumn<String> get lastContent => $composableBuilder(
    column: $table.lastContent,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastSendTime => $composableBuilder(
    column: $table.lastSendTime,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastType =>
      $composableBuilder(column: $table.lastType, builder: (column) => column);

  GeneratedColumn<int> get isGroup =>
      $composableBuilder(column: $table.isGroup, builder: (column) => column);

  GeneratedColumn<int> get unread =>
      $composableBuilder(column: $table.unread, builder: (column) => column);

  GeneratedColumn<int> get isAt =>
      $composableBuilder(column: $table.isAt, builder: (column) => column);

  GeneratedColumn<int> get isTop =>
      $composableBuilder(column: $table.isTop, builder: (column) => column);

  GeneratedColumn<int> get isNotice =>
      $composableBuilder(column: $table.isNotice, builder: (column) => column);

  GeneratedColumn<int> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<int> get depId =>
      $composableBuilder(column: $table.depId, builder: (column) => column);

  GeneratedColumn<int> get isOnline =>
      $composableBuilder(column: $table.isOnline, builder: (column) => column);

  GeneratedColumn<String> get draft =>
      $composableBuilder(column: $table.draft, builder: (column) => column);

  GeneratedColumn<String> get extra =>
      $composableBuilder(column: $table.extra, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$DbConversationsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DbConversationsTable,
          DbConversation,
          $$DbConversationsTableFilterComposer,
          $$DbConversationsTableOrderingComposer,
          $$DbConversationsTableAnnotationComposer,
          $$DbConversationsTableCreateCompanionBuilder,
          $$DbConversationsTableUpdateCompanionBuilder,
          (
            DbConversation,
            BaseReferences<
              _$AppDatabase,
              $DbConversationsTable,
              DbConversation
            >,
          ),
          DbConversation,
          PrefetchHooks Function()
        > {
  $$DbConversationsTableTableManager(
    _$AppDatabase db,
    $DbConversationsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DbConversationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DbConversationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DbConversationsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<String> avatar = const Value.absent(),
                Value<String> lastContent = const Value.absent(),
                Value<int> lastSendTime = const Value.absent(),
                Value<String> lastType = const Value.absent(),
                Value<int> isGroup = const Value.absent(),
                Value<int> unread = const Value.absent(),
                Value<int> isAt = const Value.absent(),
                Value<int> isTop = const Value.absent(),
                Value<int> isNotice = const Value.absent(),
                Value<int> role = const Value.absent(),
                Value<int> depId = const Value.absent(),
                Value<int> isOnline = const Value.absent(),
                Value<String> draft = const Value.absent(),
                Value<String> extra = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DbConversationsCompanion(
                id: id,
                displayName: displayName,
                avatar: avatar,
                lastContent: lastContent,
                lastSendTime: lastSendTime,
                lastType: lastType,
                isGroup: isGroup,
                unread: unread,
                isAt: isAt,
                isTop: isTop,
                isNotice: isNotice,
                role: role,
                depId: depId,
                isOnline: isOnline,
                draft: draft,
                extra: extra,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String> displayName = const Value.absent(),
                Value<String> avatar = const Value.absent(),
                Value<String> lastContent = const Value.absent(),
                Value<int> lastSendTime = const Value.absent(),
                Value<String> lastType = const Value.absent(),
                Value<int> isGroup = const Value.absent(),
                Value<int> unread = const Value.absent(),
                Value<int> isAt = const Value.absent(),
                Value<int> isTop = const Value.absent(),
                Value<int> isNotice = const Value.absent(),
                Value<int> role = const Value.absent(),
                Value<int> depId = const Value.absent(),
                Value<int> isOnline = const Value.absent(),
                Value<String> draft = const Value.absent(),
                Value<String> extra = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DbConversationsCompanion.insert(
                id: id,
                displayName: displayName,
                avatar: avatar,
                lastContent: lastContent,
                lastSendTime: lastSendTime,
                lastType: lastType,
                isGroup: isGroup,
                unread: unread,
                isAt: isAt,
                isTop: isTop,
                isNotice: isNotice,
                role: role,
                depId: depId,
                isOnline: isOnline,
                draft: draft,
                extra: extra,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$DbConversationsTable, DbConversation>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $DbConversationsTable,
                    DbConversation
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DbConversationsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DbConversationsTable,
      DbConversation,
      $$DbConversationsTableFilterComposer,
      $$DbConversationsTableOrderingComposer,
      $$DbConversationsTableAnnotationComposer,
      $$DbConversationsTableCreateCompanionBuilder,
      $$DbConversationsTableUpdateCompanionBuilder,
      (
        DbConversation,
        BaseReferences<_$AppDatabase, $DbConversationsTable, DbConversation>,
      ),
      DbConversation,
      PrefetchHooks Function()
    >;
typedef $$DbMessagesTableCreateCompanionBuilder =
    DbMessagesCompanion Function({
      Value<int> localId,
      Value<int?> serverId,
      Value<String?> msgId,
      Value<String?> clientId,
      Value<String> status,
      required String conversationId,
      Value<String> fromUserId,
      Value<String> fromUserName,
      Value<String> fromUserAvatar,
      Value<String> toContactId,
      Value<String> toUser,
      Value<String> type,
      Value<String> content,
      Value<int> sendTime,
      Value<String> atUsers,
      Value<String> ext,
      Value<int> isGroup,
      Value<int> isRead,
      Value<int> isUndo,
      Value<int> isMobile,
      Value<String> extra,
    });
typedef $$DbMessagesTableUpdateCompanionBuilder =
    DbMessagesCompanion Function({
      Value<int> localId,
      Value<int?> serverId,
      Value<String?> msgId,
      Value<String?> clientId,
      Value<String> status,
      Value<String> conversationId,
      Value<String> fromUserId,
      Value<String> fromUserName,
      Value<String> fromUserAvatar,
      Value<String> toContactId,
      Value<String> toUser,
      Value<String> type,
      Value<String> content,
      Value<int> sendTime,
      Value<String> atUsers,
      Value<String> ext,
      Value<int> isGroup,
      Value<int> isRead,
      Value<int> isUndo,
      Value<int> isMobile,
      Value<String> extra,
    });

class $$DbMessagesTableFilterComposer
    extends Composer<_$AppDatabase, $DbMessagesTable> {
  $$DbMessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get localId => $composableBuilder(
    column: $table.localId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get msgId => $composableBuilder(
    column: $table.msgId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get clientId => $composableBuilder(
    column: $table.clientId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fromUserId => $composableBuilder(
    column: $table.fromUserId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fromUserName => $composableBuilder(
    column: $table.fromUserName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fromUserAvatar => $composableBuilder(
    column: $table.fromUserAvatar,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get toContactId => $composableBuilder(
    column: $table.toContactId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get toUser => $composableBuilder(
    column: $table.toUser,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sendTime => $composableBuilder(
    column: $table.sendTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get atUsers => $composableBuilder(
    column: $table.atUsers,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ext => $composableBuilder(
    column: $table.ext,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isGroup => $composableBuilder(
    column: $table.isGroup,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isRead => $composableBuilder(
    column: $table.isRead,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isUndo => $composableBuilder(
    column: $table.isUndo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isMobile => $composableBuilder(
    column: $table.isMobile,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get extra => $composableBuilder(
    column: $table.extra,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DbMessagesTableOrderingComposer
    extends Composer<_$AppDatabase, $DbMessagesTable> {
  $$DbMessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get localId => $composableBuilder(
    column: $table.localId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get msgId => $composableBuilder(
    column: $table.msgId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get clientId => $composableBuilder(
    column: $table.clientId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fromUserId => $composableBuilder(
    column: $table.fromUserId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fromUserName => $composableBuilder(
    column: $table.fromUserName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fromUserAvatar => $composableBuilder(
    column: $table.fromUserAvatar,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get toContactId => $composableBuilder(
    column: $table.toContactId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get toUser => $composableBuilder(
    column: $table.toUser,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sendTime => $composableBuilder(
    column: $table.sendTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get atUsers => $composableBuilder(
    column: $table.atUsers,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ext => $composableBuilder(
    column: $table.ext,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isGroup => $composableBuilder(
    column: $table.isGroup,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isRead => $composableBuilder(
    column: $table.isRead,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isUndo => $composableBuilder(
    column: $table.isUndo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isMobile => $composableBuilder(
    column: $table.isMobile,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extra => $composableBuilder(
    column: $table.extra,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DbMessagesTableAnnotationComposer
    extends Composer<_$AppDatabase, $DbMessagesTable> {
  $$DbMessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get localId =>
      $composableBuilder(column: $table.localId, builder: (column) => column);

  GeneratedColumn<int> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);

  GeneratedColumn<String> get msgId =>
      $composableBuilder(column: $table.msgId, builder: (column) => column);

  GeneratedColumn<String> get clientId =>
      $composableBuilder(column: $table.clientId, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get fromUserId => $composableBuilder(
    column: $table.fromUserId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get fromUserName => $composableBuilder(
    column: $table.fromUserName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get fromUserAvatar => $composableBuilder(
    column: $table.fromUserAvatar,
    builder: (column) => column,
  );

  GeneratedColumn<String> get toContactId => $composableBuilder(
    column: $table.toContactId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get toUser =>
      $composableBuilder(column: $table.toUser, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<int> get sendTime =>
      $composableBuilder(column: $table.sendTime, builder: (column) => column);

  GeneratedColumn<String> get atUsers =>
      $composableBuilder(column: $table.atUsers, builder: (column) => column);

  GeneratedColumn<String> get ext =>
      $composableBuilder(column: $table.ext, builder: (column) => column);

  GeneratedColumn<int> get isGroup =>
      $composableBuilder(column: $table.isGroup, builder: (column) => column);

  GeneratedColumn<int> get isRead =>
      $composableBuilder(column: $table.isRead, builder: (column) => column);

  GeneratedColumn<int> get isUndo =>
      $composableBuilder(column: $table.isUndo, builder: (column) => column);

  GeneratedColumn<int> get isMobile =>
      $composableBuilder(column: $table.isMobile, builder: (column) => column);

  GeneratedColumn<String> get extra =>
      $composableBuilder(column: $table.extra, builder: (column) => column);
}

class $$DbMessagesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DbMessagesTable,
          DbMessage,
          $$DbMessagesTableFilterComposer,
          $$DbMessagesTableOrderingComposer,
          $$DbMessagesTableAnnotationComposer,
          $$DbMessagesTableCreateCompanionBuilder,
          $$DbMessagesTableUpdateCompanionBuilder,
          (
            DbMessage,
            BaseReferences<_$AppDatabase, $DbMessagesTable, DbMessage>,
          ),
          DbMessage,
          PrefetchHooks Function()
        > {
  $$DbMessagesTableTableManager(_$AppDatabase db, $DbMessagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DbMessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DbMessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DbMessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> localId = const Value.absent(),
                Value<int?> serverId = const Value.absent(),
                Value<String?> msgId = const Value.absent(),
                Value<String?> clientId = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String> conversationId = const Value.absent(),
                Value<String> fromUserId = const Value.absent(),
                Value<String> fromUserName = const Value.absent(),
                Value<String> fromUserAvatar = const Value.absent(),
                Value<String> toContactId = const Value.absent(),
                Value<String> toUser = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<int> sendTime = const Value.absent(),
                Value<String> atUsers = const Value.absent(),
                Value<String> ext = const Value.absent(),
                Value<int> isGroup = const Value.absent(),
                Value<int> isRead = const Value.absent(),
                Value<int> isUndo = const Value.absent(),
                Value<int> isMobile = const Value.absent(),
                Value<String> extra = const Value.absent(),
              }) => DbMessagesCompanion(
                localId: localId,
                serverId: serverId,
                msgId: msgId,
                clientId: clientId,
                status: status,
                conversationId: conversationId,
                fromUserId: fromUserId,
                fromUserName: fromUserName,
                fromUserAvatar: fromUserAvatar,
                toContactId: toContactId,
                toUser: toUser,
                type: type,
                content: content,
                sendTime: sendTime,
                atUsers: atUsers,
                ext: ext,
                isGroup: isGroup,
                isRead: isRead,
                isUndo: isUndo,
                isMobile: isMobile,
                extra: extra,
              ),
          createCompanionCallback:
              ({
                Value<int> localId = const Value.absent(),
                Value<int?> serverId = const Value.absent(),
                Value<String?> msgId = const Value.absent(),
                Value<String?> clientId = const Value.absent(),
                Value<String> status = const Value.absent(),
                required String conversationId,
                Value<String> fromUserId = const Value.absent(),
                Value<String> fromUserName = const Value.absent(),
                Value<String> fromUserAvatar = const Value.absent(),
                Value<String> toContactId = const Value.absent(),
                Value<String> toUser = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<int> sendTime = const Value.absent(),
                Value<String> atUsers = const Value.absent(),
                Value<String> ext = const Value.absent(),
                Value<int> isGroup = const Value.absent(),
                Value<int> isRead = const Value.absent(),
                Value<int> isUndo = const Value.absent(),
                Value<int> isMobile = const Value.absent(),
                Value<String> extra = const Value.absent(),
              }) => DbMessagesCompanion.insert(
                localId: localId,
                serverId: serverId,
                msgId: msgId,
                clientId: clientId,
                status: status,
                conversationId: conversationId,
                fromUserId: fromUserId,
                fromUserName: fromUserName,
                fromUserAvatar: fromUserAvatar,
                toContactId: toContactId,
                toUser: toUser,
                type: type,
                content: content,
                sendTime: sendTime,
                atUsers: atUsers,
                ext: ext,
                isGroup: isGroup,
                isRead: isRead,
                isUndo: isUndo,
                isMobile: isMobile,
                extra: extra,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$DbMessagesTable, DbMessage>(table),
                  BaseReferences<_$AppDatabase, $DbMessagesTable, DbMessage>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DbMessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DbMessagesTable,
      DbMessage,
      $$DbMessagesTableFilterComposer,
      $$DbMessagesTableOrderingComposer,
      $$DbMessagesTableAnnotationComposer,
      $$DbMessagesTableCreateCompanionBuilder,
      $$DbMessagesTableUpdateCompanionBuilder,
      (DbMessage, BaseReferences<_$AppDatabase, $DbMessagesTable, DbMessage>),
      DbMessage,
      PrefetchHooks Function()
    >;
typedef $$DbContactsTableCreateCompanionBuilder =
    DbContactsCompanion Function({
      required String id,
      Value<String> displayName,
      Value<String> realName,
      Value<String> avatar,
      Value<int> isGroup,
      Value<String> indexLetter,
      Value<String> namePy,
      Value<String> account,
      Value<int> isOnline,
      Value<int> role,
      Value<String> ownerId,
      Value<String> extra,
      Value<int> updatedAt,
      Value<int> rowid,
    });
typedef $$DbContactsTableUpdateCompanionBuilder =
    DbContactsCompanion Function({
      Value<String> id,
      Value<String> displayName,
      Value<String> realName,
      Value<String> avatar,
      Value<int> isGroup,
      Value<String> indexLetter,
      Value<String> namePy,
      Value<String> account,
      Value<int> isOnline,
      Value<int> role,
      Value<String> ownerId,
      Value<String> extra,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$DbContactsTableFilterComposer
    extends Composer<_$AppDatabase, $DbContactsTable> {
  $$DbContactsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get realName => $composableBuilder(
    column: $table.realName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get avatar => $composableBuilder(
    column: $table.avatar,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isGroup => $composableBuilder(
    column: $table.isGroup,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get indexLetter => $composableBuilder(
    column: $table.indexLetter,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get namePy => $composableBuilder(
    column: $table.namePy,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get account => $composableBuilder(
    column: $table.account,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isOnline => $composableBuilder(
    column: $table.isOnline,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get extra => $composableBuilder(
    column: $table.extra,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DbContactsTableOrderingComposer
    extends Composer<_$AppDatabase, $DbContactsTable> {
  $$DbContactsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get realName => $composableBuilder(
    column: $table.realName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get avatar => $composableBuilder(
    column: $table.avatar,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isGroup => $composableBuilder(
    column: $table.isGroup,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get indexLetter => $composableBuilder(
    column: $table.indexLetter,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get namePy => $composableBuilder(
    column: $table.namePy,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get account => $composableBuilder(
    column: $table.account,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isOnline => $composableBuilder(
    column: $table.isOnline,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extra => $composableBuilder(
    column: $table.extra,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DbContactsTableAnnotationComposer
    extends Composer<_$AppDatabase, $DbContactsTable> {
  $$DbContactsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get realName =>
      $composableBuilder(column: $table.realName, builder: (column) => column);

  GeneratedColumn<String> get avatar =>
      $composableBuilder(column: $table.avatar, builder: (column) => column);

  GeneratedColumn<int> get isGroup =>
      $composableBuilder(column: $table.isGroup, builder: (column) => column);

  GeneratedColumn<String> get indexLetter => $composableBuilder(
    column: $table.indexLetter,
    builder: (column) => column,
  );

  GeneratedColumn<String> get namePy =>
      $composableBuilder(column: $table.namePy, builder: (column) => column);

  GeneratedColumn<String> get account =>
      $composableBuilder(column: $table.account, builder: (column) => column);

  GeneratedColumn<int> get isOnline =>
      $composableBuilder(column: $table.isOnline, builder: (column) => column);

  GeneratedColumn<int> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<String> get ownerId =>
      $composableBuilder(column: $table.ownerId, builder: (column) => column);

  GeneratedColumn<String> get extra =>
      $composableBuilder(column: $table.extra, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$DbContactsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DbContactsTable,
          DbContact,
          $$DbContactsTableFilterComposer,
          $$DbContactsTableOrderingComposer,
          $$DbContactsTableAnnotationComposer,
          $$DbContactsTableCreateCompanionBuilder,
          $$DbContactsTableUpdateCompanionBuilder,
          (
            DbContact,
            BaseReferences<_$AppDatabase, $DbContactsTable, DbContact>,
          ),
          DbContact,
          PrefetchHooks Function()
        > {
  $$DbContactsTableTableManager(_$AppDatabase db, $DbContactsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DbContactsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DbContactsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DbContactsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<String> realName = const Value.absent(),
                Value<String> avatar = const Value.absent(),
                Value<int> isGroup = const Value.absent(),
                Value<String> indexLetter = const Value.absent(),
                Value<String> namePy = const Value.absent(),
                Value<String> account = const Value.absent(),
                Value<int> isOnline = const Value.absent(),
                Value<int> role = const Value.absent(),
                Value<String> ownerId = const Value.absent(),
                Value<String> extra = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DbContactsCompanion(
                id: id,
                displayName: displayName,
                realName: realName,
                avatar: avatar,
                isGroup: isGroup,
                indexLetter: indexLetter,
                namePy: namePy,
                account: account,
                isOnline: isOnline,
                role: role,
                ownerId: ownerId,
                extra: extra,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String> displayName = const Value.absent(),
                Value<String> realName = const Value.absent(),
                Value<String> avatar = const Value.absent(),
                Value<int> isGroup = const Value.absent(),
                Value<String> indexLetter = const Value.absent(),
                Value<String> namePy = const Value.absent(),
                Value<String> account = const Value.absent(),
                Value<int> isOnline = const Value.absent(),
                Value<int> role = const Value.absent(),
                Value<String> ownerId = const Value.absent(),
                Value<String> extra = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DbContactsCompanion.insert(
                id: id,
                displayName: displayName,
                realName: realName,
                avatar: avatar,
                isGroup: isGroup,
                indexLetter: indexLetter,
                namePy: namePy,
                account: account,
                isOnline: isOnline,
                role: role,
                ownerId: ownerId,
                extra: extra,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$DbContactsTable, DbContact>(table),
                  BaseReferences<_$AppDatabase, $DbContactsTable, DbContact>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DbContactsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DbContactsTable,
      DbContact,
      $$DbContactsTableFilterComposer,
      $$DbContactsTableOrderingComposer,
      $$DbContactsTableAnnotationComposer,
      $$DbContactsTableCreateCompanionBuilder,
      $$DbContactsTableUpdateCompanionBuilder,
      (DbContact, BaseReferences<_$AppDatabase, $DbContactsTable, DbContact>),
      DbContact,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$DbConversationsTableTableManager get dbConversations =>
      $$DbConversationsTableTableManager(_db, _db.dbConversations);
  $$DbMessagesTableTableManager get dbMessages =>
      $$DbMessagesTableTableManager(_db, _db.dbMessages);
  $$DbContactsTableTableManager get dbContacts =>
      $$DbContactsTableTableManager(_db, _db.dbContacts);
}
