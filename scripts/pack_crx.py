#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""pack_crx.py —— 把扩展 zip 打成 **CRX3**（零第三方依赖），并支持自检。

设计见 SuiDevAgent technology/design/low-level-design/extension-packaging.md
（决策见 ADR-025）。只用 Python 标准库 + `openssl` 命令行。

## 四种模式

    # 1) 打 zip：扩展目录内容，manifest.json 放在 zip 根；条目顺序固定、时间戳归一化（可复现）
    python3 scripts/pack_crx.py --make-zip --source-dir extension --out dist/sui-clipper-0.13.1.zip

    # 2) 打 CRX3：用本地私钥签名
    python3 scripts/pack_crx.py --build --zip dist/x.zip --key ~/.sui/extension-signing-key.pem \
        --out dist/sui-clipper-0.13.1.crx

    # 3) 自检（可从 crx 自身取出公钥验签，**不需要私钥**）
    python3 scripts/pack_crx.py --verify dist/sui-clipper-0.13.1.crx --source-dir extension

    # 4) 只打印扩展 ID + chrome-extension:// 前缀
    python3 scripts/pack_crx.py --print-id --key ~/.sui/extension-signing-key.pem
    python3 scripts/pack_crx.py --print-id --crx dist/sui-clipper-0.13.1.crx

## 环境变量

    SUI_OPENSSL   覆盖 openssl 命令（可含参数，按 shell 规则切分；默认就是 `openssl`）。
                  例：`SUI_OPENSSL=/opt/openssl/bin/openssl`、`SUI_OPENSSL="node /path/shim.js"`。

## CRX3 结构（逐字节）

    "Cr24" | uint32LE(3) | uint32LE(len(header)) | header | zip_bytes

    CrxFileHeader { repeated AsymmetricKeyProof sha256_with_rsa = 2;   // field 2, wire type 2
                    optional bytes signed_header_data = 10000; }       // field 10000
    AsymmetricKeyProof { optional bytes public_key = 1; optional bytes signature = 2; }
    SignedData { optional bytes crx_id = 1; }        // crx_id = sha256(DER SPKI)[:16]

    签名数据 = b"CRX3 SignedData\x00" + uint32LE(len(signed_header_data)) + signed_header_data + zip
    签名算法 = RSA-SHA256 / PKCS#1 v1.5（openssl dgst -sha256 -sign）
    public_key = openssl rsa -in key.pem -pubout -outform DER   （DER 的 SubjectPublicKeyInfo）

