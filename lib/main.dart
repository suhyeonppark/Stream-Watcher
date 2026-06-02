import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'discovery.dart';

const _defaultServerUrl = 'http://127.0.0.1:53683';
const _prefServerUrl = 'serverUrl';
const _prefToken = 'token';
const _prefOperateMode = 'operateMode';
const _alertChannel = MethodChannel('stream_watcher_mobile/alerts');

void main() {
  runApp(const StreamWatcherMobileApp());
}

class StreamWatcherMobileApp extends StatelessWidget {
  const StreamWatcherMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '방송 모니터링',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const MonitorScreen(),
    );
  }
}

class MonitorScreen extends StatefulWidget {
  const MonitorScreen({super.key});

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen>
    with SingleTickerProviderStateMixin {
  final _pinController = TextEditingController();
  late final AnimationController _alertFlashController;
  String? _serverUrl;
  String? _token;
  String? _lastAlertKey;
  String _message = '';
  bool _initializing = true;
  bool _busy = false;
  bool _operateMode = false;
  Map<String, dynamic>? _status;
  StreamSubscription<Map<String, dynamic>>? _eventsSub;

  StreamWatcherApi get _api =>
      StreamWatcherApi(baseUrl: _serverUrl ?? _defaultServerUrl, token: _token);

  @override
  void initState() {
    super.initState();
    _alertFlashController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _restoreSession();
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    _alertChannel.invokeMethod('stopAlertVibration').catchError((_) {});
    _alertFlashController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_prefToken);
    final serverUrl = prefs.getString(_prefServerUrl);
    final operateMode = prefs.getBool(_prefOperateMode) ?? false;
    if (token == null ||
        token.isEmpty ||
        serverUrl == null ||
        serverUrl.isEmpty) {
      if (mounted) setState(() => _initializing = false);
      return;
    }

    _token = token;
    _serverUrl = serverUrl;
    _operateMode = operateMode;
    try {
      await _loadStatus();
      _connectEvents();
    } on UnauthorizedException {
      // PC에서 페어링이 해제됨 → PIN 화면으로
      await _clearSession();
      if (mounted) {
        setState(() {
          _token = null;
          _message = 'PC에서 연결이 해제되었습니다. PIN으로 다시 연결하세요.';
        });
      }
    } catch (_) {
      // 일시적 연결 실패(PC 꺼짐/네트워크) → 세션 유지하고 대시보드에서 재연결 시도
      _connectEvents();
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  Future<void> _pair() async {
    final pin = _pinController.text.trim();
    if (pin.isEmpty) {
      setState(() => _message = 'PIN을 입력하세요.');
      return;
    }

    await _run(() async {
      setState(() => _message = 'Stream Mon 찾는 중...');
      final server = await MobileDiscoveryClient().discover();
      if (server == null) {
        throw Exception('Stream Mon을 찾지 못했습니다. PC와 같은 Wi-Fi인지 확인하세요.');
      }

      _serverUrl = server.url;
      setState(() => _message = 'PIN 확인 중...');
      final result = await _api.pair(pin, await _deviceName());
      final token = result['token'] as String?;
      _token = token;
      _message = '페어링 완료';
      try {
        await _loadStatus();
        await _saveSession();
        _connectEvents();
      } catch (_) {
        _token = null;
        rethrow;
      }
    });
  }

  Future<String> _deviceName() async {
    try {
      final name = await _alertChannel.invokeMethod<String>('getDeviceName');
      if (name != null && name.trim().isNotEmpty) return name.trim();
    } catch (_) {}
    return 'Mobile';
  }

  Future<void> _saveSession() async {
    final token = _token;
    final serverUrl = _serverUrl;
    if (token == null ||
        token.isEmpty ||
        serverUrl == null ||
        serverUrl.isEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefToken, token);
    await prefs.setString(_prefServerUrl, serverUrl);
    await prefs.setBool(_prefOperateMode, _operateMode);
  }

  Future<void> _setOperateMode(bool v) async {
    setState(() => _operateMode = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefOperateMode, v);
  }

  Future<void> _clearSession() async {
    _eventsSub?.cancel();
    _eventsSub = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefToken);
    await prefs.remove(_prefServerUrl);
    _token = null;
    _serverUrl = null;
    _status = null;
  }

  Future<void> _loadStatus() async {
    final status = await _api.status();
    if (mounted) setState(() => _status = status);
  }

  void _connectEvents() {
    _eventsSub?.cancel();
    _eventsSub = _api.events().listen(
      (event) {
        final type = event['event'];
        final data = event['data'];
        if (type == 'status' && data is Map<String, dynamic>) {
          setState(() => _status = data);
        } else if (type == 'scenario') {
          _loadStatus().catchError((_) {});
        } else if (type == 'devicesCleared' || type == 'unpaired') {
          _handleUnauthorized();
        }
      },
      onError: (_) => _scheduleReconnect(),
      onDone: () => _scheduleReconnect(),
    );
  }

  void _scheduleReconnect() {
    if (_token == null) return;
    _loadStatus().catchError((err) {
      if (err is UnauthorizedException) _handleUnauthorized();
    });
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted || _token == null) return;
      _connectEvents();
    });
  }

  void _handleUnauthorized() {
    _eventsSub?.cancel();
    _eventsSub = null;
    _alertChannel.invokeMethod('stopAlertVibration').catchError((_) {});
    _token = null;
    _serverUrl = null;
    _status = null;
    _clearSession();
    if (mounted) {
      setState(() {
        _message = 'PC에서 연결이 해제되었습니다. PIN으로 다시 연결하세요.';
      });
    }
  }

  Future<void> _setStage(int index) async {
    await _run(() async {
      await _api.setScenarioStage(index);
      await _loadStatus();
      _message = '시나리오 단계 변경됨';
    });
  }

  Future<void> _ackAlert(String? alertId) async {
    // 탭 즉시 진동 중지 (다른 알림이 남아있으면 상태 갱신 후 다시 울림)
    _alertChannel.invokeMethod('stopAlertVibration').catchError((_) {});
    await _run(() async {
      await _api.ack(alertId);
      await _loadStatus();
    });
  }

  List<Map<String, dynamic>> _activeAlerts(Map<String, dynamic>? status) {
    if (status == null) return const [];
    final list = status['activeAlerts'];
    if (list is List) {
      return list
          .whereType<Map<String, dynamic>>()
          .where((a) => a['acknowledged'] != true)
          .toList();
    }
    // 구버전 PC 호환: 단일 activeAlert
    final single = status['activeAlert'];
    if (single is Map<String, dynamic> && single['acknowledged'] != true) {
      return [single];
    }
    return const [];
  }

  void _syncAlertFlash(List<Map<String, dynamic>> alerts) {
    if (alerts.isEmpty) {
      _lastAlertKey = null;
      _alertFlashController.reset();
      // 알림이 모두 해제되면 진동 중지
      _alertChannel.invokeMethod('stopAlertVibration').catchError((_) {});
      return;
    }

    // 활성 알림 구성이 바뀌면(새 알림 추가 등) 진동/플래시 재트리거
    final key = alerts.map((a) => '${a['id']}').join(',');
    if (_lastAlertKey == key) return;
    _lastAlertKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      HapticFeedback.vibrate();
      // 탭(확인)할 때까지 진동을 계속 반복
      _alertChannel.invokeMethod('startAlertVibration').catchError((_) {});
      _alertFlashController.forward(from: 0);
    });
  }

  Future<void> _run(Future<void> Function() task) async {
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      await task();
    } catch (err) {
      _message = err.toString().replaceFirst('Exception: ', '');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final activeAlerts = _activeAlerts(status);
    _syncAlertFlash(activeAlerts);

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            if (_initializing)
              const _LoadingView()
            else if (_token == null)
              _PairingPanel(
                pinController: _pinController,
                busy: _busy,
                message: _message,
                onPair: _pair,
                operateMode: _operateMode,
                onModeToggle: _setOperateMode,
              )
            else
              ListView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                children: [
                  if (status != null) ...[
                    _DashboardHeader(
                      busy: _busy,
                      onRefresh: () => _loadStatus().catchError((_) {}),
                      operateMode: _operateMode,
                      onModeToggle: _setOperateMode,
                    ),
                    const SizedBox(height: 10),
                    _SummaryPanel(status: status),
                    const SizedBox(height: 10),
                    _StatusGrid(status: status),
                    const SizedBox(height: 10),
                    _ScenarioPanel(
                      scenario: status['scenario'] as Map<String, dynamic>?,
                      onStageTap: _setStage,
                      enabled: _operateMode,
                    ),
                    const SizedBox(height: 10),
                    _AlertLog(
                      alerts:
                          status['recentAlerts'] as List<dynamic>? ?? const [],
                    ),
                  ] else
                    const _LoadingView(),
                ],
              ),
            if (activeAlerts.isNotEmpty)
              _AlertStack(
                alerts: activeAlerts,
                flash: _alertFlashController,
                onAck: _ackAlert,
              ),
          ],
        ),
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    );
  }
}

