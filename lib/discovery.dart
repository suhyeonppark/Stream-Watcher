import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _mdnsAddress = '224.0.0.251';
const _mdnsPort = 5353;
const _serviceName = '_streamwatcher._tcp.local';

class DiscoveredServer {
  const DiscoveredServer({
    required this.name,
    required this.host,
    required this.ip,
    required this.port,
  });

  final String name;
  final String host;
  final String ip;
  final int port;

  String get url => 'http://$ip:$port';
}

class MobileDiscoveryClient {
  Future<DiscoveredServer?> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    DiscoveredServer? server;
    try {
      server = await _discoverMdns(timeout: timeout);
    } catch (_) {
      server = null;
    }
    return server ?? await _scanDefaultPort(timeout: timeout);
  }

  Future<DiscoveredServer?> _discoverMdns({required Duration timeout}) async {
    RawDatagramSocket? socket;
    final completer = Completer<DiscoveredServer?>();
    Timer? timer;

    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _mdnsPort,
        reuseAddress: true,
        reusePort: true,
      );
      socket.multicastHops = 255;
      socket.broadcastEnabled = true;
      socket.joinMulticast(InternetAddress(_mdnsAddress));

      timer = Timer(timeout, () {
        if (!completer.isCompleted) completer.complete(null);
      });

      socket.listen((event) {
        if (event != RawSocketEvent.read || completer.isCompleted) return;
        final datagram = socket?.receive();
        if (datagram == null) return;
        final server = _parseResponse(datagram.data, datagram.address.address);
        if (server != null && !completer.isCompleted) {
          completer.complete(server);
        }
      });

      final query = _buildQuery(_serviceName);
      socket.send(query, InternetAddress(_mdnsAddress), _mdnsPort);
      return await completer.future;
    } finally {
      timer?.cancel();
      socket?.close();
    }
  }

  Future<DiscoveredServer?> _scanDefaultPort({
    required Duration timeout,
  }) async {
    final localIps = await _localIpv4Addresses();
    for (final localIp in localIps) {
      final parts = localIp.split('.');
      if (parts.length != 4) continue;
      final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
      final found = await _scanPrefix(prefix, timeout: timeout);
      if (found != null) return found;
    }
    return null;
  }

  Future<List<String>> _localIpv4Addresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    return [
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (!address.isLoopback) address.address,
    ];
  }

  Future<DiscoveredServer?> _scanPrefix(
    String prefix, {
    required Duration timeout,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 300);
    final completer = Completer<DiscoveredServer?>();
    var pending = 0;

    Future<void> probe(String ip) async {
      pending += 1;
      try {
        final req = await client
            .getUrl(Uri.parse('http://$ip:53683/api/mobile/health'))
            .timeout(const Duration(milliseconds: 500));
        final res = await req.close().timeout(
              const Duration(milliseconds: 500),
            );
        final raw = await res.transform(utf8.decoder).join();
        if (res.statusCode == 200 && raw.contains('Stream Mon')) {
          if (!completer.isCompleted) {
            completer.complete(
              DiscoveredServer(
                name: 'Stream Mon',
                host: ip,
                ip: ip,
                port: 53683,
              ),
            );
          }
        }
      } catch (_) {
        // Ignore hosts that do not run Stream Watcher.
      } finally {
        pending -= 1;
        if (pending == 0 && !completer.isCompleted) completer.complete(null);
      }
    }

    for (var host = 1; host < 255; host++) {
      unawaited(probe('$prefix.$host'));
    }

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Uint8List _buildQuery(String name) {
    final encodedName = _encodeName(name);
    final query = BytesBuilder();
    query.add(Uint8List(4));
    query.add(_u16(1));
    query.add(Uint8List(6));
    query.add(encodedName);
    query.add(_u16(12));
    query.add(_u16(1));
    return query.toBytes();
  }

  DiscoveredServer? _parseResponse(Uint8List data, String fallbackIp) {
    if (data.length < 12) return null;

    final qdCount = _readU16(data, 4);
    final answerCount = _readU16(data, 6);
    final authorityCount = _readU16(data, 8);
    final additionalCount = _readU16(data, 10);

    var offset = 12;
    for (var i = 0; i < qdCount; i++) {
      final questionName = _readName(data, offset);
      if (questionName == null) return null;
      offset = questionName.offset + 4;
      if (offset > data.length) return null;
    }

    final addresses = <String, String>{};
    final services = <_SrvRecord>[];
    final records = answerCount + authorityCount + additionalCount;

    for (var i = 0; i < records; i++) {
      final name = _readName(data, offset);
      if (name == null) return null;
      offset = name.offset;
      if (offset + 10 > data.length) return null;

      final type = _readU16(data, offset);
      final dataLength = _readU16(data, offset + 8);
      final dataOffset = offset + 10;
      final nextOffset = dataOffset + dataLength;
      if (nextOffset > data.length) return null;

      if (type == 1 && dataLength == 4) {
        addresses[_normalizeName(name.value)] =
            '${data[dataOffset]}.${data[dataOffset + 1]}.${data[dataOffset + 2]}.${data[dataOffset + 3]}';
      } else if (type == 33 && dataLength >= 7) {
        final port = _readU16(data, dataOffset + 4);
        final target = _readName(data, dataOffset + 6);
        if (target != null) {
          services.add(_SrvRecord(name.value, target.value, port));
        }
      }

      offset = nextOffset;
    }

    for (final service in services) {
      final ip = addresses[_normalizeName(service.target)] ?? fallbackIp;
      if (service.port > 0 && ip.isNotEmpty) {
        return DiscoveredServer(
          name: service.name,
          host: service.target,
          ip: ip,
          port: service.port,
        );
      }
    }
    return null;
  }

  Uint8List _encodeName(String name) {
    final builder = BytesBuilder();
    for (final label in name.replaceAll(RegExp(r'\.$'), '').split('.')) {
      final bytes = Uint8List.fromList(label.codeUnits);
      builder.addByte(bytes.length.clamp(0, 63).toInt());
      builder.add(bytes.take(63).toList());
    }
    builder.addByte(0);
    return builder.toBytes();
  }

  _DnsName? _readName(Uint8List data, int offset, [int depth = 0]) {
    if (depth > 8) return null;
    final labels = <String>[];
    var cursor = offset;
    var jumped = false;
    var nextOffset = offset;

    while (cursor < data.length) {
      final length = data[cursor];
      if (length == 0) {
        cursor += 1;
        if (!jumped) nextOffset = cursor;
        return _DnsName(labels.join('.'), nextOffset);
      }

      if ((length & 0xc0) == 0xc0) {
        if (cursor + 1 >= data.length) return null;
        final pointer = ((length & 0x3f) << 8) | data[cursor + 1];
        final pointed = _readName(data, pointer, depth + 1);
        if (pointed == null) return null;
        if (pointed.value.isNotEmpty) labels.add(pointed.value);
        cursor += 2;
        if (!jumped) nextOffset = cursor;
        jumped = true;
        return _DnsName(labels.join('.'), nextOffset);
      }

      cursor += 1;
      if (cursor + length > data.length) return null;
      labels.add(String.fromCharCodes(data.sublist(cursor, cursor + length)));
      cursor += length;
    }
    return null;
  }

  int _readU16(Uint8List data, int offset) =>
      ByteData.sublistView(data, offset, offset + 2).getUint16(0);

  Uint8List _u16(int value) {
    final bytes = ByteData(2)..setUint16(0, value);
    return bytes.buffer.asUint8List();
  }

  String _normalizeName(String name) => name.toLowerCase().replaceAll(
        RegExp(r'\.$'),
        '',
      );
}

class _DnsName {
  const _DnsName(this.value, this.offset);

  final String value;
  final int offset;
}

class _SrvRecord {
  const _SrvRecord(this.name, this.target, this.port);

  final String name;
  final String target;
  final int port;
}
