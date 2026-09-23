import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// M0 client skeleton: ping the Sui server and show connection status.
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.serverUrl = defaultServerUrl});

  /// Base URL of the Sui server, overridable for tests.
  static const defaultServerUrl = 'http://127.0.0.1:8080';

  final String serverUrl;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Future<String?>? _pingFuture;

  @override
  void initState() {
    super.initState();
    _pingFuture = _ping();
  }

  Future<String?> _ping() async {
    try {
      final resp = await http
          .get(Uri.parse('${widget.serverUrl}/api/v1/ping'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      return '${body['service']} v${body['version']} · ${body['msg']}';
    } catch (e) {
      // Handled below via FutureBuilder error path.
      return Future.error(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('随手记 Sui')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sticky_note_2_outlined,
                  size: 64, color: Color(0xFF2E8B57)),
              const SizedBox(height: 16),
              const Text('M0 客户端壳',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text('服务端：${widget.serverUrl}',
                  style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 24),
              FutureBuilder<String?>(
                future: _pingFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 12),
                        Text('正在连接服务端…'),
                      ],
                    );
                  }
                  if (snapshot.hasError) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.wifi_off, color: Colors.redAccent),
                        const SizedBox(height: 8),
                        const Text('无法连接服务端',
                            style: TextStyle(color: Colors.redAccent)),
                        const SizedBox(height: 8),
                        Text(
                          '${snapshot.error}',
                          style: const TextStyle(
                              color: Colors.grey, fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    );
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.check_circle, color: Colors.green),
                      const SizedBox(height: 8),
                      const Text('服务端已连接',
                          style: TextStyle(color: Colors.green)),
                      const SizedBox(height: 4),
                      Text('${snapshot.data}',
                          style: const TextStyle(color: Colors.grey)),
                    ],
                  );
                },
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () {
                  setState(() {
                    _pingFuture = null;
                    _pingFuture = _ping();
                  });
                },
                icon: const Icon(Icons.refresh),
                label: const Text('重新连接'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}