class _PairingPanel extends StatelessWidget {
  const _PairingPanel({
    required this.pinController,
    required this.busy,
    required this.message,
    required this.onPair,
    required this.operateMode,
    required this.onModeToggle,
  });

  final TextEditingController pinController;
  final bool busy;
  final String message;
  final VoidCallback onPair;
  final bool operateMode;
  final ValueChanged<bool> onModeToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Stack(
        children: [
          IgnorePointer(
            child: Opacity(
              opacity: 0.42,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                children: [
                  _DashboardHeader(
                    busy: true,
                    onRefresh: () {},
                    operateMode: operateMode,
                    onModeToggle: onModeToggle,
                  ),
                  const SizedBox(height: 10),
                  _SummaryPanel(status: _pairingPreviewStatus),
                  const SizedBox(height: 10),
                  _StatusGrid(status: _pairingPreviewStatus),
                  const SizedBox(height: 10),
                  Panel(
                    title: '시나리오',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: const [
                        SizedBox(height: 58),
                        SizedBox(height: 10),
                        SizedBox(height: 58),
                        SizedBox(height: 10),
                        SizedBox(height: 58),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned.fill(
            child: Container(color: scheme.surface.withOpacity(0.38)),
          ),
          Align(
            alignment: const Alignment(0, -0.12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 420),
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                decoration: BoxDecoration(
                  color: scheme.surface.withOpacity(0.92),
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.10),
                      blurRadius: 24,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'PIN 연결',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'PC 앱에서 생성한 PIN을 입력하세요.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: scheme.secondary),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: pinController,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration(labelText: '페어링 PIN'),
                      onSubmitted: (_) {
                        if (!busy) onPair();
                      },
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: busy ? null : onPair,
                      child: Text(busy ? '연결 중...' : '연결'),
                    ),
                    if (message.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.secondary),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final Map<String, dynamic> _pairingPreviewStatus = {
  'summary': {
    'level': 'ok',
    'title': '모니터링 대기',
    'message': 'PIN 연결 후 PC의 송출 상태를 표시합니다.',
  },
  'obs': {'streaming': false, 'bitrateKbps': '-', 'droppedFramePct': '-'},
  'youtube': {'live': false},
  'lufs': {'shortTerm': null, 'status': 'inactive'},
  'audio': {'silent': false, 'status': 'inactive'},
};

class _DashboardHeader extends StatelessWidget {
  const _DashboardHeader({
    required this.busy,
    required this.onRefresh,
    required this.operateMode,
    required this.onModeToggle,
  });

  final bool busy;
  final VoidCallback onRefresh;
  final bool operateMode;
  final ValueChanged<bool> onModeToggle;

  Future<void> _pickMode(BuildContext context) async {
    final selected = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('모드 선택'),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: _ModeOption(
                label: '노멀',
                description: '모니터링 전용',
                selected: !operateMode,
                onTap: () => Navigator.of(ctx).pop(false),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ModeOption(
                label: '운영',
                description: '시나리오 조작',
                selected: operateMode,
                onTap: () => Navigator.of(ctx).pop(true),
              ),
            ),
          ],
        ),
      ),
    );
    if (selected != null && selected != operateMode) {
      onModeToggle(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill =
        operateMode ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final fg =
        operateMode ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return Row(
      children: [
        Expanded(
          child: Text(
            'Stream Mon',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        Row(
          children: [
            Material(
              color: fill,
              borderRadius: BorderRadius.circular(6),
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: busy ? null : () => _pickMode(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    operateMode ? '운영' : '노멀',
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: busy ? null : onRefresh,
              icon: const Icon(Icons.refresh),
              tooltip: '새로고침',
            ),
          ],
        ),
      ],
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({
    required this.label,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 감싸는 불투명 배경 제거 → 반투명 버튼만 얹기
    final fill = selected
        ? scheme.primary.withOpacity(0.22)
        : scheme.onSurface.withOpacity(0.05);
    final fg = selected ? scheme.primary : scheme.onSurface;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 12),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: fg,
                fontWeight: FontWeight.w800,
                fontSize: 26,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: TextStyle(color: fg.withOpacity(0.75), fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({required this.status});

  final Map<String, dynamic> status;

  @override
  Widget build(BuildContext context) {
    final summary = status['summary'] as Map<String, dynamic>? ?? {};
    final level = summary['level'] as String? ?? 'ok';
    final color = levelColor(context, level);
    return Panel(
      title: '송출 상태',
      trailing: StatusDot(color: color),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: color.withOpacity(0.12),
            child: Icon(Icons.monitor_heart, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${summary['title'] ?? '정상 모니터링'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${summary['message'] ?? '-'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusGrid extends StatelessWidget {
  const _StatusGrid({required this.status});

  final Map<String, dynamic> status;

  @override
  Widget build(BuildContext context) {
    final obs = status['obs'] as Map<String, dynamic>? ?? {};
    final youtube = status['youtube'] as Map<String, dynamic>? ?? {};
    final lufs = status['lufs'] as Map<String, dynamic>? ?? {};
    final audio = status['audio'] as Map<String, dynamic>? ?? {};

    final streaming = obs['streaming'] == true;
    final obsKnown = obs.containsKey('streaming');
    final live = youtube['live'] == true;
    final ytKnown = youtube.containsKey('live');
    final bitrate = obs['bitrateKbps'];
    final dropped = obs['droppedFramePct'] ?? obs['droppedFrames'];
    final lufsVal = lufs['shortTerm'];
    final audioConnected =
        audio['connected'] == true || audio['peakDb'] != null;
    final audioActive = audioConnected && audio['status'] != 'inactive';

    // streaming=true 라도 비트레이트가 0/없으면 실제 송출이 아님 → 녹색 끔
    final br = bitrate is num
        ? bitrate.toDouble()
        : double.tryParse('${bitrate ?? ''}');
    final obsLive = streaming && br != null && br > 0;

    final tiles = [
      TileData(
        'OBS',
        obsLive ? 'LIVE' : (streaming ? '대기' : (obsKnown ? '중지' : '연결 안됨')),
        obsLive ? 'ok' : (obsKnown ? 'warn' : 'inactive'),
      ),
      TileData(
        'YouTube',
        live ? 'LIVE' : (ytKnown ? '오프라인' : '연결 안됨'),
        live ? 'ok' : (ytKnown ? 'warn' : 'inactive'),
      ),
      TileData(
        '비트레이트',
        obsLive ? '$bitrate kbps' : '-',
        obsLive ? 'ok' : 'inactive',
      ),
      TileData(
        '드롭',
        obsLive && dropped != null ? '$dropped' : '-',
        obsLive && dropped != null ? 'ok' : 'inactive',
      ),
      TileData(
        'LUFS',
        lufsVal != null ? '$lufsVal' : '-',
        lufsVal != null ? '${lufs['status'] ?? 'ok'}' : 'inactive',
      ),
      TileData(
        '오디오',
        audioActive ? (audio['silent'] == true ? '무음' : 'OK') : '-',
        audioActive ? '${audio['status'] ?? 'ok'}' : 'inactive',
      ),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: tiles.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 2.15,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemBuilder: (context, index) => StatusTile(data: tiles[index]),
    );
  }
}

class _ScenarioPanel extends StatelessWidget {
  const _ScenarioPanel({
    required this.scenario,
    required this.onStageTap,
    required this.enabled,
  });

  final Map<String, dynamic>? scenario;
  final ValueChanged<int> onStageTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final stages = scenario?['stages'] as List<dynamic>? ?? const [];
    final current = scenario?['currentStageIndex'] as int? ?? 0;
    return Panel(
      title: '시나리오',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final stage in stages)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: ScenarioStageButton(
                title: '${stage['title'] ?? '-'}',
                note: '${stage['note'] ?? ''}',
                selected: (stage['index'] as num).toInt() == current,
                onPressed: enabled
                    ? () => onStageTap((stage['index'] as num).toInt())
                    : null,
              ),
            ),
          if (stages.isEmpty)
            Text(
              '시나리오 단계가 없습니다.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class ScenarioStageButton extends StatelessWidget {
  const ScenarioStageButton({
    super.key,
    required this.title,
    required this.note,
    required this.selected,
    this.onPressed,
  });

  final String title;
  final String note;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;

    late final Color bg;
    late final Color fg;
    late final Color borderColor;
    late final double elevation;
    late final IconData icon;
    late final Color iconColor;

    if (disabled) {
      // 노멀 모드: 조작 잠금 — 평평한 회색 + 자물쇠로 '잠김'을 분명히
      bg = const Color(0xffeceff3);
      fg = const Color(0xff97a1b0);
      borderColor = const Color(0xffdce1e8);
      elevation = 0;
      icon = Icons.lock_outline;
      iconColor = fg;
    } else if (selected) {
      // 선택된 단계: 선명한 파랑으로 강조
      bg = const Color(0xff2563eb);
      fg = Colors.white;
      borderColor = const Color(0xff2563eb);
      elevation = 2.5;
      icon = Icons.check_circle;
      iconColor = Colors.white;
    } else {
      // 선택 가능한 단계: 흰 버튼 + 테두리 + 그림자로 '누를 수 있음'을 표현
      bg = Colors.white;
      fg = const Color(0xff182235);
      borderColor = const Color(0xffd6deea);
      elevation = 1.5;
      icon = Icons.chevron_right;
      iconColor = const Color(0xff2563eb);
    }

    return Material(
      color: bg,
      elevation: elevation,
      shadowColor: Colors.black.withOpacity(0.22),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: BoxConstraints(minHeight: note.trim().isEmpty ? 66 : 88),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: fg,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    if (note.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        note,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: fg.withOpacity(0.78),
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(icon, color: iconColor, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlertLog extends StatelessWidget {
  const _AlertLog({required this.alerts});

  final List<dynamic> alerts;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: '알림 이벤트',
      child: Column(
        children: [
          for (final alert in alerts.take(4))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: StatusDot(
                color: levelColor(context, '${alert['level'] ?? 'info'}'),
              ),
              title: Text('${alert['title'] ?? alert['type'] ?? '-'}'),
              subtitle: Text(
                alert['acknowledged'] == true
                    ? '확인됨'
                    : '${alert['message'] ?? ''}',
              ),
            ),
          if (alerts.isEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '알림 없음',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _AlertStack extends StatelessWidget {
  const _AlertStack({
    required this.alerts,
    required this.flash,
    required this.onAck,
  });

  final List<Map<String, dynamic>> alerts;
  final Animation<double> flash;
  final void Function(String? id) onAck;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasCritical = alerts.any((a) => '${a['level']}' == 'critical');
    final flashColor = hasCritical ? scheme.error : const Color(0xffd97706);
    return Positioned.fill(
      child: Stack(
        children: [
          AnimatedBuilder(
            animation: flash,
            builder: (context, child) {
              final pulse =
                  math.sin(flash.value * math.pi * 7).abs() * (1 - flash.value);
              return Container(
                color: flashColor.withOpacity(0.34 + pulse * 0.42),
              );
            },
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 20,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          alerts.length > 1 ? '알림 ${alerts.length}건' : '알림',
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                        ),
                      ),
                      for (final alert in alerts)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _AlertCard(
                            alert: alert,
                            onAck: () => onAck(alert['id'] as String?),
                          ),
                        ),
                      if (alerts.length > 1)
                        TextButton(
                          onPressed: () => onAck(null),
                          child: const Text(
                            '모두 확인',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert, required this.onAck});

  final Map<String, dynamic> alert;
  final VoidCallback onAck;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final critical = '${alert['level'] ?? 'warn'}' == 'critical';
    final cardColor = critical ? scheme.error : const Color(0xffd97706);
    final message = '${alert['message'] ?? ''}'.trim();
    return Material(
      color: cardColor,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      shadowColor: Colors.black.withOpacity(0.3),
      child: InkWell(
        onTap: onAck,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              Icon(
                critical ? Icons.warning_amber_rounded : Icons.error_outline,
                color: Colors.white,
                size: 32,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${alert['title'] ?? '경고'}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    if (message.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        message,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Colors.white.withOpacity(0.92),
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '확인',
                  style: TextStyle(
                    color: cardColor,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title.toUpperCase(),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
          ),
          Divider(height: 1, color: Theme.of(context).dividerColor),
          Padding(padding: const EdgeInsets.all(14), child: child),
        ],
      ),
    );
  }
}

class StatusTile extends StatelessWidget {
  const StatusTile({super.key, required this.data});

  final TileData data;

  @override
  Widget build(BuildContext context) {
    final color = levelColor(context, data.level);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withOpacity(0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  data.label,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              StatusDot(color: color),
            ],
          ),
          Text(
            data.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class TileData {
  TileData(this.label, this.value, this.level);
  final String label;
  final String value;
  final String level;
}

Color levelColor(BuildContext context, String level) {
  return switch (level) {
    'critical' || 'err' => AppColors.err,
    'warn' => AppColors.warn,
    'ok' => AppColors.ok,
    'inactive' || 'off' => const Color(0xff94a3b8), // 비활성 (회색)
    _ => Theme.of(context).colorScheme.secondary,
  };
}

class AppTheme {
  static ThemeData light() {
    return _theme(
      brightness: Brightness.light,
      bg: const Color(0xfff5f7fb),
      surface: Colors.white,
      border: const Color(0xffe1e7f0),
      text: const Color(0xff182235),
      muted: const Color(0xff647184),
      accent: const Color(0xff2563eb),
    );
  }

  static ThemeData dark() {
    return _theme(
      brightness: Brightness.dark,
      bg: const Color(0xff0f172a),
      surface: const Color(0xff111827),
      border: const Color(0xff263449),
      text: const Color(0xffe5edf8),
      muted: const Color(0xff9aa8bc),
      accent: const Color(0xff60a5fa),
    );
  }

  static ThemeData _theme({
    required Brightness brightness,
    required Color bg,
    required Color surface,
    required Color border,
    required Color text,
    required Color muted,
    required Color accent,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    ).copyWith(surface: surface, secondary: muted, error: AppColors.err);
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: bg,
      colorScheme: scheme,
      dividerColor: border,
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: text,
        elevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
      textTheme: ThemeData(
        brightness: brightness,
      ).textTheme.apply(bodyColor: text, displayColor: text),
    );
  }
}

class AppColors {
  static const ok = Color(0xff22c55e); // 선명한 초록 (정상)
  static const warn = Color(0xffeab308); // 선명한 노랑 (경고) — 빨강과 확실히 구분
  static const err = Color(0xffef4444); // 선명한 빨강 (오류)
}
