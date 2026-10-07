// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

Future<String> _send(
  html.HttpRequest req, {
  Duration timeout = const Duration(seconds: 2),
  Object? body,
}) {
  final c = Completer<String>();
  var completed = false;
  void completeOk() {
    if (completed) return;
    completed = true;
    c.complete(req.responseText ?? '');
  }

  void completeErr(Object e, [StackTrace? st]) {
    if (completed) return;
    completed = true;
    c.completeError(e, st);
  }

  req.timeout = timeout.inMilliseconds;
  req.onLoad.listen((_) {
    final status = req.status ?? 0;
    if (status == 0 || (status >= 200 && status < 300)) {
      completeOk();
    } else {
      completeErr(Exception('HTTP ${req.status}'), StackTrace.current);
    }
  });
  req.onError.listen(
    (_) => completeErr(Exception('XHR error'), StackTrace.current),
  );
  req.onTimeout.listen(
    (_) =>
        completeErr(TimeoutException('timeout', timeout), StackTrace.current),
  );
  req.onAbort.listen(
    (_) => completeErr(Exception('XHR aborted'), StackTrace.current),
  );

  // Start
  req.send(body);
  return c.future;
}

Future<String> getText(
  String url, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final req = html.HttpRequest()..open('GET', url);
  return _send(req, timeout: timeout);
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
  final req = html.HttpRequest()
    ..open('POST', url)
    ..setRequestHeader('Content-Type', 'application/json');
  return _send(req, timeout: timeout, body: jsonEncode(body));
}

Future<String> postBytes(
  String url,
  List<int> bytes, {
  Duration timeout = const Duration(seconds: 4),
  Map<String, String>? headers,
}) async {
  final req = html.HttpRequest()..open('POST', url);
  headers?.forEach(req.setRequestHeader);
  return _send(req, timeout: timeout, body: bytes);
}

Future<String> postMultipartBytes(
  String url,
  List<int> bytes, {
  Duration timeout = const Duration(seconds: 10),
  void Function(int sent, int total)? onProgress,
}) async {
  final req = html.HttpRequest()..open('POST', url);
  final form = html.FormData();
  form.appendBlob(
    'file',
    html.Blob([bytes], 'application/octet-stream'),
    'pattern.ldy',
  );
  onProgress?.call(bytes.length, bytes.length);
  return _send(req, timeout: timeout, body: form);
}

Future<String> postMultipartStream(
  String url,
  Stream<List<int>> data, {
  required int contentLength,
  Duration timeout = const Duration(seconds: 30),
  void Function(int sent, int total)? onProgress,
}) async {
  final collected = <int>[];
  var sent = 0;
  await for (final chunk in data) {
    collected.addAll(chunk);
    sent += chunk.length;
    onProgress?.call(sent, contentLength);
  }
  return postMultipartBytes(url, collected, timeout: timeout);
}

Future<String> deleteText(
  String url, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final req = html.HttpRequest()..open('DELETE', url);
  return _send(req, timeout: timeout);
}

Future<String> postStream(
  String url,
  Stream<List<int>> data, {
  Duration timeout = const Duration(seconds: 10),
  Map<String, String>? headers,
  int? contentLength,
  void Function(int sent, int total)? onProgress,
}) async {
  final collected = <int>[];
  var sent = 0;
  await for (final chunk in data) {
    collected.addAll(chunk);
    sent += chunk.length;
    onProgress?.call(sent, contentLength ?? sent);
  }
  return postBytes(url, collected, timeout: timeout, headers: headers);
}
