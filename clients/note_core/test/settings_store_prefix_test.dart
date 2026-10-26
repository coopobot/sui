import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// M14（FR-66 / BR-66.3）：按前缀批量读取本机偏好——笔记本字体覆盖
/// `ui.notebookFont.<notebookId>` 的载入接缝。
void main() {
  group('SettingsStore.withPrefix（M14）', () {
    late AppDatabase db;
    late SettingsStore store;

    setUp(() {
      db = AppDatabase.memory();
      store = SettingsStore(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('只返回匹配前缀的键（其余偏好不受影响）', () async {
      await store.set('ui.notebookFont.nb-1', 'SimSun');
      await store.set('ui.notebookFont.nb-2', 'KaiTi');
      await store.set('ui.fontFamily.body', 'Microsoft YaHei');
      await store.set('notes.sortMode', 'title');

      final fonts = await store.withPrefix('ui.notebookFont.');
      expect(fonts, <String, String>{
        'ui.notebookFont.nb-1': 'SimSun',
        'ui.notebookFont.nb-2': 'KaiTi',
      });
    });

    test('无匹配时返回空表；remove 后不再出现', () async {
      expect(await store.withPrefix('ui.notebookFont.'), isEmpty);

      await store.set('ui.notebookFont.nb-1', 'SimSun');
      await store.remove('ui.notebookFont.nb-1');
      expect(await store.withPrefix('ui.notebookFont.'), isEmpty);
    });

    test('覆盖写：同一键重复写入取最后值', () async {
      await store.set('ui.notebookFont.nb-1', 'SimSun');
      await store.set('ui.notebookFont.nb-1', 'FangSong');
      expect(await store.withPrefix('ui.notebookFont.'),
          <String, String>{'ui.notebookFont.nb-1': 'FangSong'});
    });
  });
}
