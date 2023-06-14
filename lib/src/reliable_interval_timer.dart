import 'dart:async';
import 'dart:isolate';

class ReliableIntervalTimer {
  static const _isolateTimerDurationMicroseconds = 500;

  Duration interval;

  final Function(int elapsedMilliseconds) callback;

  Isolate? _isolate;
  StreamSubscription? _isolateSubscription;

  SendPort? _childSendPort;

  bool _isWarmingUp = true;
  bool _isReady = false;

  int _millisecondsLastTick = -1;

  ReliableIntervalTimer({
    required this.interval,
    required this.callback,
  }) : assert(interval.inMilliseconds > 0, 'Intervals smaller than a millisecond are not supported');

  Future<void> start() async {
    if (_isolate != null) {
      throw Exception('Timer is already running! Use stop() to stop it before restarting.');
    }

    var completer = Completer();

    ReceivePort receiveFromIsolatePort = ReceivePort();
    ReceivePort childSendPort = ReceivePort();

    _isolate = await Isolate.spawn(
      _isolateTimer,
      {
        'tickRate': interval.inMilliseconds,
        'sendToMainThreadPort': receiveFromIsolatePort.sendPort,
        'childSendPort': childSendPort.sendPort,
      },
    );

    _isolateSubscription = receiveFromIsolatePort.listen((data) {
      if (data is SendPort) {
        _childSendPort = data;
      } else {
        _onIsolateTimerTick(completer);
      }
    });

    return completer.future;
  }

  Future<void> stop() async {
    await _isolateSubscription?.cancel();
    _isolateSubscription = null;

    _isolate?.kill();
    _isolate = null;
    _childSendPort = null;
  }

  Future<void> updateInterval(Duration newInterval) async {
    interval = newInterval;
    _childSendPort?.send(newInterval.inMilliseconds);
  }

  void _onIsolateTimerTick(Completer completer) {
    var now = DateTime.now().millisecondsSinceEpoch;

    var elapsedMilliseconds = (now - _millisecondsLastTick).abs();

    _millisecondsLastTick = now;

    if (_isWarmingUp) {
      _isReady = elapsedMilliseconds == interval.inMilliseconds;
      _isWarmingUp = !_isReady;

      if (_isReady) completer.complete();
    } else {
      callback(elapsedMilliseconds);
    }
  }

  static Future<void> _isolateTimer(Map data) async {
    int tickRate = data['tickRate'];
    SendPort sendToMainThreadPort = data['sendToMainThreadPort'];
    SendPort childSendPort = data['childSendPort'];

    var millisLastTick = DateTime.now().millisecondsSinceEpoch;

    ReceivePort receivePort = ReceivePort();
    sendToMainThreadPort.send(receivePort.sendPort);

    receivePort.listen((newTickRate) {
      if (newTickRate is int) {
        tickRate = newTickRate;
      }
    });

    Timer.periodic(
      const Duration(microseconds: _isolateTimerDurationMicroseconds),
      (_) {
        var now = DateTime.now().millisecondsSinceEpoch;
        var duration = now - millisLastTick;

        if (duration >= tickRate) {
          sendToMainThreadPort.send(null);
          millisLastTick = now;
        }
      },
    );
  }
}