protobuf 为**手写编码**（varint + length-delimited），不引入任何库。
扩展 ID = `sha256(DER SPKI)[:16]`，每个 nibble 按 0→a、1→b、…、f→p 映射成 32 个 a~p 字母。
"""

import argparse
import hashlib
import os
import shlex
import struct
import subprocess
import sys
import tempfile
import zipfile

MAGIC = b'Cr24'
CRX3_VERSION = 3
SIGNED_DATA_MAGIC = b'CRX3 SignedData\x00'

FIELD_PROOF = 2          # CrxFileHeader.sha256_with_rsa
FIELD_SIGNED_HEADER = 10000
FIELD_PUBLIC_KEY = 1     # AsymmetricKeyProof.public_key
FIELD_SIGNATURE = 2      # AsymmetricKeyProof.signature
FIELD_CRX_ID = 1         # SignedData.crx_id

WIRE_VARINT = 0
WIRE_LEN = 2

# zip 恒排除项（目录名 / 文件名）
EXCLUDE_DIRS = ('dist', '.git', '__pycache__', 'node_modules', '.idea', '.vscode')
EXCLUDE_FILES = ('.DS_Store', 'Thumbs.db', 'desktop.ini')
EXCLUDE_SUFFIXES = ('.log', '.pyc', '.swp')
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)   # 归一化时间戳 → 可复现


class Fail(Exception):
    """可预期的失败：打印后 exit 1。"""


# --------------------------------------------------------------------------- #
# protobuf 手写编码 / 解析
# --------------------------------------------------------------------------- #

def enc_varint(n):
    if n < 0:
        raise Fail('varint 不能为负: %d' % n)
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def enc_ld(field, payload):
    """length-delimited 字段：tag + len + payload。"""
    return enc_varint((field << 3) | WIRE_LEN) + enc_varint(len(payload)) + payload


def dec_varint(buf, i):
    result = 0
    shift = 0
    while True:
        if i >= len(buf):
            raise Fail('protobuf varint 被截断（偏移 %d）' % i)
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, i
        shift += 7
        if shift > 63:
            raise Fail('protobuf varint 过长')


def dec_fields(buf):
    """解析为 [(field, wire, value)]；value 对 wire=2 是 bytes，对 wire=0 是 int。"""
    out = []
    i = 0
    while i < len(buf):
        key, i = dec_varint(buf, i)
        field, wire = key >> 3, key & 0x07
        if wire == WIRE_LEN:
            ln, i = dec_varint(buf, i)
            if i + ln > len(buf):
                raise Fail('protobuf length-delimited 被截断（field %d）' % field)
            out.append((field, wire, buf[i:i + ln]))
            i += ln
        elif wire == WIRE_VARINT:
            val, i = dec_varint(buf, i)
            out.append((field, wire, val))
        else:
            raise Fail('不支持的 protobuf wire type %d（field %d）' % (wire, field))
    return out


# --------------------------------------------------------------------------- #
# openssl 封装
# --------------------------------------------------------------------------- #

def _openssl_argv():
    """openssl 命令（默认 `openssl`）。

    可用环境变量 **`SUI_OPENSSL`** 覆盖，值可以是**带参数的命令**（按 shell 规则切分），
    例如 `SUI_OPENSSL="node /path/openssl-shim.js"` 或指向自定义安装：
    `SUI_OPENSSL="/opt/openssl/bin/openssl"`。
    """
    raw = os.environ.get('SUI_OPENSSL', '').strip()
    if not raw:
        return ['openssl']
    parts = [p.strip('"') for p in shlex.split(raw, posix=(os.name != 'nt'))]
    parts = [p for p in parts if p]
    return parts or ['openssl']


def _run(cmd):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError:
        raise Fail('找不到可执行文件 %r —— 请确认 openssl 已安装并在 PATH 中'
                   '（可用环境变量 SUI_OPENSSL 指定）' % cmd[0])
    if p.returncode != 0:
        raise Fail('命令失败（exit %d）: %s\n%s'
                   % (p.returncode, ' '.join(cmd),
                      p.stderr.decode('utf-8', 'replace').strip()))
    return p.stdout.decode('utf-8', 'replace').strip()


def _read(path):
    with open(path, 'rb') as f:
        return f.read()


def _write(path, data):
    with open(path, 'wb') as f:
        f.write(data)
    return path


def pubkey_der_from_key(key_path):
    """openssl rsa -in key.pem -pubout -outform DER  → DER SubjectPublicKeyInfo。"""
    if not os.path.isfile(key_path):
        raise Fail('私钥不存在: %s' % key_path)
    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, 'pub.der')
        _run(_openssl_argv() + ['rsa', '-in', key_path, '-pubout', '-outform', 'DER', '-out', out])
        return _read(out)


def rsa_sha256_sign(key_path, data):
    with tempfile.TemporaryDirectory() as td:
        d = _write(os.path.join(td, 'data.bin'), data)
        s = os.path.join(td, 'sig.bin')
        _run(_openssl_argv() + ['dgst', '-sha256', '-sign', key_path, '-out', s, d])
        return _read(s)


def rsa_sha256_verify(pubkey_der, signature, data):
    """openssl dgst -sha256 -verify。公钥由调用方提供（通常取自 crx 自身）。"""
    with tempfile.TemporaryDirectory() as td:
        der = _write(os.path.join(td, 'pub.der'), pubkey_der)
        pem = os.path.join(td, 'pub.pem')
        _run(_openssl_argv() + ['rsa', '-pubin', '-inform', 'DER', '-in', der,
                                '-outform', 'PEM', '-out', pem])
        sig = _write(os.path.join(td, 'sig.bin'), signature)
        dat = _write(os.path.join(td, 'data.bin'), data)
        out = _run(_openssl_argv() + ['dgst', '-sha256', '-verify', pem,
                                      '-signature', sig, dat])
    return out


# --------------------------------------------------------------------------- #
# 扩展 ID
# --------------------------------------------------------------------------- #

def crx_id_from_pubkey(pubkey_der):
    """扩展 ID 的原始 16 字节 = sha256(DER SPKI)[:16]。"""
    return hashlib.sha256(pubkey_der).digest()[:16]


def id_to_letters(raw16):
    """nibble 映射 0→a、1→b、…、f→p，得到 32 个 a~p 字母的扩展 ID。"""
    return ''.join(chr(ord('a') + n) for b in raw16 for n in (b >> 4, b & 0x0F))


def extension_id_from_pubkey(pubkey_der):
    return id_to_letters(crx_id_from_pubkey(pubkey_der))


# --------------------------------------------------------------------------- #
# zip 打包（与 --verify 共用同一套排除规则）
# --------------------------------------------------------------------------- #

def is_excluded(relpath, extra):
    parts = relpath.replace('\\', '/').split('/')
    base = parts[-1]
    if any(p in EXCLUDE_DIRS for p in parts[:-1]) or base in EXCLUDE_DIRS:
        return True
    if base in EXCLUDE_FILES:
        return True
    if base.endswith(EXCLUDE_SUFFIXES):
        return True
    norm = '/'.join(parts)
    for pat in extra or ():
        pat = pat.replace('\\', '/').strip('/')
        if not pat:
            continue
        if norm == pat or norm.startswith(pat + '/') or base == pat:
            return True
    return False


def collect_source_files(source_dir, extra_excludes):
    """→ [(relpath, abspath)]，按 relpath 排序（保证 zip 可复现）。"""
    if not os.path.isdir(source_dir):
        raise Fail('源目录不存在: %s' % source_dir)
    out = []
    for root, dirs, files in os.walk(source_dir):
        dirs.sort()
        for name in sorted(files):
            abspath = os.path.join(root, name)
            rel = os.path.relpath(abspath, source_dir).replace('\\', '/')
            if is_excluded(rel, extra_excludes):
                continue
            out.append((rel, abspath))
    out.sort(key=lambda t: t[0])
    return out


def make_zip(source_dir, out_zip, extra_excludes):
    files = collect_source_files(source_dir, extra_excludes)
    if not files:
        raise Fail('源目录里没有可打包的文件: %s' % source_dir)
    if not any(rel == 'manifest.json' for rel, _ in files):
        raise Fail('源目录根缺少 manifest.json（zip 根的 manifest.json 是 Chrome 的硬要求）: %s'
                   % source_dir)
    os.makedirs(os.path.dirname(os.path.abspath(out_zip)), exist_ok=True)
    with zipfile.ZipFile(out_zip, 'w', zipfile.ZIP_DEFLATED) as zf:
        for rel, abspath in files:
            info = zipfile.ZipInfo(rel, date_time=ZIP_TIMESTAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            with open(abspath, 'rb') as f:
                zf.writestr(info, f.read())
    return files


# --------------------------------------------------------------------------- #
# CRX3：组装与解析
# --------------------------------------------------------------------------- #

def build_crx(zip_bytes, pubkey_der, signature):
    signed_header_data = enc_ld(FIELD_CRX_ID, crx_id_from_pubkey(pubkey_der))
    proof = enc_ld(FIELD_PUBLIC_KEY, pubkey_der) + enc_ld(FIELD_SIGNATURE, signature)
    header = enc_ld(FIELD_PROOF, proof) + enc_ld(FIELD_SIGNED_HEADER, signed_header_data)
    body = (MAGIC + struct.pack('<I', CRX3_VERSION) + struct.pack('<I', len(header))
            + header + zip_bytes)
    return body, signed_header_data


def parse_crx(blob):
    """→ dict(header, payload_zip, proofs=[(pubkey, sig)], signed_header_data, crx_id)"""
    if len(blob) < 12:
        raise Fail('文件太小，不是 CRX（%d 字节）' % len(blob))
    if blob[:4] != MAGIC:
        raise Fail('魔数不是 "Cr24"（实际 %r）' % blob[:4])
    version = struct.unpack('<I', blob[4:8])[0]
    if version != CRX3_VERSION:
        raise Fail('只支持 CRX3（version=3），实际 version=%d' % version)
    header_len = struct.unpack('<I', blob[8:12])[0]
    if 12 + header_len > len(blob):
        raise Fail('header_len=%d 超出文件长度 %d' % (header_len, len(blob)))
    header = blob[12:12 + header_len]
    payload = blob[12 + header_len:]

    proofs, signed_header_data = [], None
    for field, wire, value in dec_fields(header):
        if field == FIELD_PROOF and wire == WIRE_LEN:
            pub = sig = None
            for f2, w2, v2 in dec_fields(value):
                if f2 == FIELD_PUBLIC_KEY and w2 == WIRE_LEN:
                    pub = v2
                elif f2 == FIELD_SIGNATURE and w2 == WIRE_LEN:
                    sig = v2
            if pub is None or sig is None:
                raise Fail('AsymmetricKeyProof 缺 public_key 或 signature')
            proofs.append((pub, sig))
        elif field == FIELD_SIGNED_HEADER and wire == WIRE_LEN:
            signed_header_data = value
    if not proofs:
        raise Fail('CrxFileHeader 里没有 sha256_with_rsa proof')
    if signed_header_data is None:
        raise Fail('CrxFileHeader 里没有 signed_header_data（field 10000）')

    crx_id = None
    for field, wire, value in dec_fields(signed_header_data):
        if field == FIELD_CRX_ID and wire == WIRE_LEN:
            crx_id = value
    if crx_id is None:
        raise Fail('SignedData 里没有 crx_id（field 1）')

    return {'version': version, 'header_len': header_len, 'header': header,
            'payload': payload, 'proofs': proofs,
            'signed_header_data': signed_header_data, 'crx_id': crx_id}


def signing_blob(signed_header_data, zip_bytes):
    return (SIGNED_DATA_MAGIC + struct.pack('<I', len(signed_header_data))
            + signed_header_data + zip_bytes)


# --------------------------------------------------------------------------- #
# 各模式
# --------------------------------------------------------------------------- #

def mode_make_zip(args):
    files = make_zip(args.source_dir, args.out, args.exclude)
    size = os.path.getsize(args.out)
    print('[make-zip] %s -> %s' % (args.source_dir, args.out))
    print('  条目数 : %d' % len(files))
    print('  体积   : %d 字节 (%.1f KiB)' % (size, size / 1024.0))
    for rel, _ in files:
        print('    + %s' % rel)
    return 0


def mode_build(args):
    if not os.path.isfile(args.zip):
        raise Fail('zip 不存在: %s' % args.zip)
    zip_bytes = _read(args.zip)
    if not zipfile.is_zipfile(args.zip):
        raise Fail('不是合法 zip: %s' % args.zip)
    pubkey_der = pubkey_der_from_key(args.key)
    crx_id = crx_id_from_pubkey(pubkey_der)
    signed_header_data = enc_ld(FIELD_CRX_ID, crx_id)
    payload = signing_blob(signed_header_data, zip_bytes)
    signature = rsa_sha256_sign(args.key, payload)
    body, _ = build_crx(zip_bytes, pubkey_der, signature)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    _write(args.out, body)
    ext_id = id_to_letters(crx_id)
    print('[build] %s + %s -> %s' % (args.zip, args.key, args.out))
    print('  zip 载荷  : %d 字节' % len(zip_bytes))
    print('  crx 总体积: %d 字节 (%.1f KiB)' % (len(body), len(body) / 1024.0))
    print('  公钥 (DER SPKI): %d 字节' % len(pubkey_der))
    print('  签名      : %d 字节 (RSA-SHA256)' % len(signature))
    print('  crx_id    : %s' % crx_id.hex())
    print('  扩展 ID   : %s' % ext_id)
    print('  chrome-extension://%s/' % ext_id)
    return 0


def mode_verify(args):
    crx_path = args.verify
    if not os.path.isfile(crx_path):
        raise Fail('crx 不存在: %s' % crx_path)
    blob = _read(crx_path)
    print('[verify] %s（%d 字节）' % (crx_path, len(blob)))

    # ---- V1 容器结构 ----
    c = parse_crx(blob)
    print('  [V1] 容器结构 OK：魔数 Cr24 / version=%d / header_len=%d / payload=%d 字节'
          % (c['version'], c['header_len'], len(c['payload'])))

    # ---- V2 结构与 crx_id ----
    ok_any = False
    checked = []
    for idx, (pub, sig) in enumerate(c['proofs'], 1):
        expect = crx_id_from_pubkey(pub)
        same = (expect == c['crx_id'])
        checked.append((idx, pub, sig, expect, same))
        print('  [V2] proof #%d：public_key=%d 字节 / signature=%d 字节 / crx_id %s'
              % (idx, len(pub), len(sig), '一致' if same else '**不一致**'))
    if not any(t[4] for t in checked):
        raise Fail('crx_id 与所有 proof 的公钥都不匹配（sha256(DER SPKI)[:16]）')
    print('       signed_header_data=%d 字节 / crx_id=%s'
          % (len(c['signed_header_data']), c['crx_id'].hex()))

    # ---- V3 签名验签（公钥取自 crx 自身，不需要私钥）----
    sd_head = struct.pack('<I', len(c['signed_header_data']))
    for idx, pub, sig, expect, same in checked:
        if not same:
            print('  [V3] proof #%d 跳过（crx_id 不匹配）' % idx)
            continue
        data = SIGNED_DATA_MAGIC + sd_head + c['signed_header_data'] + c['payload']
        out = rsa_sha256_verify(pub, sig, data)
        if 'Verified OK' not in out and 'Verification OK' not in out:
            raise Fail('proof #%d 验签失败：%s' % (idx, out))
        print('  [V3] 签名校验 OK（openssl: %s）' % out)
        ok_any = True
    if not ok_any:
        raise Fail('没有任何 proof 通过验签')

    # ---- V4 payload zip 可解压 ----
    with tempfile.TemporaryDirectory() as td:
        zp = os.path.join(td, 'payload.zip')
        _write(zp, c['payload'])
        if not zipfile.is_zipfile(zp):
            raise Fail('payload 不是合法 zip')
        with zipfile.ZipFile(zp) as zf:
            bad = zf.testzip()
            if bad is not None:
                raise Fail('payload zip 内条目 CRC 校验失败: %s' % bad)
            names = [n for n in zf.namelist() if not n.endswith('/')]
            if 'manifest.json' not in names:
                raise Fail('payload zip 根缺少 manifest.json（实际顶层：%s）'
                           % ', '.join(sorted(names)[:10]))
            print('  [V4] payload zip 可解压 OK：%d 个文件，manifest.json 在根' % len(names))

            # ---- V5 与源目录逐文件 md5 比对 ----
            if args.source_dir:
                src = collect_source_files(args.source_dir, args.exclude)
                src_map = {rel: ap for rel, ap in src}
                zip_map = {n: zf.read(n) for n in names}
                print('  [V5] 与源目录逐文件比对（md5）：源 %d 个 / zip %d 个'
                      % (len(src_map), len(zip_map)))
                only_src = sorted(set(src_map) - set(zip_map))
                only_zip = sorted(set(zip_map) - set(src_map))
                if only_src:
                    print('       **仅在源目录**: %s' % ', '.join(only_src))
                if only_zip:
                    print('       **仅在 zip**   : %s' % ', '.join(only_zip))
                mismatched = []
                for rel in sorted(set(src_map) & set(zip_map)):
                    a = hashlib.md5(_read(src_map[rel])).hexdigest()
                    b = hashlib.md5(zip_map[rel]).hexdigest()
                    if a != b:
                        mismatched.append(rel)
                        print('       **md5 不一致** %s: 源 %s / zip %s' % (rel, a, b))
                if only_src or only_zip or mismatched:
                    raise Fail('payload 与源目录不一致（仅源 %d / 仅 zip %d / md5 不符 %d）'
                               % (len(only_src), len(only_zip), len(mismatched)))
                print('       md5 一致 %d/%d，文件集合完全一致'
                      % (len(src_map), len(src_map)))

    # ---- V6 扩展 ID ----
    ext_id = id_to_letters(c['crx_id'])
    print('  [V6] 扩展 ID: %s' % ext_id)
    print('       chrome-extension://%s/' % ext_id)
    print('[verify] 全部通过 ✔')
    return 0


def mode_print_id(args):
    if args.crx:
        if not os.path.isfile(args.crx):
            raise Fail('crx 不存在: %s' % args.crx)
        c = parse_crx(_read(args.crx))
        pub = c['proofs'][0][0]
        raw = crx_id_from_pubkey(pub)
        if raw != c['crx_id']:
            raise Fail('crx 自身不一致：crx_id 与公钥推导不符')
    elif args.key:
        raw = crx_id_from_pubkey(pubkey_der_from_key(args.key))
    else:
        raise Fail('--print-id 需要 --key <key.pem> 或 --crx <crx>')
    ext_id = id_to_letters(raw)
    print(ext_id)
    return 0


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def build_parser():
    p = argparse.ArgumentParser(
        prog='pack_crx.py',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description='把扩展 zip 打成 CRX3（零第三方依赖）并自检。\n'
                    '设计见 technology/design/low-level-design/extension-packaging.md（ADR-025）。',
        epilog='示例:\n'
               '  python3 scripts/pack_crx.py --make-zip --source-dir extension --out dist/e.zip\n'
               '  python3 scripts/pack_crx.py --build --zip dist/e.zip --key ~/.sui/k.pem --out dist/e.crx\n'
               '  python3 scripts/pack_crx.py --verify dist/e.crx --source-dir extension\n'
               '  python3 scripts/pack_crx.py --print-id --crx dist/e.crx\n')
    p.add_argument('--make-zip', action='store_true', help='模式 1：把源目录打成 zip（manifest.json 在根）')
    p.add_argument('--build', action='store_true', help='模式 2：把 zip 打成 CRX3 并用本地私钥签名')
    p.add_argument('--verify', metavar='CRX', help='模式 3：自检 crx（结构 / 验签 / payload / md5 / 扩展 ID）')
    p.add_argument('--print-id', action='store_true', dest='print_id',
                   help='模式 4：只打印扩展 ID')

    p.add_argument('--source-dir', metavar='DIR', help='扩展源目录（--make-zip 必需；--verify 可选，用于 md5 比对）')
    p.add_argument('--out', metavar='PATH', help='输出文件（--make-zip → zip；--build → crx）')
    p.add_argument('--zip', metavar='PATH', help='输入 zip（--build）')
    p.add_argument('--key', metavar='PATH', help='签名私钥 PEM（--build / --print-id）')
    p.add_argument('--crx', metavar='PATH', help='输入 crx（--print-id）')
    p.add_argument('--exclude', action='append', default=[], metavar='PATTERN',
                   help='额外排除的相对路径 / 目录名 / 文件名（可重复；dist 等恒排除）')
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    modes = [bool(args.make_zip), bool(args.build), bool(args.verify), bool(args.print_id)]
    if sum(modes) != 1:
        build_parser().print_help(sys.stderr)
        print('\n错误：必须且只能指定一个模式（--make-zip / --build / --verify / --print-id）',
              file=sys.stderr)
        return 2
    try:
        if args.make_zip:
            if not args.source_dir or not args.out:
                raise Fail('--make-zip 需要 --source-dir 与 --out')
            return mode_make_zip(args)
        if args.build:
            if not args.zip or not args.key or not args.out:
                raise Fail('--build 需要 --zip、--key 与 --out')
            return mode_build(args)
        if args.verify:
            return mode_verify(args)
        return mode_print_id(args)
    except Fail as e:
        print('FAIL: %s' % e, file=sys.stderr)
        return 1
    except zipfile.BadZipFile as e:
        print('FAIL: zip 解析失败: %s' % e, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
