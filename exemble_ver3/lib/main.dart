// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:ui';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

void main() {
  runApp(const TrafficApp());
}

class TrafficApp extends StatelessWidget {
  const TrafficApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const TrafficHome(),
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(1.0),
          ),
          child: child!,
        );
      },
    );
  }
}

// ==================== HELPER FUNCTIONS ====================
double getResponsiveFontSize(BuildContext context, double fontSize) {
  double screenWidth = MediaQuery.of(context).size.width;
  const double baseWidth = 375.0;
  double scale = screenWidth / baseWidth;
  scale = scale.clamp(0.8, 1.3);
  return fontSize * scale;
}

// ==================== MQTT MANAGER ====================
class MQTTManager {
  late MqttServerClient client;
  final String host = 'broker.emqx.io';
  final int port = 1883;
  final String clientId = 'flutter_traffic_controller_${DateTime.now().millisecondsSinceEpoch}';

  final String topicPublish = 'traffic/control';
  final String topicSubscribe = 'traffic/status';

  Function(String)? onMessageReceived;
  Function()? onConnected;
  Function()? onDisconnected;
  Function(Map<String, dynamic>)? onStatusReceived;

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  MQTTManager() {
    client = MqttServerClient(host, clientId);
    client.port = port;
    client.keepAlivePeriod = 60;
    client.logging(on: false);
    client.setProtocolV311();
    client.autoReconnect = true;
    client.resubscribeOnAutoReconnect = true;
  }

  Future<bool> connect() async {
    try {
      print('🔄 Connecting to MQTT broker...');

      final connMessage = MqttConnectMessage()
          .withClientIdentifier(clientId)
          .keepAliveFor(60)
          .withWillTopic('willtopic')
          .withWillMessage('Client disconnected')
          .startClean();

      client.connectionMessage = connMessage;

      await client.connect();

      if (client.connectionStatus?.state == MqttConnectionState.connected) {
        print('✅ MQTT Connected!');

        client.subscribe(topicSubscribe, MqttQos.atLeastOnce);
        print('📡 Subscribed to $topicSubscribe');

        client.updates?.listen((List<MqttReceivedMessage<MqttMessage>> c) {
          final recMess = c[0].payload as MqttPublishMessage;
          final payload = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);

          print('📨 Received: $payload from ${c[0].topic}');

          if (payload.trim().startsWith('{')) {
            try {
              final jsonData = jsonDecode(payload);
              onStatusReceived?.call(jsonData);
            } catch (e) {
              print('Error parsing JSON: $e');
            }
          }

          onMessageReceived?.call(payload);
        });

        _isConnected = true;
        onConnected?.call();
        return true;
      } else {
        print('❌ MQTT connection failed: ${client.connectionStatus}');
        _isConnected = false;
        return false;
      }
    } catch (e) {
      print('❌ MQTT exception: $e');
      _isConnected = false;
      return false;
    }
  }

  void disconnect() {
    client.disconnect();
    _isConnected = false;
    onDisconnected?.call();
    print('🔌 MQTT Disconnected');
  }

  void publishCommand(String command) {
    if (!_isConnected) {
      print('⚠️ MQTT not connected!');
      return;
    }

    final builder = MqttClientPayloadBuilder();
    builder.addString(command);
    client.publishMessage(topicPublish, MqttQos.atLeastOnce, builder.payload!);
    print('📤 Published: $command');
  }

  Future<bool> reconnect() async {
    disconnect();
    await Future.delayed(const Duration(seconds: 2));
    return await connect();
  }
}

// ==================== TRAFFIC LOGIC (ACTIVE CONTROLLER) ====================
class TrafficLogic extends ChangeNotifier {
  List<String> states = ["green", "red", "green", "red"];
  List<int> counters = [10, 15, 10, 15];

  int greenTime = 10;
  int yellowTime = 5;
  int redTime = 15;

  String _modeBeforePriority = "🚗 Bình thường";
  int _redTimeBeforePriority = 15;
  int _greenTimeBeforePriority = 10;
  int _yellowTimeBeforePriority = 5;

  String currentMode = "🚗 Bình thường";

  bool priorityMode = false;
  int priorityId = -1;
  bool priorityBlink = false;

  bool nightMode = false;
  bool nightBlink = false;
  bool nightModeManual = false;

  Timer? timer;
  Function(String, Color)? onShowMessage;

  Function(String)? onPublishCommand;

  bool _isSyncedWithFirmware = false;
  bool get isSyncedWithFirmware => _isSyncedWithFirmware;

  bool _isWaitingForSync = false;
  Timer? _syncDelayTimer;

  TrafficLogic() {
    startTimer();
  }

