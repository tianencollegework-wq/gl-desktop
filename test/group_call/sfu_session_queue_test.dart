import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/net/api_exception.dart';
import 'package:gracelinkim/domain/group_call/sfu_failure.dart';
import 'package:gracelinkim/domain/group_call/sfu_session_queue.dart';

/// 让排队的操作有机会推进
Future<void> pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('失败分类（决定"能不能继续用这条会话"）', () {
    test('会话过期 / 结果未知 → 必须重建', () {
      for (final code in <int>[
        SfuCodes.sessionGone, // CF 410
        SfuCodes.upstreamUnreachable, // 超时 / 上游 5xx
      ]) {
        final failure = SfuFailure.fromCode(code, 'x');
        expect(
          failure.requiresRebuild,
          isTrue,
          reason: 'code=$code 必须触发换新会话重建',
        );
      }
    });

    test('明确被拒 → 不重建会话（什么都没发生）', () {
      for (final code in <int>[
        SfuCodes.badRequest,
        SfuCodes.sessionConflict, // CF 406：并发提交被拒，修顺序后重发即可
        SfuCodes.notMember,
        SfuCodes.roomFull,
      ]) {
        final failure = SfuFailure.fromCode(code, 'x');
        expect(failure.requiresRebuild, isFalse, reason: 'code=$code 不该重建');
      }
    });

    test('上游鉴权失败 → 要重新登录，但不是会话死了', () {
      final failure = SfuFailure.fromCode(SfuCodes.upstreamAuth, 'x');
      expect(failure.kind, SfuFailureKind.unauthorized);
      expect(failure.requiresRebuild, isFalse);
      expect(failure.needsRelogin, isTrue);
    });

    test('超时 / 断网 / 5xx 一律算"结果未知"（可能已经生效，不能重试）', () {
      expect(
        SfuFailure.fromApiException(
          const NetworkUnavailableException('请求超时，请检查网络后重试'),
        ).kind,
        SfuFailureKind.unknownOutcome,
      );
      expect(
        SfuFailure.fromApiException(const ServerException()).kind,
        SfuFailureKind.unknownOutcome,
      );
      expect(
        SfuFailure.fromApiException(const UnknownApiException()).kind,
        SfuFailureKind.unknownOutcome,
      );
    });

    test('HTTP 401 / 业务码 -1 → 重新登录，不重建会话', () {
      expect(
        SfuFailure.fromApiException(const UnauthorizedException()).kind,
        SfuFailureKind.unauthorized,
      );
      expect(
        SfuFailure.fromApiException(const SessionExpiredException()).kind,
        SfuFailureKind.unauthorized,
      );
    });

    test('信封里的非零业务码按映射走', () {
      expect(
        SfuFailure.fromApiException(
          const BusinessException(SfuCodes.sessionGone, 'gone'),
        ).requiresRebuild,
        isTrue,
      );
      expect(
        SfuFailure.fromApiException(
          const BusinessException(SfuCodes.notMember, 'no'),
        ).kind,
        SfuFailureKind.rejected,
      );
    });
  });

  group('SfuSessionQueue：同一会话的改动必须串行', () {
    test('并发提交时按顺序一条一条跑，同时只有一个在飞', () async {
      final queue = SfuSessionQueue(sessionId: 'sess-1');
      final started = <String>[];
      var inFlight = 0;
      var maxInFlight = 0;

      Future<String> mutation(String label) => queue.run(label, () async {
        started.add(label);
        inFlight += 1;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await pump();
        inFlight -= 1;
        return label;
      });

      // 一次性全提交（CF 文档里"A 还在入会、B 又加入"就是这个形状）
      final futures = <Future<String>>[
        mutation('snapshot'),
        mutation('peer-joined'),
        mutation('publish'),
      ];
      expect(await Future.wait(futures), <String>[
        'snapshot',
        'peer-joined',
        'publish',
      ]);
      expect(started, <String>['snapshot', 'peer-joined', 'publish']);
      expect(maxInFlight, 1);
      expect(queue.pending, 0);
    });

    test('前一条没结束，后一条不会开始（操作跨越整个 SDP 交换）', () async {
      final queue = SfuSessionQueue(sessionId: 'sess-1');
      final gate = Completer<void>();
      var secondStarted = false;

      final first = queue.run('subscribe', () async {
        await gate.future; // 模拟"等 CF 的 answer 应用完"
        return 'first';
      });
      final second = queue.run('publish', () async {
        secondStarted = true;
        return 'second';
      });

      await pump();
      expect(secondStarted, isFalse, reason: '前一条还在跑，后一条必须等着');
      expect(queue.pending, 2);

      gate.complete();
      expect(await first, 'first');
      expect(await second, 'second');
      expect(secondStarted, isTrue);
    });

    test('结果未知 → 毒化：后续提交立刻失败，并通知重建（只通知一次）', () async {
      final queue = SfuSessionQueue(sessionId: 'sess-1');
      var poisonCalls = 0;
      queue.onPoisoned = (_) => poisonCalls += 1;

      final failed = queue.run('publish', () async {
        throw SfuFailure.fromCode(SfuCodes.upstreamUnreachable, '超时');
      });
      await expectLater(failed, throwsA(isA<SfuFailure>()));
      await pump();

      expect(queue.isPoisoned, isTrue);
      expect(queue.poisonReason?.kind, SfuFailureKind.unknownOutcome);
      expect(queue.poisonedBy, 'publish');
      expect(poisonCalls, 1);

      // 之后的提交不再发请求，直接失败并说明要重建
      var ran = false;
      await expectLater(
        queue.run('subscribe', () async {
          ran = true;
          return 'x';
        }),
        throwsA(
          isA<SfuFailure>().having(
            (failure) => failure.requiresRebuild,
            'requiresRebuild',
            isTrue,
          ),
        ),
      );
      expect(ran, isFalse, reason: '死会话上不该再发请求');
      expect(poisonCalls, 1, reason: '毒化只通知一次');
    });

    test('会话过期同样毒化', () async {
      final queue = SfuSessionQueue(sessionId: 'sess-1');
      final failed = queue.run('subscribe', () async {
        throw SfuFailure.fromCode(SfuCodes.sessionGone, '410');
      });
      await expectLater(failed, throwsA(isA<SfuFailure>()));
      expect(queue.isPoisoned, isTrue);
    });

    test('明确被拒不毒化，队列照常跑下一条', () async {
      final queue = SfuSessionQueue(sessionId: 'sess-1');
      var poisonCalls = 0;
      queue.onPoisoned = (_) => poisonCalls += 1;

      final rejected = queue.run('subscribe', () async {
        throw SfuFailure.fromCode(SfuCodes.sessionConflict, '406');
      });
      await expectLater(rejected, throwsA(isA<SfuFailure>()));

      expect(queue.isPoisoned, isFalse);
      expect(poisonCalls, 0);
      expect(await queue.run('subscribe-again', () async => 'ok'), 'ok');
    });

    test('非 SfuFailure 的异常不毒化会话，也不会把队列卡死', () async {
      final queue = SfuSessionQueue(sessionId: 'sess-1');

      final boom = queue.run('publish', () async {
        throw StateError('我们的 bug');
      });
      await expectLater(boom, throwsA(isA<StateError>()));
      expect(queue.isPoisoned, isFalse);

      expect(await queue.run('after', () async => 1), 1);
    });

    test('毒化发生在排队中途：后面已经排上的也会被拦下', () async {
      final queue = SfuSessionQueue(sessionId: 'sess-1');
      var secondRan = false;

      final first = queue.run('publish', () async {
        throw SfuFailure.fromCode(SfuCodes.upstreamUnreachable, '超时');
      });
      final second = queue.run('subscribe', () async {
        secondRan = true;
        return 'x';
      });

      await expectLater(first, throwsA(isA<SfuFailure>()));
      await expectLater(second, throwsA(isA<SfuFailure>()));
      expect(secondRan, isFalse);
    });
  });
}
