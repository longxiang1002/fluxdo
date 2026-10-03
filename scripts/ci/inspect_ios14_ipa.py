"""检查 IPA 的 plist、Mach-O 架构和最低 iOS；不修改或重签名产物。"""
import argparse
import hashlib
import json
import plistlib
import struct
import zipfile
from pathlib import Path


def version(value):
    return f'{value >> 16}.{(value >> 8) & 255}.{value & 255}'


def macho(data, start=0):
    magic = data[start:start + 4]
    if magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        count = struct.unpack_from('>I', data, start + 4)[0]
        stride = 32 if magic[-1] == 0xbf else 20
        records = []
        for index in range(count):
            pos = start + 8 + index * stride
            offset = struct.unpack_from('>Q' if stride == 32 else '>I', data, pos + 8)[0]
            records.extend(macho(data, start + offset))
        return records
    formats = {b'\xcf\xfa\xed\xfe': ('<', 32), b'\xce\xfa\xed\xfe': ('<', 28),
               b'\xfe\xed\xfa\xcf': ('>', 32), b'\xfe\xed\xfa\xce': ('>', 28)}
    if magic not in formats:
        return []
    endian, header = formats[magic]
    cpu = struct.unpack_from(endian + 'I', data, start + 4)[0]
    ncmds = struct.unpack_from(endian + 'I', data, start + 16)[0]
    pos = start + header
    record = {'cpu': hex(cpu), 'minimums': []}
    for _ in range(ncmds):
        cmd, size = struct.unpack_from(endian + 'II', data, pos)
        if size < 8 or pos + size > len(data):
            raise ValueError('Invalid Mach-O load command')
        if cmd == 0x25:
            record['minimums'].append({'platform': 2, 'version': version(struct.unpack_from(endian + 'I', data, pos + 8)[0])})
        elif cmd == 0x32:
            platform, minimum = struct.unpack_from(endian + 'II', data, pos + 8)
            record['minimums'].append({'platform': platform, 'version': version(minimum)})
        pos += size
    return [record]


def inspect(path):
    report = {'artifact': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
              'plists': [], 'binaries': [], 'errors': [],
              'scope': 'Static declarations only; not signing, unavailable APIs, login or thermal verification.'}
    limit = (14, 8, 0)
    main_exec = None
    with zipfile.ZipFile(path) as z:
        for name in z.namelist():
            if not name.startswith('Payload/') or name.endswith('/'):
                continue
            data = z.read(name)
            if name.endswith('/Info.plist'):
                info = plistlib.loads(data)
                minimum = info.get('MinimumOSVersion')
                if minimum:
                    report['plists'].append({'path': name, 'minimum': minimum})
                    parsed = tuple((list(map(int, minimum.split('.'))) + [0, 0])[:3])
                    if parsed > limit:
                        report['errors'].append(f'Plist requires >14.8: {name} = {minimum}')
                if name.count('/') == 2:
                    main_exec = name.rsplit('/', 1)[0] + '/' + info['CFBundleExecutable']
                    report['bundleIdentifier'] = info.get('CFBundleIdentifier')
                    report['version'] = info.get('CFBundleShortVersionString')
                    report['build'] = info.get('CFBundleVersion')
            records = macho(data)
            if records:
                if not any(record['cpu'] == '0x100000c' and any(v['platform'] == 2 for v in record['minimums']) for record in records):
                    report['errors'].append(f'Missing arm64 iOS device slice: {name}')
                if any(v['platform'] != 2 for record in records for v in record['minimums']):
                    report['errors'].append(f'Non-iOS device platform embedded: {name}')
                report['binaries'].append({'path': name, 'slices': records})
                for record in records:
                    for minimum in record['minimums']:
                        if minimum['platform'] == 2 and tuple(map(int, minimum['version'].split('.'))) > limit:
                            report['errors'].append(f'Mach-O requires >14.8: {name} = {minimum["version"]}')
        main = next((x for x in report['binaries'] if x['path'] == main_exec), None)
        if not main or not any(s['cpu'] == '0x100000c' and any(v['platform'] == 2 for v in s['minimums']) for s in main['slices']):
            report['errors'].append('Missing main arm64 iOS executable/minimum load command')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = inspect(args.ipa)
    args.output.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(f'Checked {len(result["binaries"])} Mach-O files; SHA256 {result["sha256"]}')
    for error in result['errors']:
        print(error)
    raise SystemExit(1 if result['errors'] else 0)