  void startTimer() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateStateMachine();
    });
  }

  void _updateModeFromTimes() {
    if (nightMode) {
      if (nightModeManual) {
        currentMode = "🌙 Ban đêm (thủ công)";
      } else {
        currentMode = "🌙 Ban đêm";
      }
    } else if (priorityMode) {
      currentMode = "🚑 Ưu tiên hướng ${priorityId + 1}";
    } else {
      if (redTime == 15 && greenTime == 10 && yellowTime == 5) {
        currentMode = "🚗 Bình thường";
      } else if (redTime == 30 && greenTime == 25 && yellowTime == 5) {
        currentMode = "🚙 Đông xe";
      } else if (redTime == 12 && greenTime == 10 && yellowTime == 2) {
        currentMode = "🚲 Ít xe";
      } else {
        currentMode = "⚙️ Tùy chỉnh";
      }
    }
  }

  void _delayedReset() {
    _syncDelayTimer?.cancel();
    _isWaitingForSync = true;

    for (int i = 0; i < 4; i++) {
      counters[i] = 0;
    }
    notifyListeners();

    _syncDelayTimer = Timer(const Duration(seconds: 1), () {
      states = ["green", "red", "green", "red"];
      counters = [greenTime, redTime, greenTime, redTime];
      _isWaitingForSync = false;
      notifyListeners();
    });
  }

  void _resetImmediately() {
    _syncDelayTimer?.cancel();
    _isWaitingForSync = false;
    states = ["green", "red", "green", "red"];
    counters = [greenTime, redTime, greenTime, redTime];
    notifyListeners();
  }

  void activateNormalMode() {
    print("🚗 Activating NORMAL mode");

    redTime = 15;
    greenTime = 10;
    yellowTime = 5;

    priorityMode = false;
    nightMode = false;
    nightModeManual = false;

    _updateModeFromTimes();

    if (!priorityMode) {
      _modeBeforePriority = currentMode;
      _redTimeBeforePriority = redTime;
      _greenTimeBeforePriority = greenTime;
      _yellowTimeBeforePriority = yellowTime;
    }

    _delayedReset();

    if (onPublishCommand != null) {
      onPublishCommand?.call('N');
    }

    onShowMessage?.call("✅ Chế độ bình thường", Colors.green);
    notifyListeners();
  }

  void activatePeakMode() {
    print("🚙 Activating PEAK mode");

    redTime = 30;
    greenTime = 25;
    yellowTime = 5;

    priorityMode = false;
    nightMode = false;
    nightModeManual = false;

    _updateModeFromTimes();

    if (!priorityMode) {
      _modeBeforePriority = currentMode;
      _redTimeBeforePriority = redTime;
      _greenTimeBeforePriority = greenTime;
      _yellowTimeBeforePriority = yellowTime;
    }

    _delayedReset();

    if (onPublishCommand != null) {
      onPublishCommand?.call('P');
    }

    onShowMessage?.call("🚙 Chế độ cao điểm", Colors.orange);
    notifyListeners();
  }

  void activateLowMode() {
    print("🚲 Activating LOW mode");

    redTime = 12;
    greenTime = 10;
    yellowTime = 2;

    priorityMode = false;
    nightMode = false;
    nightModeManual = false;

    _updateModeFromTimes();

    if (!priorityMode) {
      _modeBeforePriority = currentMode;
      _redTimeBeforePriority = redTime;
      _greenTimeBeforePriority = greenTime;
      _yellowTimeBeforePriority = yellowTime;
    }

    _delayedReset();

    if (onPublishCommand != null) {
      onPublishCommand?.call('L');
    }

    onShowMessage?.call("🚲 Chế độ thấp điểm", Colors.green);
    notifyListeners();
  }

  void activatePriorityMode(int id) {
    print("🚑 Activating PRIORITY mode for direction $id");

    if (!priorityMode) {
      _modeBeforePriority = currentMode;
      _redTimeBeforePriority = redTime;
      _greenTimeBeforePriority = greenTime;
      _yellowTimeBeforePriority = yellowTime;
      print("📝 Saved mode before priority: $_modeBeforePriority");
    }

    priorityMode = true;
    nightMode = false;
    nightModeManual = false;
    priorityId = id;

    _updateModeFromTimes();

    _isWaitingForSync = true;

    for (int i = 0; i < 4; i++) {
      if (i == id) {
        states[i] = "green";
      } else {
        states[i] = "red";
      }
      counters[i] = 0;
    }
    notifyListeners();

    _syncDelayTimer?.cancel();
    _syncDelayTimer = Timer(const Duration(seconds: 1), () {
      for (int i = 0; i < 4; i++) {
        if (i == id) {
          counters[i] = greenTime;
        } else {
          counters[i] = redTime;
        }
      }
      _isWaitingForSync = false;
      notifyListeners();
    });

    if (onPublishCommand != null) {
      onPublishCommand?.call('P$id');
    }

    onShowMessage?.call("🚑 Ưu tiên hướng ${id + 1}", Colors.red);
    notifyListeners();
  }

  void exitPriorityMode() {
    print("❌ Exiting PRIORITY mode");

    priorityMode = false;
    priorityId = -1;

    redTime = _redTimeBeforePriority;
    greenTime = _greenTimeBeforePriority;
    yellowTime = _yellowTimeBeforePriority;

    _updateModeFromTimes();
    print("📝 Restored mode: $currentMode");

    _delayedReset();

    if (onPublishCommand != null) {
      if (redTime == 15 && greenTime == 10 && yellowTime == 5) {
        onPublishCommand?.call('N');
      } else if (redTime == 30 && greenTime == 25 && yellowTime == 5) {
        onPublishCommand?.call('P');
      } else if (redTime == 12 && greenTime == 10 && yellowTime == 2) {
        onPublishCommand?.call('L');
      } else {
        onPublishCommand?.call('R${redTime}G${greenTime}Y${yellowTime}');
      }
    }

    onShowMessage?.call("✅ Thoát ưu tiên - Quay về $_modeBeforePriority", Colors.blue);
    notifyListeners();
  }

  void activateNightModeManual() {
    print("🌙 Activating NIGHT mode (manual)");

    if (!nightMode && !priorityMode) {
      _modeBeforePriority = currentMode;
      _redTimeBeforePriority = redTime;
      _greenTimeBeforePriority = greenTime;
      _yellowTimeBeforePriority = yellowTime;
    }

    nightMode = true;
    nightModeManual = true;
    priorityMode = false;

    _updateModeFromTimes();

    if (onPublishCommand != null) {
      onPublishCommand?.call('NM');
    }

    onShowMessage?.call("🌙 Chế độ ban đêm (thủ công)", Colors.indigo);
    notifyListeners();
  }

  void deactivateNightModeManual() {
    print("☀️ Deactivating NIGHT mode");

    nightMode = false;
    nightModeManual = false;

    redTime = 15;
    greenTime = 10;
    yellowTime = 5;

    _updateModeFromTimes();

    _delayedReset();

    if (onPublishCommand != null) {
      onPublishCommand?.call('NMO');
    }

    onShowMessage?.call("☀️ Tắt chế độ ban đêm - Quay về chế độ bình thường", Colors.amber);
    notifyListeners();
  }

  void activateCustomMode(int red, int green, int yellow) {
    print("⚙️ Activating CUSTOM mode: R${red}G${green}Y${yellow}");

    if (red != green + yellow) {
      onShowMessage?.call("❌ Đỏ phải = Xanh + Vàng", Colors.red);
      return;
    }

    if (!priorityMode) {
      _modeBeforePriority = currentMode;
      _redTimeBeforePriority = red;
      _greenTimeBeforePriority = green;
      _yellowTimeBeforePriority = yellow;
    }

    redTime = red;
    greenTime = green;
    yellowTime = yellow;

    priorityMode = false;
    nightMode = false;
    nightModeManual = false;

    _updateModeFromTimes();

    _delayedReset();

    if (onPublishCommand != null) {
      onPublishCommand?.call('R${red}G${green}Y${yellow}');
    }

    onShowMessage?.call("⚙️ Cấu hình: $red-$green-$yellow", Colors.teal);
    notifyListeners();
  }

  void processFirmwareStatus(String message) {
    if (!_isSyncedWithFirmware) return;

    if (message.startsWith("STATUS|")) {
      if (message.contains("NIGHT_MODE_AUTO_ON")) {
        nightMode = true;
        nightModeManual = false;
        priorityMode = false;
        priorityId = -1;
        _updateModeFromTimes();
        onShowMessage?.call("🌙 Cảm biến: Trời tối - Vào chế độ ban đêm", Colors.indigo);
        notifyListeners();

      } else if (message.contains("NIGHT_MODE_AUTO_OFF")) {
        nightMode = false;
        nightModeManual = false;

        _resetImmediately();

        _updateModeFromTimes();
        onShowMessage?.call("☀️ Cảm biến: Trời sáng", Colors.amber);

      } else if (message.contains("NIGHT_MODE_MANUAL_ON")) {
        nightMode = true;
        nightModeManual = true;
        priorityMode = false;
        priorityId = -1;
        _updateModeFromTimes();
        onShowMessage?.call("🌙 Chế độ ban đêm (thủ công)", Colors.indigo);

      } else if (message.contains("NIGHT_MODE_MANUAL_OFF")) {
        nightMode = false;
        nightModeManual = false;

        if (redTime == 15 && greenTime == 10 && yellowTime == 5) {
          _resetImmediately();
        } else if (redTime == 30 && greenTime == 25 && yellowTime == 5) {
          _resetImmediately();
        } else if (redTime == 12 && greenTime == 10 && yellowTime == 2) {
          _resetImmediately();
        } else {
          if (onPublishCommand != null) {
            onPublishCommand?.call('STATUS');
          }
        }

        _updateModeFromTimes();
        onShowMessage?.call("☀️ Tắt chế độ ban đêm", Colors.amber);

      } else if (message.contains("PRIORITY_")) {
        int id = int.tryParse(message.substring(9)) ?? -1;
        if (id >= 0 && id <= 3) {
          if (!nightMode) {
            priorityMode = true;
            nightMode = false;
            nightModeManual = false;
            priorityId = id;
            _updateModeFromTimes();

            for (int i = 0; i < 4; i++) {
              if (i == id) {
                states[i] = "green";
              } else {
                states[i] = "red";
              }
            }
            onShowMessage?.call("🚑 Cảm biến: Xe ưu tiên hướng ${id + 1}", Colors.red);
          } else {
            print("Đang ở chế độ ban đêm, bỏ qua xe ưu tiên");
          }
        }
      }
    } else if (message.startsWith("ONLINE")) {
      onShowMessage?.call("🟢 Sa Bàn Đã Kết Nối", Colors.green);
    } else if (message.startsWith("ACK:")) {
      print("ACK received: $message");
    }
  }

  void updateFromJson(Map<String, dynamic> json) {
    if (!_isSyncedWithFirmware) return;

    try {
      if (json.containsKey('states') && json.containsKey('counters')) {
        List<dynamic> jsonStates = json['states'];
        List<dynamic> jsonCounters = json['counters'];

        if (jsonStates.length == 4 && jsonCounters.length == 4) {
          states = List<String>.from(jsonStates);
          counters = List<int>.from(jsonCounters.map((e) => e is int ? e : int.tryParse(e.toString()) ?? 0));
        }
      }

      if (json.containsKey('green_time')) {
        greenTime = json['green_time'] is int ? json['green_time'] : int.tryParse(json['green_time'].toString()) ?? greenTime;
      }
      if (json.containsKey('yellow_time')) {
        yellowTime = json['yellow_time'] is int ? json['yellow_time'] : int.tryParse(json['yellow_time'].toString()) ?? yellowTime;
      }
      if (json.containsKey('red_time')) {
        redTime = json['red_time'] is int ? json['red_time'] : int.tryParse(json['red_time'].toString()) ?? redTime;
      }

      if (json.containsKey('night_mode')) {
        nightMode = json['night_mode'] == true || json['night_mode'] == 1;
      }

      if (json.containsKey('priority_mode')) {
        priorityMode = json['priority_mode'] == true || json['priority_mode'] == 1;
      }

      if (json.containsKey('priority_id')) {
        priorityId = json['priority_id'] is int ? json['priority_id'] : int.tryParse(json['priority_id'].toString()) ?? -1;
      }

      if (json.containsKey('mode')) {
        String mode = json['mode'];
        if (nightMode) {
          if (nightModeManual) {
            currentMode = "🌙 Ban đêm (thủ công)";
          } else {
            currentMode = "🌙 Ban đêm";
          }
        } else if (priorityMode) {
          currentMode = "🚑 Ưu tiên hướng ${priorityId + 1}";
        } else {
          switch (mode) {
            case 'normal':
              currentMode = "🚗 Bình thường";
              break;
            case 'peak':
              currentMode = "🚙 Đông xe";
              break;
            case 'low':
              currentMode = "🚲 Ít xe";
              break;
            case 'custom':
              currentMode = "⚙️ Tùy chỉnh";
              break;
            default:
              _updateModeFromTimes();
          }
        }
      } else {
        _updateModeFromTimes();
      }

      print('✅ Cập nhật trạng thái từ firmware thành công');
      notifyListeners();
    } catch (e) {
      print('❌ Lỗi cập nhật từ JSON: $e');
    }
  }

  void setSyncedWithFirmware(bool synced) {
    if (_isSyncedWithFirmware != synced) {
      _isSyncedWithFirmware = synced;
      if (synced) {
        onShowMessage?.call("🔄 Đã đồng bộ với firmware", Colors.green);
      } else {
        onShowMessage?.call("🔄 Chạy chế độ local", Colors.orange);
      }
      notifyListeners();
    }
  }

  void _updateStateMachine() {
    if (_isWaitingForSync) {
      return;
    }

    if (nightMode) {
      nightBlink = !nightBlink;
    } else if (priorityMode) {
      priorityBlink = !priorityBlink;
    } else {
      for (int i = 0; i < 4; i++) {
        counters[i]--;

        if (counters[i] <= 0) {
          switch (states[i]) {
            case "green":
              states[i] = "yellow";
              counters[i] = yellowTime;
              break;
            case "yellow":
              states[i] = "red";
              counters[i] = redTime;
              break;
            case "red":
              states[i] = "green";
              counters[i] = greenTime;
              break;
          }
        }
      }
    }
    notifyListeners();
  }

  void _resetSystem() {
    states = ["green", "red", "green", "red"];
    counters = [greenTime, redTime, greenTime, redTime];
    notifyListeners();
  }

  bool isRed(int index) => !nightMode && !priorityMode && states[index] == "red";
  bool isYellow(int index) => !nightMode && !priorityMode && states[index] == "yellow";
  bool isGreen(int index) => !nightMode && !priorityMode && states[index] == "green";

  bool isNightYellow() => nightMode && nightBlink;
  bool isPriorityGreen(int index) => priorityMode && index == priorityId && priorityBlink;
  bool isPriorityRed(int index) => priorityMode && index != priorityId && priorityBlink;

  String getCounterText(int index) {
    if (_isWaitingForSync || nightMode || priorityMode) return "--";
    return counters[index].toString();
  }

  void resetToNormalModeOnFirmwareOnline() {
    print("🚗 Reset to normal mode (firmware online)");

    redTime = 15;
    greenTime = 10;
    yellowTime = 5;

    priorityMode = false;
    nightMode = false;
    nightModeManual = false;

    _updateModeFromTimes();
    _delayedReset();

    onShowMessage?.call("✅ Reset chế độ bình thường", Colors.green);
    notifyListeners();
  }

  void disposeTimer() {
    timer?.cancel();
    _syncDelayTimer?.cancel();
  }
}

