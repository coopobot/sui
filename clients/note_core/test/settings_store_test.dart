import 'dart:io';

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

void main() {
  group('SettingsStore（内存库）', () {
    late AppDatabase db;
    late SettingsStore store;

    setUp(() {
      db = AppDatabase.memory();
      store = SettingsStore(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('set/get 往返与覆盖', () async {
      expect(await store.get('k'), isNull);
      await store.set('k', 'v1');
      expect(await store.get('k'), 'v1');
      await store.set('k', 'v2');
      expect(await store.get('k'), 'v2', reason: '同 key 应覆盖而非插入失败');
    });

    test('remove 后读回 null', () async {
      await store.set('k', 'v');
      await store.remove('k');
      expect(await store.get('k'), isNull);
    });

    test('deviceId 首次生成后保持稳定', () async {
      final a = await store.deviceId();
      final b = await store.deviceId();
      expect(a, isNotEmpty);
      expect(b, a);
    });

    test('未配置时 isConfigured 为 false', () async {
      final cfg = await store.loadSyncConfig();
      expect(cfg.isConfigured, isFalse);
      expect(cfg.deviceId, isNotEmpty, reason: 'deviceId 应已生成');
    });

    test('保存配置：地址去末尾斜杠、Token 去空白', () async {
      await store.saveSyncConfig(
        baseUrl: '  http://127.0.0.1:8080//  ',
        token: '  tok-1  ',
      );
      final cfg = await store.loadSyncConfig();
      expect(cfg.baseUrl, 'http://127.0.0.1:8080');
      expect(cfg.token, 'tok-1');
      expect(cfg.isConfigured, isTrue);
    });

    test('clearSyncConfig 断开连接但保留 deviceId', () async {
      final before = await store.deviceId();
      await store.saveSyncConfig(baseUrl: 'http://x', token: 't');
      await store.clearSyncConfig();
      final cfg = await store.loadSyncConfig();
      expect(cfg.isConfigured, isFalse);
      expect(cfg.deviceId, before);
    });
  });

  group('SyncConfig', () {
    test('normalizeBaseUrl 处理多斜杠与空白', () {
      expect(SyncConfig.normalizeBaseUrl(' http://a:1/ '), 'http://a:1');
      expect(SyncConfig.normalizeBaseUrl('http://a:1///'), 'http://a:1');
      expect(SyncConfig.normalizeBaseUrl('http://a:1'), 'http://a:1');
    });

    test('copyWith 只覆盖指定字段', () {
      const c = SyncConfig(baseUrl: 'u', token: 't', deviceId: 'd');
      final c2 = c.copyWith(token: 't2');
      expect(c2.baseUrl, 'u');
      expect(c2.token, 't2');
      expect(c2.deviceId, 'd');
    });
  });

  group('SettingsStore（落盘）', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('sui-settings');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('配置跨重启保留，deviceId 不变', () async {
      final db1 = AppDatabase.file(basePath: dir.path);
      final s1 = SettingsStore(db1);
      final dev1 = await s1.deviceId();
      await s1.saveSyncConfig(baseUrl: 'http://host:8080', token: 'tok');
      await db1.close();

      final db2 = AppDatabase.file(basePath: dir.path);
      final s2 = SettingsStore(db2);
      final cfg = await s2.loadSyncConfig();
      expect(cfg.baseUrl, 'http://host:8080');
      expect(cfg.token, 'tok');
      expect(cfg.deviceId, dev1, reason: '同一设备标识应跨重启稳定');
      await db2.close();
    });
  });
}