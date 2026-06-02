// ignore: deprecated_member_use
import 'dart:html' as html;
import 'dart:async';
import 'dart:convert';

class StreamWatcherApi {
  StreamWatcherApi({required this.baseUrl, this.token});

  final String baseUrl;
  final String? token;

  String _url(String path) => '${baseUrl.replaceAll(RegExp(r'/$'), '')}$path';

  Future<Map<String, dynamic>> getJson(String path) async {
    final res = await html.HttpRequest.request(
      _url(path),
      method: 'GET',
      requestHeaders: _headers(),
    );
    return _decode(res);
  }

  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    final res = await html.HttpRequest.request(
      _url(path),
      method: 'POST',
      requestHeaders: {..._headers(), 'Content-Type': 'application/json'},
      sendData: jsonEncode(body),
    );
    return _decode(res);
  }

  Future<Map<String, dynamic>> health() => getJson('/api/mobile/health');
  Future<Map<String, dynamic>> status() => getJson('/api/mobile/status');
  Future<Map<String, dynamic>> scenario() => getJson('/api/mobile/scenario');
  Future<Map<String, dynamic>> pair(String pin, String deviceName) {
    return postJson('/api/mobile/pair', {
      'pin': pin,
      'deviceName': deviceName,
      'clientId': 'stream-watcher-mobile-web',
    });
  }

  Future<Map<String, dynamic>> setScenarioStage(int stageIndex) {
    return postJson('/api/mobile/scenario/stage', {'stageIndex': stageIndex});
  }

  Future<Map<String, dynamic>> ack(String? alertId) {
    return postJson('/api/mobile/ack', {'alertId': alertId});
  }

  Stream<Map<String, dynamic>> events() {
    final controller = StreamController<Map<String, dynamic>>();
    final uri = Uri.parse(_url('/api/mobile/events')).replace(
      queryParameters: token == null || token!.isEmpty
          ? null
          : {'token': token},
    );
    final source = html.EventSource(uri.toString());
    for (final name in ['status', 'alert', 'ack', 'scenario', 'ping']) {
      source.addEventListener(name, (event) {
        final message = event as html.MessageEvent;
        controller.add({
          'event': name,
          'data': jsonDecode(message.data as String),
        });
      });
    }
    source.onError.listen((_) {
      source.close();
      controller.close();
    });
    controller.onCancel = source.close;
    return controller.stream;
  }

  Map<String, String> _headers() {
    if (token == null || token!.isEmpty) return {};
    return {'Authorization': 'Bearer $token'};
  }

  Map<String, dynamic> _decode(html.HttpRequest res) {
    final raw = res.responseText ?? '{}';
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final status = res.status ?? 0;
    if (status < 200 || status >= 300) {
      throw Exception(json['message'] ?? json['error'] ?? 'HTTP $status');
    }
    return json;
  }
}
