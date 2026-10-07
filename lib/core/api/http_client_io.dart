import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<String> _readResponse(
  HttpClientResponse response,
  Uri uri,
  Duration timeout,
) async {
  final body = await response.transform(utf8.decoder).join().timeout(timeout);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw HttpException('HTTP ${response.statusCode}: $body', uri: uri);
  }
  return body;
}

Future<String> getText(
  String url, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final client = HttpClient();
  client.connectionTimeout = timeout;
  try {
    final uri = Uri.parse(url);
    final req = await client.getUrl(uri).timeout(timeout);
    final resp = await req.close().timeout(timeout);
    return _readResponse(resp, uri, timeout);
  } finally {
    client.close();
  }
}

Future<Map<String, dynamic>> getJson(
  String url, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final text = await getText(url, timeout: timeout);
  return jsonDecode(text) as Map<String, dynamic>;
}

Future<String> postJson(
  String url,
  Map<String, dynamic> body, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final client = HttpClient();
  client.connectionTimeout = timeout;
  try {
    final uri = Uri.parse(url);
    final req = await client.postUrl(uri).timeout(timeout);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.add(utf8.encode(jsonEncode(body)));
    final resp = await req.close().timeout(timeout);
    return _readResponse(resp, uri, timeout);
  } finally {
    client.close();
  }
}

Future<String> postBytes(
  String url,
  List<int> bytes, {
  Duration timeout = const Duration(seconds: 4),
  Map<String, String>? headers,
}) async {
  final client = HttpClient();
  client.connectionTimeout = timeout;
  try {
    final uri = Uri.parse(url);
    final req = await client.postUrl(uri).timeout(timeout);
    headers?.forEach(req.headers.set);
    req.add(bytes);
    final resp = await req.close().timeout(timeout);
    return _readResponse(resp, uri, timeout);
  } finally {
    client.close();
  }
}

Future<String> postMultipartBytes(
  String url,
  List<int> bytes, {
  Duration timeout = const Duration(seconds: 10),
  void Function(int sent, int total)? onProgress,
}) {
  return postMultipartStream(
    url,
    Stream.value(bytes),
    contentLength: bytes.length,
    timeout: timeout,
    onProgress: onProgress,
  );
}

Future<String> postMultipartStream(
  String url,
  Stream<List<int>> data, {
  required int contentLength,
  Duration timeout = const Duration(seconds: 30),
  void Function(int sent, int total)? onProgress,
}) async {
  final client = HttpClient();
  client.connectionTimeout = timeout;
  try {
    final uri = Uri.parse(url);
    final boundary =
        '----LightDome${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
    final head = utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="file"; filename="pattern.ldy"\r\n'
      'Content-Type: application/octet-stream\r\n\r\n',
    );
    final tail = utf8.encode('\r\n--$boundary--\r\n');
    final req = await client.postUrl(uri).timeout(timeout);
    req.headers.set(
      HttpHeaders.contentTypeHeader,
      'multipart/form-data; boundary=$boundary',
    );
    req.contentLength = head.length + contentLength + tail.length;
    req.add(head);
    var sent = 0;
    final monitored = data.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          sent += chunk.length;
          sink.add(chunk);
          onProgress?.call(sent, contentLength);
        },
      ),
    );
    await req.addStream(monitored).timeout(timeout);
    req.add(tail);
    final response = await req.close().timeout(timeout);
    return _readResponse(response, uri, timeout);
  } finally {
    client.close();
  }
}

Future<String> deleteText(
  String url, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final client = HttpClient();
  client.connectionTimeout = timeout;
  try {
    final uri = Uri.parse(url);
    final req = await client.deleteUrl(uri).timeout(timeout);
    final resp = await req.close().timeout(timeout);
    return _readResponse(resp, uri, timeout);
  } finally {
    client.close();
  }
}

Future<String> postStream(
  String url,
  Stream<List<int>> data, {
  Duration timeout = const Duration(seconds: 10),
  Map<String, String>? headers,
  int? contentLength,
  void Function(int sent, int total)? onProgress,
}) async {
  final client = HttpClient();
  client.connectionTimeout = timeout;
  try {
    final uri = Uri.parse(url);
    final req = await client.postUrl(uri).timeout(timeout);
    headers?.forEach(req.headers.set);
    if (contentLength != null) {
      req.headers.set(HttpHeaders.contentLengthHeader, contentLength);
    }
    var sent = 0;
    final monitored = data.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          sent += chunk.length;
          sink.add(chunk);
          if (onProgress != null) {
            onProgress(sent, contentLength ?? sent);
          }
        },
        handleError: (error, stackTrace, sink) =>
            sink.addError(error, stackTrace),
        handleDone: (sink) => sink.close(),
      ),
    );
    await req.addStream(monitored).timeout(timeout);
    final resp = await req.close().timeout(timeout);
    return _readResponse(resp, uri, timeout);
  } finally {
    client.close();
  }
}
