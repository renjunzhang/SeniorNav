#!/usr/bin/env python3
"""Offline APK regression guard for Baidu SDK 9.0.0 JNI entry points.

Reads DEX class definitions and declared methods, not incidental string matches.
No SDK execution, credentials, device access, or network calls are involved.
Run after a release build: python3 tools/check_release_jni.py [path/to/app.apk]
"""
import argparse
from pathlib import Path
import re
import struct
import sys
from zipfile import ZipFile


REQUIRED = {
    'com.baidu.platform.comjni.tools.ParcelItem': {'<init>', 'getBundle', 'setBundle'},
    'com.baidu.platform.comapi.util.URLEncodeUtils': {
        'nativeUrlEncode', 'nativeMD5Sign', 'nativeWebSign', 'nativeOperSign',
        'nativeGetUrlParamsSign',
    },
    'com.baidu.mapsdkplatform.comjni.tools.JNITools': {'initClass'},
    'com.baidu.mapsdkplatform.comjni.util.JNIHandler': {'registerNativeHandler'},
    'com.baidu.mapsdkplatform.comjni.util.JNISysOSAPI': {'create', 'init', 'update'},
    'com.baidu.mshield.x0.jni.Native': {'doExecStaticMethod', 'doExecNonStaticMethod'},
    'com.baidu.xclient.gdid.jni.Native': {'jnictl'},
}


def uleb(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    for shift in range(0, 35, 7):
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7f) << shift
        if not byte & 0x80:
            return value, offset
    raise ValueError('Invalid DEX unsigned LEB128')


def dex_definitions(data: bytes) -> dict[str, set[str]]:
    if not data.startswith(b'dex\n') or data[7] != 0:
        raise ValueError('Expected standard DEX file')
    u32 = lambda offset: struct.unpack_from('<I', data, offset)[0]
    if u32(40) != 0x12345678:
        raise ValueError('Unsupported DEX byte order')
    strings_count, strings_offset = u32(56), u32(60)
    types_count, types_offset = u32(64), u32(68)
    methods_count, methods_offset = u32(88), u32(92)
    classes_count, classes_offset = u32(96), u32(100)
    strings = []
    for index in range(strings_count):
        _, start = uleb(data, u32(strings_offset + index * 4))
        # Names checked here are ASCII; unrelated modified UTF-8 strings are ignored.
        end = data.index(b'\0', start)
        strings.append(data[start:end].decode('utf-8', errors='replace'))
    types = [strings[u32(types_offset + index * 4)] for index in range(types_count)]
    methods = [strings[u32(methods_offset + index * 8 + 4)]
               for index in range(methods_count)]
    found = {}
    for index in range(classes_count):
        offset = classes_offset + index * 32
        descriptor = types[u32(offset)]
        name = descriptor[1:-1].replace('/', '.')
        if name not in REQUIRED:
            continue
        declared = set()
        cursor = u32(offset + 24)
        if cursor:
            counts = []
            for _ in range(4):
                count, cursor = uleb(data, cursor)
                counts.append(count)
            for _ in range(counts[0] + counts[1]):
                _, cursor = uleb(data, cursor)  # field index delta
                _, cursor = uleb(data, cursor)  # access flags
            for count in counts[2:]:  # direct and virtual method indexes restart at zero
                method_index = 0
                for _ in range(count):
                    delta, cursor = uleb(data, cursor)
                    method_index += delta
                    _, cursor = uleb(data, cursor)  # access flags
                    _, cursor = uleb(data, cursor)  # code offset (zero for native)
                    declared.add(methods[method_index])
        found[name] = declared
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', nargs='?', type=Path,
                        default=Path(__file__).resolve().parent.parent /
                        'app/build/app/outputs/flutter-apk/app-release.apk')
    args = parser.parse_args()
    definitions = {}
    with ZipFile(args.apk) as apk:
        for name in apk.namelist():
            if re.fullmatch(r'classes(?:\d+)?\.dex', name):
                definitions.update(dex_definitions(apk.read(name)))
    failures = []
    for name, members in REQUIRED.items():
        if name not in definitions:
            failures.append(f'Missing or renamed JNI class: {name}')
        elif missing := members - definitions[name]:
            failures.append(f'Missing or renamed JNI methods: {name}: {", ".join(sorted(missing))}')
    if failures:
        print('\n'.join(failures), file=sys.stderr)
        return 1
    print(f'PASS: {len(REQUIRED)} Baidu JNI classes and required methods retain original names.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
