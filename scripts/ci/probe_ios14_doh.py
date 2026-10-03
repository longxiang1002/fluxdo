"""按生产 Rust 的 DNS-wire GET 协议检查固定 DoH，绝不回退系统解析。"""
import base64
import json
import struct
import sys
import time
import urllib.request

endpoint = 'https://linuxdo.ddd.oaifree.com/query-dns'
rows = []
for qtype in (1, 28):
    question = b''.join(bytes([len(x)]) + x.encode('ascii') for x in 'linux.do'.split('.')) + b'\x00'
    query = struct.pack('!HHHHHH', 0x1408, 0x0100, 1, 0, 0, 0) + question + struct.pack('!HH', qtype, 1)
    url = endpoint + '?dns=' + base64.urlsafe_b64encode(query).decode().rstrip('=')
    started = time.monotonic()
    row = {'qtype': qtype}
    try:
        req = urllib.request.Request(url, headers={'Accept': 'application/dns-message'})
        with urllib.request.urlopen(req, timeout=20) as response:
            body = response.read(65536)
            content_type = response.headers.get('Content-Type', '')
            row.update(httpStatus=response.status, contentType=content_type)
        if not content_type.startswith('application/dns-message') or len(body) < 12:
            raise ValueError('Response is not a DNS message')
        ident, flags, qd, an, ns, ar = struct.unpack('!HHHHHH', body[:12])
        if ident != 0x1408 or not flags & 0x8000:
            raise ValueError('Mismatched DNS response')
        row.update(rcode=flags & 15, answerCount=an, bytes=len(body))
    except Exception as error:
        row['errorType'] = type(error).__name__
    row['elapsedMs'] = round((time.monotonic() - started) * 1000)
    rows.append(row)
report = {'endpoint': endpoint, 'host': 'linux.do', 'method': 'DNS-wire GET', 'results': rows,
          'scope': 'Only this machine DNS query. Not iPhone traffic or WebView coverage.'}
text = json.dumps(report, indent=2)
print(text)
if len(sys.argv) > 1:
    from pathlib import Path
    Path(sys.argv[1]).write_text(text, encoding='utf-8')
sys.exit(0 if all(r.get('rcode') == 0 for r in rows) and rows[0].get('answerCount', 0) > 0 else 1)
