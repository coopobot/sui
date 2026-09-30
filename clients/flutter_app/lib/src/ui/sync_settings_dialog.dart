import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_controller.dart';

/// 打开「同步设置」对话框：服务端地址 / 账号 / Token / 附件缓存上限。
Future<void> showSyncSettingsDialog(
  BuildContext context,
  AppController controller,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => ChangeNotifierProvider<AppController>.value(
      value: controller,
      child: const _SyncSettingsDialog(),
    ),
  );
}

class _SyncSettingsDialog extends StatefulWidget {
  const _SyncSettingsDialog();

  @override
  State<_SyncSettingsDialog> createState() => _SyncSettingsDialogState();
}

class _SyncSettingsDialogState extends State<_SyncSettingsDialog> {
  late final AppController _c = context.read<AppController>();

  late final TextEditingController _baseUrl =
      TextEditingController(text: _defaultBaseUrl());
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  late final TextEditingController _token =
      TextEditingController(text: _c.syncConfig.token);
  late final TextEditingController _cacheMb =
      TextEditingController(text: '${_c.cacheLimitBytes ~/ (1024 * 1024)}');

  bool _busy = false;
  String? _message;
  bool _messageIsError = false;
  int _usedBytes = 0;

  /// 服务端是否已完成首启建号（null = 尚未探明）。true 时禁用「注册并连接」。
  bool? _serverInitialized;

  String _defaultBaseUrl() {
    final configured = _c.syncConfig.baseUrl;
    // 默认走 localhost：WSL2 只把 localhost 转发到宿主 Windows，127.0.0.1
    // 会被浏览器直连到 Windows 自身，注册/连接会 ERR_CONNECTION_REFUSED。
    return configured.isEmpty ? 'http://localhost:8080' : configured;
  }

  @override
  void initState() {
    super.initState();
    _loadUsage();
    _probeInitialized();
  }

  /// 探测服务端注册状态（M4/BR-33.4）：已初始化则禁用「注册并连接」。
  ///
  /// 尽力而为：探测失败不阻塞 UI，保持「未知」（按钮可点），
  /// 真实错误留给用户实际动作时的反馈。
  Future<void> _probeInitialized() async {
    try {
      final info = await _c.probeServer(_baseUrl.text);
      if (!mounted) return;
      setState(() => _serverInitialized = info.initialized);
    } on Exception {
      // 忽略：服务端不可达时保持未知。
    }
  }

  Future<void> _loadUsage() async {
    final (used, _) = await _c.attachmentCacheUsage();
    if (!mounted) return;
    setState(() => _usedBytes = used);
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _username.dispose();
    _password.dispose();
    _token.dispose();
    _cacheMb.dispose();
    super.dispose();
  }

  void _ok(String msg) => setState(() {
        _message = msg;
        _messageIsError = false;
      });

  void _err(String msg) => setState(() {
        _message = msg;
        _messageIsError = true;
      });

  /// 统一处理「忙碌 + 结果提示」，避免每个动作重复样板。
  Future<void> _run(Future<String?> Function() action, String successMsg) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final error = await action();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = error ?? successMsg;
      _messageIsError = error != null;
    });
    await _loadUsage();
  }

  Future<void> _test() => _run(() async {
        final info = await _c.probeServer(_baseUrl.text);
        if (mounted) setState(() => _serverInitialized = info.initialized);
        if (info.version.isEmpty) return null;
        return info.initialized
            ? '连接正常（服务端版本 ${info.version} · 已建号，请用「登录并连接」）'
            : '连接正常（服务端版本 ${info.version}）';
      }, '连接正常');

  Future<void> _register() => _run(
        () => _c.registerAndConnect(
          baseUrl: _baseUrl.text,
          username: _username.text.trim(),
          password: _password.text,
        ),
        '注册成功，已连接',
      );

  Future<void> _login() => _run(
        () => _c.loginAndConnect(
          baseUrl: _baseUrl.text,
          username: _username.text.trim(),
          password: _password.text,
        ),
        '登录成功，已连接',
      );

  Future<void> _saveToken() => _run(() async {
        await _c.connectWithToken(
          baseUrl: _baseUrl.text,
          token: _token.text.trim(),
        );
        return _c.syncConfig.isConfigured ? null : '地址或 Token 为空';
      }, '已连接并完成首次同步');

  Future<void> _saveCacheLimit() async {
    final mb = int.tryParse(_cacheMb.text.trim());
    if (mb == null || mb <= 0) {
      _err('缓存上限需为正整数（单位 MB）');
      return;
    }
    await _c.setCacheLimitBytes(mb * 1024 * 1024);
    if (!mounted) return;
    _ok('缓存上限已设为 $mb MB（下次连接生效）');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = _c.syncClient != null;

    return AlertDialog(
      title: const Text('同步设置'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _statusRow(theme, connected),
              const SizedBox(height: 12),
              TextField(
                controller: _baseUrl,
                decoration: const InputDecoration(
                  labelText: '服务端地址',
                  hintText: 'http://localhost:8080',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _username,
                      decoration: const InputDecoration(
                        labelText: '用户名',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '密码',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: (_busy || _serverInitialized == true)
                        ? null
                        : _register,
                    child: const Text('注册并连接'),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : _login,
                    child: const Text('登录并连接'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _test,
                    child: const Text('测试连接'),
                  ),
                ],
              ),
              if (_serverInitialized == true) ...[
                const SizedBox(height: 6),
                Text(
                  '该服务端已完成初始化（单用户实例），请使用「登录并连接」。',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
              const Divider(height: 28),
              TextField(
                controller: _token,
                decoration: const InputDecoration(
                  labelText: 'Token（已有账号可直接粘贴）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  FilledButton(
                    onPressed: _busy ? null : _saveToken,
                    child: const Text('保存并连接'),
                  ),
                  const SizedBox(width: 8),
                  if (connected)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                                await _c.disconnect();
                                return null;
                              }, '已断开连接'),
                      child: const Text('断开连接'),
                    ),
                ],
              ),
              const Divider(height: 28),
              Text('本机设备 ID', style: theme.textTheme.labelMedium),
              SelectableText(
                _c.syncConfig.deviceId,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Text(
                '附件缓存：${_fmtBytes(_usedBytes)} / ${_fmtBytes(_c.cacheLimitBytes)}',
                style: theme.textTheme.labelMedium,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  SizedBox(
                    width: 120,
                    child: TextField(
                      controller: _cacheMb,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '上限 (MB)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _busy ? null : _saveCacheLimit,
                    child: const Text('保存上限'),
                  ),
                ],
              ),
              if (_busy) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
              if (_message != null) ...[
                const SizedBox(height: 12),
                Text(
                  _message!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _messageIsError
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _statusRow(ThemeData theme, bool connected) {
    final (icon, text, color) = switch (_c.syncState) {
      SyncState.unconfigured => (
          Icons.cloud_off_outlined,
          '未连接',
          theme.colorScheme.outline,
        ),
      SyncState.idle => (
          Icons.cloud_done_outlined,
          '已连接',
          theme.colorScheme.primary,
        ),
      SyncState.syncing => (
          Icons.cloud_sync_outlined,
          '同步中…',
          theme.colorScheme.primary,
        ),
      SyncState.error => (
          Icons.cloud_off_outlined,
          '同步失败：${_c.syncError ?? '未知原因'}',
          theme.colorScheme.error,
        ),
    };
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: color)),
        ),
        if (connected)
          Text(
            'deviceId 已就绪',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
      ],
    );
  }
}

String _fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}