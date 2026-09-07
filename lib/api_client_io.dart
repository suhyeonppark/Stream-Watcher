import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 서버가 인증을 거부(401)했을 때 — 페어링이 해제된 상태.
class UnauthorizedException implements Exception {
  const UnauthorizedException();
  @override
  String toString() => '인증이 만료되었습니다';
}

class StreamWatcherApi {
  StreamWatcherApi({required this.baseUrl, this.token});

  final String baseUrl;
  final String? token;

  Uri _uri(String path) =>
      Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}$path');

  Future<Map<String, dynamic>> getJson(String path) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(_uri(path));
      _authorize(req);
      final res = await req.close();
      return _decode(res);
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(_uri(path));
      _authorize(req);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      return _decode(res);
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> health() => getJson('/api/mobile/health');
  Future<Map<String, dynamic>> status() => getJson('/api/mobile/status');
  Future<Map<String, dynamic>> scenario() => getJson('/api/mobile/scenario');
  Future<Map<String, dynamic>> pair(String pin, String deviceName) {
    return postJson('/api/mobile/pair', {
      'pin': pin,
      'deviceName': deviceName,
      'clientId': 'stream-watcher-mobile',
    });
  }

  Future<Map<String, dynamic>> setScenarioStage(int stageIndex) {
    return postJson('/api/mobile/scenario/stage', {'stageIndex': stageIndex});
  }

  Future<Map<String, dynamic>> ack(String? alertId) {
    return postJson('/api/mobile/ack', {'alertId': alertId});
  }

  /// 서버에서 이 시간 동안 한 바이트도 오지 않으면 죽은 연결로 보고 끊는다.
  /// Wi-Fi 로밍/AP 재부팅처럼 소켓은 열린 채 데이터만 멎는 상황은
  /// 이 타임아웃이 없으면 onDone/onError가 영영 오지 않아 조용히 먹통이 된다.
  static const eventIdleTimeout = Duration(seconds: 90);

  Stream<Map<String, dynamic>> events() async* {
    final client = HttpClient();
    try {
      final req = await client.getUrl(_uri('/api/mobile/events'));
      _authorize(req);
      final res = await req.close();
      if (res.statusCode == 401) throw const UnauthorizedException();

      var event = 'message';
      final data = StringBuffer();

      final lines = res
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(eventIdleTimeout);

      await for (final line in lines) {
        if (line.isEmpty) {
          if (data.isNotEmpty) {
            yield {'event': event, 'data': jsonDecode(data.toString())};
          }
          event = 'message';
          data.clear();
        } else if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          data.write(line.substring(5).trim());
        }
      }
    } finally {
      // 정상 종료/에러/구독 취소 어느 경로로 빠져나가든 소켓을 닫는다.
      // 닫지 않으면 재접속할 때마다 PC 쪽에 유령 연결이 쌓인다.
      client.close(force: true);
    }
  }

  void _authorize(HttpClientRequest req) {
    if (token != null && token!.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
  }

  Future<Map<String, dynamic>> _decode(HttpClientResponse res) async {
    final raw = await res.transform(utf8.decoder).join();
    final json = raw.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    if (res.statusCode == 401) {
      throw const UnauthorizedException();
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(
        json['message'] ?? json['error'] ?? 'HTTP ${res.statusCode}',
      );
    }
    return json;
  }
}
