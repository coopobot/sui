import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// M10-T29：加密笔记本**密码学接缝**的门禁。
///
/// 关键点：本测试**以 Spike-003 固化的向量为基线**（`test/fixtures/sui-crypto-v1.json`）——
/// 保证实现走的是「已实测逐字节可互操作 + 与 RFC 公开向量吻合」的那套原语与封装，
/// 而不是某个恰好能自洽的变体（自洽的错实现最危险：本端能加解密、跨端却读不出来）。

/// 固定随机源（测试用）：按给定字节序列产出，便于复现向量中的 nonce。
class _FixedRandom implements Random {
  _FixedRandom(this.values);

  final List<int> values;
  int _i = 0;

  @override
  int nextInt(int max) => values[_i++ % values.length];

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}

String _hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _fromHex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);

void main() {
  final vectors = jsonDecode(
    File('test/fixtures/sui-crypto-v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  group('Spike 向量基线（逐字节回归）', () {
    test('Argon2id 原语与向量一致（含 KiB 量纲）', () async {
      final v = vectors['argon2id'] as Map<String, dynamic>;
      final argon = Argon2id(
        memory: v['memoryKiB'] as int,
        parallelism: v['parallelism'] as int,
        iterations: v['iterations'] as int,
        hashLength: v['outLen'] as int,
      );
      final derived = await argon.deriveKeyFromPassword(
        password: v['password'] as String,
        nonce: _fromHex(v['salt'] as String),
      );
      expect(_hexOf(await derived.extractBytes()), v['expected'],
          reason: 'Argon2id 必须与向量一致（Spike-003 已由 Python argon2-cffi 独立复核）');
    });

    test('组合向量：Argon2id → HKDF 得 K_nb 与 verifier', () async {
      final v = vectors['notebookKey'] as Map<String, dynamic>;
      final meta = CryptoMeta(
        memoryKiB: v['memoryKiB'] as int,
        iterations: v['iterations'] as int,
        parallelism: v['parallelism'] as int,
        salt: _fromHex(
            (vectors['argon2id'] as Map<String, dynamic>)['salt'] as String),
        verifier: Uint8List(0),
      );
      final key = await NotebookCrypto.deriveKey(
        password: v['password'] as String,
        meta: meta,
      );
      expect(_hexOf(key.bytes), v['expectedK'], reason: 'K_nb 必须与向量一致');
      expect(_hexOf(await NotebookCrypto.computeVerifier(key)),
          v['expectedVerifier'],
          reason: 'verifier 必须与向量一致');
    });

    test('AES-256-GCM + 封装 + AAD 与向量逐字节一致', () async {
      final a = vectors['aesgcm'] as Map<String, dynamic>;
      final env = vectors['envelope'] as Map<String, dynamic>;
      final hkdfApp =
          (vectors['hkdf'] as List).cast<Map<String, dynamic>>().last;
      final key = NotebookKey(_fromHex(hkdfApp['expected'] as String));
      final cipher = NotebookFieldCipher(key);

      // 向量里的 AAD 字面量恰是本实现的 AAD 口径：`<notebookId>|<noteId>|<field>`
      expect(
        utf8.decode(NotebookFieldCipher.aadFor(
            notebookId: 'nb-1', noteId: 'note-1', field: NotebookField.content)),
        a['aadUtf8'],
      );

      final envelope = await cipher.encrypt(
        notebookId: 'nb-1',
        noteId: 'note-1',
        field: NotebookField.content,
        plaintext: a['plaintextUtf8'] as String,
        random: _FixedRandom(_fromHex(a['nonce'] as String)),
      );
      expect(envelope, env['expectedBase64'],
          reason: '封装（ver|alg|nonce|ct|tag → base64）必须与向量一致');

      expect(
        await cipher.decrypt(
          notebookId: 'nb-1',
          noteId: 'note-1',
          field: NotebookField.content,
          envelope: envelope,
        ),
        a['plaintextUtf8'],
      );
    });
  });

  group('解锁与密钥', () {
    test('set-encrypted → unlock：正确密码得同一密钥，错误密码拒绝', () async {
      final created = await NotebookCrypto.create(
        password: 'lock-me',
        random: _FixedRandom(List<int>.filled(64, 7)),
      );
      final opened = await NotebookCrypto.unlock(
        password: 'lock-me',
        meta: created.meta,
      );
      expect(_hexOf(opened.bytes), _hexOf(created.key.bytes));

      await expectLater(
        NotebookCrypto.unlock(password: 'wrong', meta: created.meta),
        throwsA(isA<NotebookUnlockException>()),
      );
    });

    test('crypto_meta 往返：JSON 可解析且不含密钥', () async {
      final created = await NotebookCrypto.create(
        password: 'p',
        random: _FixedRandom(List<int>.filled(64, 3)),
      );
      final raw = created.meta.toJson();
      final parsed = CryptoMeta.fromJson(raw);
      expect(parsed.memoryKiB, created.meta.memoryKiB);
      expect(parsed.iterations, created.meta.iterations);
      expect(parsed.salt, created.meta.salt);
      expect(parsed.verifier, created.meta.verifier);
      // 不含任何可用于解密的秘密
      expect(raw.contains(_hexOf(created.key.bytes)), isFalse);
      expect(raw.contains('password'), isFalse);
    });

    test('损坏的 crypto_meta 一律拒绝（不静默当明文）', () {
      final bad = <String>[
        'not json',
        '[]',
        '{"v":1}',
        '{"v":1,"kdf":"scrypt","m":1,"t":1,"p":1,"salt":"AA==","verifier":"AA=="}',
        '{"v":1,"kdf":"argon2id","m":0,"t":1,"p":1,"salt":"AA==","verifier":"AA=="}',
        '{"v":1,"kdf":"argon2id","m":1,"t":1,"p":1,"salt":"!!!","verifier":"AA=="}',
        '{"v":1,"kdf":"argon2id","m":1,"t":1,"p":1,"salt":1,"verifier":"AA=="}',
      ];
      for (final raw in bad) {
        expect(() => CryptoMeta.fromJson(raw),
            throwsA(isA<CryptoMetaFormatException>()),
            reason: raw);
      }
    });
  });

  group('字段加解密', () {
    late NotebookKey key;

    setUp(() async {
      final created = await NotebookCrypto.create(
        password: 'pw',
        random: _FixedRandom(List<int>.filled(64, 11)),
      );
      key = created.key;
    });

    test('往返：密文不是明文，解密还原（含中文 / 长文 / 空串）', () async {
      final cipher = NotebookFieldCipher(key);
      for (final text in <String>['', '短', '# 标题\n\n正文 with `code`', 'x' * 5000]) {
        final env = await cipher.encrypt(
          notebookId: 'nb',
          noteId: 'note',
          field: NotebookField.content,
          plaintext: text,
        );
        // 空串不能做「不含明文」断言（`contains('')` 恒为真）。
        if (text.isNotEmpty) {
          expect(env.contains(text), isFalse, reason: '密文不应含明文');
        }
        expect(NotebookFieldCipher.isEnvelope(env), isTrue);
        expect(
          await cipher.decrypt(
            notebookId: 'nb',
            noteId: 'note',
            field: NotebookField.content,
            envelope: env,
          ),
          text,
        );
      }
    });

    test('nonce 每条唯一（同一明文两次加密产出不同密文）', () async {
      final cipher = NotebookFieldCipher(key);
      final a = await cipher.encrypt(
          notebookId: 'nb',
          noteId: 'n',
          field: NotebookField.content,
          plaintext: 'same');
      final b = await cipher.encrypt(
          notebookId: 'nb',
          noteId: 'n',
          field: NotebookField.content,
          plaintext: 'same');
      expect(a, isNot(b));
    });

    test('AAD 绑定：换笔记 / 换字段解不开（防密文搬运替换）', () async {
      final cipher = NotebookFieldCipher(key);
      final env = await cipher.encrypt(
        notebookId: 'nb',
        noteId: 'note-1',
        field: NotebookField.content,
        plaintext: 'secret',
      );
      for (final other in [
        (notebookId: 'nb', noteId: 'note-2', field: NotebookField.content),
        (notebookId: 'nb2', noteId: 'note-1', field: NotebookField.content),
        (notebookId: 'nb', noteId: 'note-1', field: NotebookField.title),
      ]) {
        await expectLater(
          cipher.decrypt(
            notebookId: other.notebookId,
            noteId: other.noteId,
            field: other.field,
            envelope: env,
          ),
          throwsA(isA<NotebookDecryptException>()),
          reason: '$other',
        );
      }
    });

    test('篡改密文 / tag 即拒绝，不吐半截明文', () async {
      final cipher = NotebookFieldCipher(key);
      final env = await cipher.encrypt(
        notebookId: 'nb',
        noteId: 'note',
        field: NotebookField.content,
        plaintext: 'secret',
      );
      final bytes = base64.decode(env);
      final flipped = Uint8List.fromList(bytes)..[bytes.length - 1] ^= 0x01;
      await expectLater(
        cipher.decrypt(
          notebookId: 'nb',
          noteId: 'note',
          field: NotebookField.content,
          envelope: base64.encode(flipped),
        ),
        throwsA(isA<NotebookDecryptException>()),
      );
    });

    test('isEnvelope 判定：只认本系统封装（避免二次加密 / 误当明文）', () {
      // 合成封装一律给足长度（≥ ver+alg+nonce+tag = 30B），否则会因「太短」而非因
      // 版本 / 算法判定返回 null，断言就成了空转。
      List<int> synth(int ver, int alg) =>
          <int>[ver, alg, ...List<int>.filled(28, 1)];

      expect(NotebookFieldCipher.isEnvelope('普通正文'), isFalse);
      expect(NotebookFieldCipher.isEnvelope(''), isFalse);
      expect(NotebookFieldCipher.isEnvelope('not-base64!!'), isFalse);
      expect(
        NotebookFieldCipher.isEnvelope(base64.encode(synth(0x09, EnvelopeFormat.algAes256Gcm))),
        isFalse,
        reason: '版本不符应拒绝',
      );
      expect(
        NotebookFieldCipher.isEnvelope(base64.encode(synth(EnvelopeFormat.version, 0x09))),
        isFalse,
        reason: '算法标识未知应拒绝',
      );
      expect(
        NotebookFieldCipher.isEnvelope(
            base64.encode(synth(EnvelopeFormat.version, EnvelopeFormat.algAes256Gcm))),
        isTrue,
      );
      // ChaCha20 标识属「本系统封装」（预留位）——判定为密文，但用 AES 密钥解会失败
      expect(
        NotebookFieldCipher.isEnvelope(base64.encode(
            synth(EnvelopeFormat.version, EnvelopeFormat.algChacha20Poly1305))),
        isTrue,
      );
    });

    test('解密非法封装 / 不支持算法 → 明确异常', () async {
      final cipher = NotebookFieldCipher(key);
      await expectLater(
        cipher.decrypt(
            notebookId: 'nb',
            noteId: 'n',
            field: NotebookField.content,
            envelope: 'not-a-cipher'),
        throwsA(isA<NotebookDecryptException>()),
      );
      await expectLater(
        cipher.decrypt(
          notebookId: 'nb',
          noteId: 'n',
          field: NotebookField.content,
          envelope: base64.encode(<int>[
            EnvelopeFormat.version,
            EnvelopeFormat.algChacha20Poly1305,
            ...List<int>.filled(20, 1)
          ]),
        ),
        throwsA(isA<NotebookDecryptException>()),
      );
    });
  });
}