// ==================== UI ====================
class TrafficHome extends StatefulWidget {
  const TrafficHome({super.key});

  @override
  State<TrafficHome> createState() => _TrafficHomeState();
}

class _TrafficHomeState extends State<TrafficHome>
    with SingleTickerProviderStateMixin {
  late TrafficLogic _logic;
  late AnimationController _skyController;
  late Animation<double> _sunMoonPosition;
  late Animation<double> _starOpacity;

  late MQTTManager _mqttManager;
  bool _mqttConnected = false;

  bool _firmwareConnected = false;

  DateTime _lastFirmwareMessage = DateTime.now();
  final Duration _firmwareTimeout = const Duration(seconds: 6);
  Timer? _firmwareCheckTimer;

  @override
  void initState() {
    super.initState();
    _logic = TrafficLogic();
    _logic.onShowMessage = _showSnackBar;

    _logic.onPublishCommand = (command) {
      _mqttManager.publishCommand(command);
    };

    _mqttManager = MQTTManager();
    _mqttManager.onConnected = () {
      if (mounted) {
        setState(() {
          _mqttConnected = true;
        });
        _showSnackBar('✅ Kết nối MQTT thành công', Colors.green);

        _logic.resetToNormalModeOnFirmwareOnline();
        _mqttManager.publishCommand('N');
      }
    };

    _mqttManager.onDisconnected = () {
      if (mounted) {
        setState(() {
          _mqttConnected = false;
          _firmwareConnected = false;
        });
        _logic.setSyncedWithFirmware(false);
        _showSnackBar('🔌 Mất kết nối MQTT', Colors.orange);
      }
    };

    _mqttManager.onMessageReceived = (message) {
      _lastFirmwareMessage = DateTime.now();

      if (message.startsWith("ONLINE")) {
        if (!_firmwareConnected) {
          setState(() {
            _firmwareConnected = true;
          });
          _logic.setSyncedWithFirmware(true);
          _logic.resetToNormalModeOnFirmwareOnline();
          _syncCurrentStateToFirmware();
        }
      }
      _logic.processFirmwareStatus(message);
    };

    _mqttManager.onStatusReceived = (json) {
      _lastFirmwareMessage = DateTime.now();
      _logic.updateFromJson(json);
    };

    _connectMQTT();

    _skyController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat(reverse: true);

    _sunMoonPosition = Tween<double>(begin: -0.3, end: 1.3).animate(
      CurvedAnimation(parent: _skyController, curve: Curves.easeInOutSine),
    );

    _starOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _skyController, curve: Curves.easeInOut),
    );

    _startFirmwareCheckTimer();
  }

  void _startFirmwareCheckTimer() {
    _firmwareCheckTimer?.cancel();
    _firmwareCheckTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _checkFirmwareConnection();
    });
  }

  void _checkFirmwareConnection() {
    if (!_mqttConnected) {
      if (_firmwareConnected) {
        setState(() {
          _firmwareConnected = false;
        });
        _logic.setSyncedWithFirmware(false);
      }
      return;
    }

    final now = DateTime.now();
    final difference = now.difference(_lastFirmwareMessage);

    if (_firmwareConnected && difference > _firmwareTimeout) {
      setState(() {
        _firmwareConnected = false;
      });
      _logic.setSyncedWithFirmware(false);
      _showSnackBar('⏹️ Mất kết nối với firmware', Colors.orange, duration: 1);
    } else if (!_firmwareConnected && difference <= _firmwareTimeout) {
      setState(() {
        _firmwareConnected = true;
      });
      _logic.setSyncedWithFirmware(true);
    }
  }

  void _syncCurrentStateToFirmware() {
    if (!_mqttConnected || !_firmwareConnected) return;

    if (_logic.nightMode) {
      if (_logic.nightModeManual) {
        _mqttManager.publishCommand('NM');
      } else {
        if (_logic.redTime == 15 && _logic.greenTime == 10 && _logic.yellowTime == 5) {
          _mqttManager.publishCommand('N');
        } else if (_logic.redTime == 30 && _logic.greenTime == 25 && _logic.yellowTime == 5) {
          _mqttManager.publishCommand('P');
        } else if (_logic.redTime == 12 && _logic.greenTime == 10 && _logic.yellowTime == 2) {
          _mqttManager.publishCommand('L');
        } else {
          _mqttManager.publishCommand('R${_logic.redTime}G${_logic.greenTime}Y${_logic.yellowTime}');
        }
      }
    } else if (_logic.priorityMode) {
      _mqttManager.publishCommand('P${_logic.priorityId}');
    } else {
      if (_logic.redTime == 15 && _logic.greenTime == 10 && _logic.yellowTime == 5) {
        _mqttManager.publishCommand('N');
      } else if (_logic.redTime == 30 && _logic.greenTime == 25 && _logic.yellowTime == 5) {
        _mqttManager.publishCommand('P');
      } else if (_logic.redTime == 12 && _logic.greenTime == 10 && _logic.yellowTime == 2) {
        _mqttManager.publishCommand('L');
      } else {
        _mqttManager.publishCommand('R${_logic.redTime}G${_logic.greenTime}Y${_logic.yellowTime}');
      }
    }
  }

  Future<void> _connectMQTT() async {
    bool connected = await _mqttManager.connect();
    if (!connected && mounted) {
      Future.delayed(const Duration(seconds: 10), () {
        if (mounted) {
          _connectMQTT();
        }
      });
    }
  }

  void _showSnackBar(String message, Color color, {int duration = 2}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(
            fontSize: getResponsiveFontSize(context, 14),
          ),
        ),
        backgroundColor: color,
        duration: Duration(seconds: duration),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  void dispose() {
    _firmwareCheckTimer?.cancel();
    _logic.disposeTimer();
    _logic.dispose();
    _skyController.dispose();
    _mqttManager.disconnect();
    super.dispose();
  }

  void showModeConfirmDialog(String mode) {
    String title = "";
    String content = "";
    VoidCallback action;

    if (mode == "normal") {
      title = "🚗 Xác nhận chế độ Bình thường?";
      content = "Hệ thống sẽ hoạt động với thời gian mặc định.";
      action = () => _logic.activateNormalMode();
    } else if (mode == "peak") {
      title = "🚙 Xác nhận chế độ Đông xe?";
      content = "Thời gian đèn sẽ tăng để phù hợp giờ cao điểm.";
      action = () => _logic.activatePeakMode();
    } else {
      title = "🚲 Xác nhận chế độ Ít xe?";
      content = "Thời gian đèn sẽ giảm khi lưu lượng thấp.";
      action = () => _logic.activateLowMode();
    }

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(
          title,
          style: TextStyle(
            fontSize: getResponsiveFontSize(context, 18),
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              content,
              style: TextStyle(
                fontSize: getResponsiveFontSize(context, 16),
              ),
            ),
            if (!_mqttConnected)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '⚠️ MQTT chưa kết nối - Chỉ điều khiển local',
                  style: TextStyle(
                    color: Colors.orange,
                    fontSize: getResponsiveFontSize(context, 14),
                  ),
                ),
              )
            else if (!_firmwareConnected)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '⏳ Đang chờ kết nối sa bàn...',
                  style: TextStyle(
                    color: Colors.blue,
                    fontSize: getResponsiveFontSize(context, 14),
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '✅ Đã đồng bộ với sa bàn',
                  style: TextStyle(
                    color: Colors.green,
                    fontSize: getResponsiveFontSize(context, 14),
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              "Hủy",
              style: TextStyle(
                fontSize: getResponsiveFontSize(context, 16),
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              action();
            },
            child: Text(
              "Xác nhận",
              style: TextStyle(
                fontSize: getResponsiveFontSize(context, 16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void showPriorityDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(
          "🚑 Chọn hướng ưu tiên",
          style: TextStyle(
            fontSize: getResponsiveFontSize(context, 18),
            fontWeight: FontWeight.bold,
          ),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_mqttConnected)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '⚠️ MQTT chưa kết nối - Chỉ điều khiển local',
                    style: TextStyle(
                      color: Colors.orange,
                      fontSize: getResponsiveFontSize(context, 14),
                    ),
                  ),
                )
              else if (!_firmwareConnected)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '⏳ Đang chờ kết nối sa bàn...',
                    style: TextStyle(
                      color: Colors.blue,
                      fontSize: getResponsiveFontSize(context, 14),
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '✅ Đã đồng bộ với sa bàn',
                    style: TextStyle(
                      color: Colors.green,
                      fontSize: getResponsiveFontSize(context, 14),
                    ),
                  ),
                ),
              for (int i = 0; i < 4; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        _logic.activatePriorityMode(i);
                        Navigator.pop(context);
                      },
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: Text(
                        "Hướng ${i + 1}",
                        style: TextStyle(
                          fontSize: getResponsiveFontSize(context, 16),
                        ),
                      ),
                    ),
                  ),
                ),
              if (_logic.priorityMode)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.grey,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () {
                        _logic.exitPriorityMode();
                        Navigator.pop(context);
                      },
                      child: Text(
                        "❌ Thoát ưu tiên",
                        style: TextStyle(
                          fontSize: getResponsiveFontSize(context, 16),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void showCustomDialog() {
    TextEditingController redController = TextEditingController(
      text: _logic.redTime.toString(),
    );
    TextEditingController greenController = TextEditingController(
      text: _logic.greenTime.toString(),
    );
    TextEditingController yellowController = TextEditingController(
      text: _logic.yellowTime.toString(),
    );

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(
          "⚙️ Tùy chỉnh thời gian",
          style: TextStyle(
            fontSize: getResponsiveFontSize(context, 18),
            fontWeight: FontWeight.bold,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              buildInput("🔴 Đỏ (giây)", redController),
              const SizedBox(height: 8),
              buildInput("🟢 Xanh (giây)", greenController),
              const SizedBox(height: 8),
              buildInput("🟡 Vàng (giây)", yellowController),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.shade200),
                ),
                child: Text(
                  "Điều kiện: Đỏ = Xanh + Vàng",
                  style: TextStyle(
                    fontSize: getResponsiveFontSize(context, 14),
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              if (!_mqttConnected)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '⚠️ MQTT chưa kết nối',
                    style: TextStyle(
                      color: Colors.orange,
                      fontSize: getResponsiveFontSize(context, 14),
                    ),
                  ),
                )
              else if (!_firmwareConnected)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '⏳ Đang chờ kết sa bàn...',
                    style: TextStyle(
                      color: Colors.blue,
                      fontSize: getResponsiveFontSize(context, 14),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              "Hủy",
              style: TextStyle(
                fontSize: getResponsiveFontSize(context, 16),
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              int r = int.tryParse(redController.text) ?? 0;
              int g = int.tryParse(greenController.text) ?? 0;
              int y = int.tryParse(yellowController.text) ?? 0;

              _logic.activateCustomMode(r, g, y);
              Navigator.pop(context);
            },
            child: Text(
              "Áp dụng",
              style: TextStyle(
                fontSize: getResponsiveFontSize(context, 16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void showNightConfirmDialog() {
    bool tempNightModeManual = _logic.nightModeManual;

    showDialog(
        context: context,
        builder: (_) => StatefulBuilder(
            builder: (context, setState) {
              return AlertDialog(
                insetPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 24),
                title: Text(
                  "🌙 Chế độ ban đêm",
                  style: TextStyle(
                    fontSize: getResponsiveFontSize(context, 18),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                content: SizedBox(
                  width: MediaQuery
                      .of(context)
                      .size
                      .width,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Chọn chế độ hoạt động:",
                        style: TextStyle(
                          fontSize: getResponsiveFontSize(context, 16),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: tempNightModeManual
                                    ? Colors.indigo.withOpacity(0.1)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 8),
                                child: Row(
                                  children: [
                                    Icon(
                                      tempNightModeManual
                                          ? Icons.nights_stay
                                          : Icons.nights_stay_outlined,
                                      color: tempNightModeManual
                                          ? Colors.indigo
                                          : Colors.grey,
                                      size: 22,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment: CrossAxisAlignment
                                            .start,
                                        children: [
                                          Text(
                                            '🌙 Thủ công',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w500,
                                              fontSize: getResponsiveFontSize(
                                                  context, 15),
                                              color: tempNightModeManual
                                                  ? Colors.indigo
                                                  : Colors.black87,
                                            ),
                                          ),
                                          Text(
                                            tempNightModeManual
                                                ? 'Đang bật - Điều khiển từ xa bằng tay'
                                                : 'Đang tắt - Sử dụng switch để bật/tắt',
                                            style: TextStyle(
                                              fontSize: getResponsiveFontSize(
                                                  context, 13),
                                              color: tempNightModeManual
                                                  ? Colors.indigo
                                                  : Colors.grey.shade600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Switch(
                                      value: tempNightModeManual,
                                      onChanged: (value) {
                                        setState(() {
                                          tempNightModeManual = value;
                                        });
                                      },
                                      activeColor: Colors.indigo,
                                      activeTrackColor: Colors.indigo
                                          .withOpacity(0.5),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            const Divider(),

                            ListTile(
                              leading: const Icon(
                                  Icons.autorenew, color: Colors.green),
                              title: Text(
                                '🔄 Đồng bộ',
                                style: TextStyle(
                                  fontSize: getResponsiveFontSize(context, 16),
                                ),
                              ),
                              subtitle: Text(
                                'Đồng bộ theo cảm biến ánh sáng',
                                style: TextStyle(
                                  fontSize: getResponsiveFontSize(context, 14),
                                ),
                              ),
                              onTap: () {
                                if (_mqttConnected) {
                                  _mqttManager.publishCommand('NA');
                                  _showSnackBar(
                                      '🔄 Đã chuyển sang chế độ tự động',
                                      Colors.green);
                                } else {
                                  _showSnackBar(
                                      '⚠️ MQTT chưa kết nối', Colors.orange);
                                }
                                Navigator.pop(context);
                              },
                            ),
                          ],
                        ),
                      ),

                      if (tempNightModeManual != _logic.nightModeManual)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: () {
                                if (tempNightModeManual) {
                                  _logic.activateNightModeManual();
                                } else {
                                  _logic.deactivateNightModeManual();
                                }
                                Navigator.pop(context);
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.indigo,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: Text(
                                tempNightModeManual
                                    ? "BẬT CHẾ ĐỘ THỦ CÔNG"
                                    : "TẮT CHẾ ĐỘ THỦ CÔNG",
                                style: TextStyle(
                                  fontSize: getResponsiveFontSize(context, 16),
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),

                      const SizedBox(height: 8),

                      if (!_mqttConnected)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '⚠️ MQTT chưa kết nối - Chỉ điều khiển local',
                            style: TextStyle(
                              color: Colors.orange,
                              fontSize: getResponsiveFontSize(context, 14),
                            ),
                          ),
                        )
                      else
                        if (!_firmwareConnected)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              '⏳ Đang chờ kết nối sa bàn...',
                              style: TextStyle(
                                color: Colors.blue,
                                fontSize: getResponsiveFontSize(context, 14),
                              ),
                            ),
                          ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      "Đóng",
                      style: TextStyle(
                        fontSize: getResponsiveFontSize(context, 16),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
    }

            void showInfoDialog() {
    showDialog(
    context: context,
    builder: (_) => Dialog(
    insetPadding: const EdgeInsets.all(20),
    backgroundColor: Colors.transparent,
    child: ClipRRect(
    borderRadius: BorderRadius.circular(30),
    child: BackdropFilter(
    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
    child: Container(
    width: double.infinity,
    constraints: const BoxConstraints(maxHeight: 600),
    decoration: BoxDecoration(
    gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: _logic.nightMode
    ? [Colors.indigo.shade900.withOpacity(0.5), Colors.purple.shade900.withOpacity(0.5)]
        : [Colors.blue.shade50.withOpacity(0.5), Colors.white.withOpacity(0.5)],
    ),
    borderRadius: BorderRadius.circular(30),
    ),
    child: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
    Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
    gradient: LinearGradient(
    colors: _logic.nightMode
    ? [Colors.indigo.shade800.withOpacity(0.7), Colors.purple.shade800.withOpacity(0.7)]
        : [Colors.blue.shade600.withOpacity(0.7), Colors.cyan.shade700.withOpacity(0.7)],
    ),
    borderRadius: const BorderRadius.only(
    topLeft: Radius.circular(30),
    topRight: Radius.circular(30),
    ),
    ),
    child: Row(
    children: [
    Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
    color: Colors.white.withOpacity(0.2),
    shape: BoxShape.circle,
    ),
    child: const Icon(
    Icons.info_outline,
    color: Colors.white,
    size: 28,
    ),
    ),
    const SizedBox(width: 12),
    Expanded(
    child: Text(
    "VỀ ỨNG DỤNG",
    style: TextStyle(
    fontSize: getResponsiveFontSize(context, 22),
    fontWeight: FontWeight.bold,
    color: Colors.white,
    letterSpacing: 1.2,
    ),
    ),
    ),
    Container(
    decoration: BoxDecoration(
    color: Colors.white.withOpacity(0.2),
    shape: BoxShape.circle,
    ),
    child: IconButton(
    icon: const Icon(Icons.close, color: Colors.white),
    onPressed: () => Navigator.pop(context),
    ),
    ),
    ],
    ),
    ),

    Expanded(
    child: SingleChildScrollView(
    padding: const EdgeInsets.all(20),
    child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
    Center(
    child: Column(
    children: [
    Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
    color: _logic.nightMode
    ? Colors.amber.withOpacity(0.2)
        : Colors.blue.withOpacity(0.1),
    shape: BoxShape.circle,
    ),
    child: Icon(
    Icons.traffic,
    size: 60,
    color: _logic.nightMode
    ? Colors.amber
        : Colors.blue.shade700,
    ),
    ),
    const SizedBox(height: 16),
    Text(
    "🚦 MÔ HÌNH ĐÈN GIAO THÔNG 🚦",
    style: TextStyle(
    fontSize: getResponsiveFontSize(context, 18),
    fontWeight: FontWeight.bold,
    color: _logic.nightMode
    ? Colors.amber
        : Colors.blue.shade700,
    ),
    textAlign: TextAlign.center,
    ),
    const SizedBox(height: 8),
    Text(
    "Ứng dụng học tập về an toàn giao thông",
    style: TextStyle(
    fontSize: getResponsiveFontSize(context, 16),
    color: Colors.grey,
    ),
    ),
    ],
    ),
    ),

    const SizedBox(height: 30),
    const Divider(),
    const SizedBox(height: 20),

    _buildInfoSection(
    icon: Icons.info,
    title: "Giới thiệu",
    content:
    "Ứng dụng này mô phỏng hệ thống đèn giao thông."
    "Giúp học sinh hiểu cách các đèn giao thông hoạt động"
    "và học về an toàn khi tham gia giao thông.\n\n"
    "Phiên bản: 2.0\n"
    "Phát hành: 03/2026\n"
    "Phát triển bởi: Liên Hiệp Bắc Nam",
    ),

    const SizedBox(height: 20),

    _buildInfoSection(
    icon: Icons.traffic,
    title: "Ý nghĩa đèn giao thông",
    content:
    "🔴 Đèn đỏ: Dừng lại\n"
    "🟡 Đèn vàng: Chuẩn bị dừng\n"
    "🟢 Đèn xanh: Được phép đi\n\n"
    "Hãy luôn tuân thủ đèn giao thông để đảm bảo an toàn.",
    ),

    const SizedBox(height: 20),

    _buildInfoSection(
    icon: Icons.settings,
    title: "Các chế độ hoạt động",
    content:
    "🚗 Bình thường\n"
    "Đèn hoạt động theo thời gian tiêu chuẩn.\n"
    "🚙 Đông xe\n"
    "Đèn xanh lâu hơn để nhiều xe đi qua.\n"
    "🚲 Ít xe\n"
    "Thời gian đèn ngắn hơn.\n"
    "🚑 Xe ưu tiên\n"
    "Cho xe cứu thương hoặc xe cứu hỏa đi trước.\n"
    "🌙 Ban đêm\n"
    "Đèn vàng nhấp nháy để cảnh báo.",
    ),

    const SizedBox(height: 20),

    _buildInfoSection(
    icon: Icons.wifi,
    title: "Trạng thái hệ thống",
    content:
    "🟢 Đã với sa bàn giao thông.\n"
    "🟠 Chưa kết nối với sa bàn giao thông.\n"
    "🔴 Chưa kết nối với hệ thống.",
    ),
    ],
    ),
    ),
    ),

    Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
    border: Border(
    top: BorderSide(color: Colors.grey.withOpacity(0.2)),
    ),
    ),
    child: Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
    Icon(
    Icons.favorite,
    size: 16,
    color: _logic.nightMode ? Colors.amber : Colors.red,
    ),
    const SizedBox(width: 8),
    Text(
    "Chúc bạn học tập vui vẻ!",
    style: TextStyle(
    fontSize: getResponsiveFontSize(context, 14),
    color: Colors.grey,
    ),
    ),
    const SizedBox(width: 8),
    Icon(
    Icons.favorite,
    size: 16,
    color: _logic.nightMode ? Colors.amber : Colors.red,
    ),
    ],
    ),
    ),
    ],
    ),
    ),
    ),
    ),
    ),
    );
    }

        Widget _buildInfoSection({
    required IconData icon,
    required String title,
    required String content,
    }) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _logic.nightMode
              ? Colors.indigo.shade900.withOpacity(0.1)
              : Colors.white.withOpacity(0.2),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _logic.nightMode
                ? Colors.amber.withOpacity(0.2)
                : Colors.blue.withOpacity(0.2),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: _logic.nightMode
                        ? Colors.amber.withOpacity(0.2)
                        : Colors.blue.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    icon,
                    size: 18,
                    color: _logic.nightMode ? Colors.amber : Colors.blue.shade700,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: getResponsiveFontSize(context, 16),
                    fontWeight: FontWeight.bold,
                    color: _logic.nightMode ? Colors.amber : Colors.blue.shade700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              content,
              style: TextStyle(
                fontSize: getResponsiveFontSize(context, 14),
                height: 1.5,
                color: _logic.nightMode ? Colors.white : Colors.black87,
              ),
            ),
          ],
        ),
      );
    }

    Widget buildSky() {
      return AnimatedBuilder(
        animation: _skyController,
        builder: (context, child) {
          return Stack(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 800),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: _logic.nightMode
                        ? [
                      Color.lerp(
                        Colors.indigo.shade900,
                        Colors.black,
                        _sunMoonPosition.value * 0.5,
                      )!,
                      Color.lerp(
                        Colors.purple.shade900,
                        Colors.indigo.shade900,
                        _sunMoonPosition.value * 0.3,
                      )!,
                    ]
                        : [
                      Color.lerp(
                        Colors.lightBlue.shade200,
                        Colors.orange.shade200,
                        _sunMoonPosition.value * 0.7,
                      )!,
                      Color.lerp(
                        Colors.white,
                        Colors.lightBlue.shade100,
                        _sunMoonPosition.value * 0.5,
                      )!,
                    ],
                  ),
                ),
              ),

              if (_logic.nightMode)
                ...List.generate(50, (index) {
                  final randomX = (index * 17) % 100 / 100;
                  final randomY = (index * 23) % 100 / 100;
                  final randomSize = 1.0 + (index % 3) * 0.5;
                  final randomOpacity = 0.3 + (index % 7) / 10;

                  return Positioned(
                    left: MediaQuery.of(context).size.width * randomX,
                    top: MediaQuery.of(context).size.height * randomY * 0.6,
                    child: Opacity(
                      opacity: _starOpacity.value * randomOpacity *
                          (0.5 + 0.5 * (_logic.nightBlink ? 1 : 0.5)),
                      child: Container(
                        width: randomSize,
                        height: randomSize,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.white.withOpacity(0.5),
                              blurRadius: randomSize,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),

              Positioned(
                left: MediaQuery.of(context).size.width * _sunMoonPosition.value - 30,
                top: 20 + (1 - _sunMoonPosition.value) * 30,
                child: Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: _logic.nightMode
                          ? [
                        Colors.grey.shade300,
                        Colors.grey.shade500,
                        Colors.grey.shade700,
                      ]
                          : [
                        Colors.yellow.shade300,
                        Colors.orange.shade400,
                        Colors.orange.shade600,
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: _logic.nightMode
                            ? Colors.grey.shade300.withOpacity(0.3)
                            : Colors.orange.withOpacity(0.5),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: _logic.nightMode
                      ? Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned(
                        top: 8,
                        left: 12,
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 12,
                        right: 8,
                        child: Container(
                          width: 15,
                          height: 15,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                    ],
                  )
                      : null,
                ),
              ),

              if (!_logic.nightMode)
                ...List.generate(3, (index) {
                  final cloudOffset = (index * 40 + _skyController.value * 200) %
                      (MediaQuery.of(context).size.width + 100) -
                      100;

                  return Positioned(
                    left: cloudOffset,
                    top: 60 + index * 20.0,
                    child: Opacity(
                      opacity: 0.3 + index * 0.1,
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 20,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.6),
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          Container(
                            width: 30,
                            height: 25,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.6),
                              borderRadius: BorderRadius.circular(15),
                            ),
                          ),
                          Container(
                            width: 35,
                            height: 18,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.6),
                              borderRadius: BorderRadius.circular(9),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
            ],
          );
        },
      );
    }

    Widget buildStreetLight(double intersectionSize) {
      final double headSize = intersectionSize * 0.06;
      final double poleHeight = intersectionSize * 0.065;
      final double poleWidth = intersectionSize * 0.015;
      final double baseWidth = intersectionSize * 0.03;
      final double baseHeight = intersectionSize * 0.01;

      return AnimatedOpacity(
        duration: const Duration(milliseconds: 800),
        opacity: _logic.nightMode ? 1 : 0.3,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: headSize,
              height: headSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _logic.nightMode ? Colors.amber : Colors.grey.shade400,
                boxShadow: _logic.nightMode
                    ? [
                  BoxShadow(
                    color: Colors.amber.withOpacity(0.6),
                    blurRadius: headSize * 0.5,
                    spreadRadius: headSize * 0.125,
                  ),
                  BoxShadow(
                    color: Colors.yellow.withOpacity(0.3),
                    blurRadius: headSize * 0.8,
                    spreadRadius: headSize * 0.2,
                  ),
                ]
                    : [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: headSize * 0.15,
                    spreadRadius: headSize * 0.04,
                  ),
                ],
              ),
              child: Icon(
                _logic.nightMode ? Icons.light_rounded : Icons.light_outlined,
                size: headSize * 0.65,
                color: _logic.nightMode ? Colors.white : Colors.black87,
              ),
            ),
            Container(
              width: poleWidth,
              height: poleHeight,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.grey.shade700,
                    Colors.grey.shade900,
                    Colors.grey.shade800,
                  ],
                ),
                borderRadius: BorderRadius.circular(poleWidth * 0.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: poleWidth * 0.3,
                    offset: Offset(poleWidth * 0.15, poleWidth * 0.15),
                  ),
                ],
              ),
            ),
            Container(
              width: baseWidth,
              height: baseHeight,
              decoration: BoxDecoration(
                color: Colors.grey.shade900,
                borderRadius: BorderRadius.circular(baseHeight * 0.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.5),
                    blurRadius: baseHeight * 0.5,
                    offset: Offset(0, baseHeight * 0.25),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    Widget buildZebraCrossing({
      required double top,
      required double left,
      required double width,
      required double height,
      required bool isVertical,
    }) {
      final int stripeCount =
      (isVertical ? height / 8 : width / 8).floor();
      final double stripeSize = 4.0;
      final Color stripeColor = Colors.white.withOpacity(0.6);

      return Positioned(
        top: top,
        left: left,
        child: Container(
          width: width,
          height: height,
          child: isVertical
              ? Column(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(
              stripeCount,
                  (_) => Container(width: width, height: stripeSize, color: stripeColor),
            ),
          )
              : Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(
              stripeCount,
                  (_) => Container(width: stripeSize, height: height, color: stripeColor),
            ),
          ),
        ),
      );
    }

    Widget buildLight(Color color, bool active) {
      return AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? color : Colors.grey.shade800,
          boxShadow: active
              ? [
            BoxShadow(
              color: color.withOpacity(0.5),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ]
              : null,
        ),
      );
    }

    Widget buildTrafficLight(int index) {
      bool isRed = _logic.isRed(index) ||
          (_logic.nightMode && false) ||
          (_logic.priorityMode && index != _logic.priorityId && _logic.priorityBlink);

      bool isYellow = _logic.isYellow(index) ||
          (_logic.nightMode && _logic.nightBlink) ||
          false;

      bool isGreen = _logic.isGreen(index) ||
          (_logic.priorityMode && index == _logic.priorityId && _logic.priorityBlink) ||
          false;

      if (_logic.nightMode) {
        isRed = false;
        isGreen = false;
        isYellow = _logic.nightBlink;
      }

      if (_logic.priorityMode) {
        if (index == _logic.priorityId) {
          isGreen = _logic.priorityBlink;
          isRed = false;
          isYellow = false;
        } else {
          isRed = _logic.priorityBlink;
          isGreen = false;
          isYellow = false;
        }
      }

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade700, width: 1.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                buildLight(Colors.red, isRed),
                const SizedBox(width: 4),
                buildLight(Colors.amber, isYellow),
                const SizedBox(width: 4),
                buildLight(Colors.green, isGreen),
              ],
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.grey.shade800),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  _logic.getCounterText(index),
                  style: TextStyle(
                    fontSize: getResponsiveFontSize(context, 12),
                    fontWeight: FontWeight.bold,
                    color: (_logic.nightMode || _logic.priorityMode || _logic.isSyncedWithFirmware == false)
                        ? Colors.grey
                        : Colors.cyan.shade300,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    Widget buildIntersection() {
      return LayoutBuilder(
        builder: (context, constraints) {
          double size = constraints.maxWidth;
          double roadWidth = size * 0.28;

          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: roadWidth,
                height: size,
                decoration: BoxDecoration(
                  color: Colors.grey.shade800,
                  border: Border.all(
                    color: Colors.white.withOpacity(0.2),
                    width: 1,
                  ),
                ),
              ),
              Container(
                width: size,
                height: roadWidth,
                decoration: BoxDecoration(
                  color: Colors.grey.shade800,
                  border: Border.all(
                    color: Colors.white.withOpacity(0.2),
                    width: 1,
                  ),
                ),
              ),

              // ==================== YELLOW LINES ====================
              // Top
              Positioned(
                top: 0,
                left: size / 2 - 1.5,
                child: Container(
                  color: Colors.yellow.withOpacity(0.5),
                  width: 3,
                  height: (size / 2) - (roadWidth / 2) - (roadWidth * 0.3),
                ),
              ),
              // Bottom
              Positioned(
                bottom: 0,
                left: size / 2 - 1.5,
                child: Container(
                  color: Colors.yellow.withOpacity(0.5),
                  width: 3,
                  height: (size / 2) - (roadWidth / 2) - (roadWidth * 0.3),
                ),
              ),
              // Left
              Positioned(
                left: 0,
                top: size / 2 - 1.5,
                child: Container(
                  color: Colors.yellow.withOpacity(0.5),
                  width: (size / 2) - (roadWidth / 2) - (roadWidth * 0.3),
                  height: 3,
                ),
              ),
              // Right
              Positioned(
                right: 0,
                top: size / 2 - 1.5,
                child: Container(
                  color: Colors.yellow.withOpacity(0.5),
                  width: (size / 2) - (roadWidth / 2) - (roadWidth * 0.3),
                  height: 3,
                ),
              ),

              Container(
                width: roadWidth * 0.5,
                height: roadWidth * 0.5,
                decoration: BoxDecoration(
                  color: Colors.grey.shade700,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withOpacity(0.3),
                    width: 2,
                  ),
                ),
                child: Center(
                  child: Icon(
                    Icons.traffic,
                    size: 24,
                    color: Colors.white.withOpacity(0.3),
                  ),
                ),
              ),

              // ==================== ZEBRA CROSSINGS ====================
              buildZebraCrossing(
                isVertical: false,
                width: roadWidth * 0.6,
                height: roadWidth * 0.2,
                top: (size / 2) - (roadWidth / 2) - (roadWidth * 0.2),
                left: (size / 2) - (roadWidth * 0.3),
              ),
              buildZebraCrossing(
                isVertical: false,
                width: roadWidth * 0.6,
                height: roadWidth * 0.2,
                top: (size / 2) + (roadWidth / 2),
                left: (size / 2) - (roadWidth * 0.3),
              ),
              buildZebraCrossing(
                isVertical: true,
                width: roadWidth * 0.2,
                height: roadWidth * 0.6,
                top: (size / 2) - (roadWidth * 0.3),
                left: (size / 2) - (roadWidth / 2) - (roadWidth * 0.2),
              ),
              buildZebraCrossing(
                isVertical: true,
                width: roadWidth * 0.2,
                height: roadWidth * 0.6,
                top: (size / 2) - (roadWidth * 0.3),
                left: (size / 2) + (roadWidth / 2),
              ),

              Positioned(top: 5, child: buildTrafficLight(0)),
              Positioned(right: 5, child: buildTrafficLight(1)),
              Positioned(bottom: 5, child: buildTrafficLight(2)),
              Positioned(left: 5, child: buildTrafficLight(3)),

              Align(
                alignment: const Alignment(-0.5, -0.5),
                child: buildStreetLight(size),
              ),
              Align(
                alignment: const Alignment(0.5, -0.5),
                child: buildStreetLight(size),
              ),
              Align(
                alignment: const Alignment(-0.5, 0.5),
                child: buildStreetLight(size),
              ),
              Align(
                alignment: const Alignment(0.5, 0.5),
                child: buildStreetLight(size),
              ),
            ],
          );
        },
      );
    }

    Widget buildInput(String label, TextEditingController controller) {
      return TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        style: TextStyle(
          fontSize: getResponsiveFontSize(context, 16),
        ),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(
            fontSize: getResponsiveFontSize(context, 14),
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      );
    }

    Widget _buildActionButton(
        String label,
        VoidCallback onPressed,
        Color color, {
          bool isFullWidth = false,
        }) {
      return SizedBox(
        width: isFullWidth ? double.infinity : null,
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: color,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            elevation: 2,
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              style: TextStyle(
                fontSize: getResponsiveFontSize(context, 12),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      );
    }

    @override
    Widget build(BuildContext context) {
      return Scaffold(
        body: AnimatedBuilder(
          animation: _logic,
          builder: (context, child) {
            return Stack(
              children: [
                buildSky(),

                SafeArea(
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Column(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(30),
                              child: BackdropFilter(
                                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                    horizontal: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: _logic.nightMode
                                          ? [
                                        Colors.indigo.shade800.withOpacity(0.5),
                                        Colors.purple.shade900.withOpacity(0.5),
                                      ]
                                          : [
                                        Colors.blue.shade600.withOpacity(0.5),
                                        Colors.cyan.shade700.withOpacity(0.5),
                                      ],
                                    ),
                                    borderRadius: BorderRadius.circular(30),
                                    boxShadow: [
                                      BoxShadow(
                                        color: _logic.nightMode
                                            ? Colors.black54.withOpacity(0.2)
                                            : Colors.blue.shade900.withOpacity(0.2),
                                        blurRadius: 8,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.traffic,
                                        size: 24,
                                        color: _logic.nightMode
                                            ? Colors.yellow.shade300
                                            : Colors.white,
                                      ),
                                      const SizedBox(width: 8),
                                      Flexible(
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            "🚦 NGÃ TƯ VUI VẺ 🚦",
                                            style: TextStyle(
                                              fontSize: getResponsiveFontSize(context, 16),
                                              fontWeight: FontWeight.bold,
                                              color: _logic.nightMode
                                                  ? Colors.yellow.shade300
                                                  : Colors.white,
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Icon(
                                        Icons.traffic,
                                        size: 24,
                                        color: _logic.nightMode
                                            ? Colors.yellow.shade300
                                            : Colors.white,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),

                            const SizedBox(height: 8),

                            Row(
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(30),
                                    child: BackdropFilter(
                                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 10,
                                          horizontal: 12,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.3),
                                          borderRadius: BorderRadius.circular(30),
                                          boxShadow: const [
                                            BoxShadow(
                                              color: Colors.black12,
                                              blurRadius: 4,
                                            ),
                                          ],
                                        ),
                                        child: Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            const SizedBox(width: 8),
                                            Container(
                                              width: 10,
                                              height: 10,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: _mqttConnected
                                                    ? (_firmwareConnected ? Colors.green : Colors.orange)
                                                    : Colors.red,
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: (_mqttConnected
                                                        ? (_firmwareConnected ? Colors.green : Colors.orange)
                                                        : Colors.red).withOpacity(0.5),
                                                    blurRadius: 4,
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Center(
                                                child: FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  child: Text(
                                                    _logic.currentMode,
                                                    style: TextStyle(
                                                      fontSize: getResponsiveFontSize(context, 15),
                                                      fontWeight: FontWeight.bold,
                                                      color: _logic.nightMode
                                                          ? Colors.indigo.shade900
                                                          : Colors.blue.shade900,
                                                    ),
                                                    maxLines: 1,
                                                    softWrap: false,
                                                    overflow: TextOverflow.visible,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),

                                const SizedBox(width: 8),

                                GestureDetector(
                                  onTap: showInfoDialog,
                                  child: Container(
                                    width: 42,
                                    height: 42,
                                    decoration: BoxDecoration(
                                      gradient: RadialGradient(
                                        colors: _logic.nightMode
                                            ? [
                                          Colors.amber.shade300,
                                          Colors.amber.shade700,
                                        ]
                                            : [
                                          Colors.blue.shade300,
                                          Colors.blue.shade700,
                                        ],
                                      ),
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: _logic.nightMode
                                              ? Colors.amber.withOpacity(0.5)
                                              : Colors.blue.withOpacity(0.5),
                                          blurRadius: 12,
                                          spreadRadius: 2,
                                        ),
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.2),
                                          blurRadius: 4,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                      border: Border.all(
                                        color: Colors.white.withOpacity(0.5),
                                        width: 2,
                                      ),
                                    ),
                                    child: const Center(
                                      child: Text(
                                        "i",
                                        style: TextStyle(
                                          fontSize: 28,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                          fontStyle: FontStyle.italic,
                                          shadows: [
                                            Shadow(
                                              color: Colors.black26,
                                              offset: Offset(1, 1),
                                              blurRadius: 2,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Center(
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(24),
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: _logic.nightMode
                                          ? Colors.black.withOpacity(0.1)
                                          : Colors.white.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(24),
                                      border: Border.all(
                                        color: _logic.nightMode
                                            ? Colors.amber.withOpacity(0.5)
                                            : Colors.blue.withOpacity(0.5),
                                        width: 3,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: _logic.nightMode
                                              ? Colors.amber.withOpacity(0.3)
                                              : Colors.blue.withOpacity(0.3),
                                          blurRadius: 20,
                                          spreadRadius: 2,
                                          offset: const Offset(0, 4),
                                        ),
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.2),
                                          blurRadius: 10,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(20),
                                      child: buildIntersection(),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                      ClipRRect(
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(30),
                          topRight: Radius.circular(30),
                        ),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: _logic.nightMode
                                  ? Colors.black.withOpacity(0.1)
                                  : Colors.white.withOpacity(0.1),
                              borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(30),
                                topRight: Radius.circular(30),
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: _buildActionButton(
                                        "🚗 Bình thường",
                                            () => showModeConfirmDialog("normal"),
                                        Colors.blue.shade700,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: _buildActionButton(
                                        "🚙 Đông xe",
                                            () => showModeConfirmDialog("peak"),
                                        Colors.orange.shade700,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: _buildActionButton(
                                        "🚲 Ít xe",
                                            () => showModeConfirmDialog("low"),
                                        Colors.green.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _buildActionButton(
                                        "🚑 Xe ưu tiên",
                                        showPriorityDialog,
                                        Colors.red.shade700,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: _buildActionButton(
                                        "🌙 Ban đêm",
                                        showNightConfirmDialog,
                                        Colors.indigo.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                _buildActionButton(
                                  "⚙️ Tùy chỉnh",
                                  showCustomDialog,
                                  Colors.teal.shade700,
                                  isFullWidth: true,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      );
    }
  }



////////////////////////////////////vip////

