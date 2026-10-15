// The flaky-link proxy itself, against a loopback echo server.
import 'dart:async';
import 'dart:io';

import 'package:sync_relay_core/testing.dart';
import 'package:test/test.dart';

/// A client socket through the proxy, collecting what comes back.
class _Client {
  final Socket socket;
  final received = <int>[];
  final done = Completer<Object?>();
  _Client(this.socket) {
    socket.done.then((_) {}, onError: (_) {});
    socket.listen(received.addAll,
        onDone: () => done.isCompleted ? null : done.complete(null),
        onError: (Object e) => done.isCompleted ? null : done.complete(e));
  }

  static Future<_Client> dial(FlakyProxy p) async => _Client(await Socket.connect('127.0.0.1', p.port));

  void send(String s) => socket.add(s.codeUnits);
  String get text => String.fromCharCodes(received);
}

Future<void> until(bool Function() ok, {Duration limit = const Duration(seconds: 3)}) async {
  final end = DateTime.now().add(limit);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('condition not met in $limit');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late ServerSocket echo;
  late FlakyProxy proxy;

  setUp(() async {
    echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    echo.listen((s) {
      s.done.then((_) {}, onError: (_) {});
      s.listen(s.add, onDone: () => s.close().then((_) {}, onError: (_) {}), onError: (_) {});
    });
    proxy = await FlakyProxy.start(echo.port);
  });

  tearDown(() async {
    await proxy.close();
    await echo.close();
  });

  test('passes bytes both ways and counts them', () async {
    final c = await _Client.dial(proxy);
    c.send('hello');
    await until(() => c.text == 'hello');
    expect(proxy.links, hasLength(1));
    expect(proxy.last!.bytesUp, 5);
    expect(proxy.last!.bytesDown, 5);
    await c.socket.close();
    await proxy.last!.closed.timeout(const Duration(seconds: 3));
  });

  test('blackhole drops everything both ways and keeps the socket open', () async {
    final c = await _Client.dial(proxy);
    c.send('a');
    await until(() => c.text == 'a');
    proxy.last!.blackhole();
    c.send('bcd');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(c.text, 'a');
    expect(proxy.last!.dropped, 3);
    expect(c.done.isCompleted, isFalse);
    expect(proxy.last!.isClosed, isFalse);
  });

  test('delay holds every chunk', () async {
    final c = await _Client.dial(proxy);
    await until(() => proxy.last != null);
    proxy.last!.delay = const Duration(milliseconds: 150);
    final sw = Stopwatch()..start();
    c.send('x');
    await until(() => c.text == 'x');
    // Up and down each wait 150 ms.
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(290));
  });

  test('holdNext delivers one chunk late and keeps order', () async {
    final c = await _Client.dial(proxy);
    await until(() => proxy.last != null);
    proxy.last!.holdNext(const Duration(milliseconds: 300), flow: Flow.up);
    final sw = Stopwatch()..start();
    c.send('1');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    c.send('2');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(c.text, '', reason: 'both still held');
    await until(() => c.text == '12');
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(290));
  });

  test('cutAfter delivers N bytes then resets', () async {
    final c = await _Client.dial(proxy);
    await until(() => proxy.last != null);
    proxy.last!.cutAfter(3, flow: Flow.up);
    c.send('abcdef');
    await c.done.future.timeout(const Duration(seconds: 3));
    expect(proxy.last!.bytesUp, 3);
    expect(proxy.last!.isClosed, isTrue);
  });

  test('reset ends the client at once', () async {
    final c = await _Client.dial(proxy);
    c.send('a');
    await until(() => c.text == 'a');
    proxy.last!.reset();
    await c.done.future.timeout(const Duration(seconds: 3));
    expect(proxy.last!.isClosed, isTrue);
  });

  test('onConnect can steer a link before any byte goes through', () async {
    proxy.onConnect = (l) => l.reset();
    // The RST can beat the connect's own completion.
    try {
      final c = await _Client.dial(proxy);
      await c.done.future.timeout(const Duration(seconds: 3));
      expect(c.text, '');
    } on Object catch (e) {
      // dart:io throws the bare OSError here (ECONNRESET), on some
      // platforms a SocketException.
      expect(e, anyOf(isA<OSError>(), isA<SocketException>()));
    }
    expect(proxy.last!.isClosed, isTrue);
  });
}
