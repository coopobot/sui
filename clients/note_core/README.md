# note_core

随手记 Sui 的多端共享核心逻辑包（纯 Dart，不依赖 Flutter）。

## 职责

- **数据模型**：Note / Notebook / Tag / Attachment / Revision（域模型，与数据库表解耦）
- **本地库**：drift（SQLite），6 表 schema（notes/notebooks/tags/note_tags/revisions/attachments）
- **Blob 存储**：`BlobStore` 抽象（附件字节不进 SQLite，按 sha256 内容寻址）+ `LocalBlobStore`
- **仓储服务**：`NoteRepository` —— 笔记本树、标签（多对多）、笔记 CRUD、修订历史、关键字搜索、软删除墓碑、归档/置顶

## 环境依赖

- Dart SDK ≥ 3.3（项目用 Flutter 内置 SDK 实测 3.13.4）
- SQLite3 native 库：drift 需要 `libsqlite3.so`。WSL 通常只有 `libsqlite3.so.0`，需建符号链接：

```bash
mkdir -p ~/.local/lib
ln -sf /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 ~/.local/lib/libsqlite3.so
export LD_LIBRARY_PATH=/home/aiuser/.local/lib:$LD_LIBRARY_PATH
```

上面 export 已追加到 `~/.bashrc`（WSL 环境）。

## 生成 drift 代码 & 测试

```bash
dart pub get
dart run build_runner build        # 生成 lib/src/db/app_database.g.dart
dart analyze
dart test
```

## 说明

- drift 生成的数据类名带 `Row` 后缀（如 `NoteRow`），避免与域模型（`Note`）冲突。
- 首条修订 version=1 与 Notes.version 初始化对齐，保证历史排序稳定。
- 附件写入示例见 `test/note_repository_test.dart` 的 BlobStore 用例。