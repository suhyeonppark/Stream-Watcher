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

  Stream<Map<String, dynamic>> events() async* {
    final client = HttpClient();
    final req = await client.getUrl(_uri('/api/mobile/events'));
    _authorize(req);
    final res = await req.close();
    var event = 'message';
    final data = StringBuffer();

    await for (final line
        in res.transform(utf8.decoder).transform(const LineSplitter())) {
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
    client.close();
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
