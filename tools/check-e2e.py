#!/usr/bin/env python3
"""Exercise the Swift app against official E2E implementations (Node 24+).

python3 tools/check-e2e.py --reference /path/to/OpenMausBot --relay
The reference must contain companion/src/e2e at commit
6f226f15def56c697626f2ed6dffac416510c79a or an API-compatible revision.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import urllib.error
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--reference', type=Path, required=True)
parser.add_argument('--app', type=Path, default=Path('build/Build/Products/Debug/MausBot.app/Contents/MacOS/MausBot'))
parser.add_argument('--relay', action='store_true', help='Run the DEBUG-only local relay protocol fixture')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
app = args.app.resolve()
children = []


def launch(command, **kwargs):
    child = subprocess.Popen(command, stdout=subprocess.PIPE, text=True, **kwargs)
    children.append(child)
    line = child.stdout.readline()
    assert json.loads(line).get('ready'), 'reference server failed to start'


def run(*arguments):
    # Credentials are test-only and never echoed in the command or failures.
    child = subprocess.run([str(app), '--selfcheck', *arguments], capture_output=True, text=True, timeout=60)
    print(child.stdout, end='')
    if child.returncode:
        print(child.stderr)
        raise RuntimeError('Swift interoperability check failed')


base = 'http://127.0.0.1:18992'


def get(path):
    with urllib.request.urlopen(base + path, timeout=5) as response:
        return json.load(response)


def plain_pair(name):
    link = get('/test/invite')['link']
    credential = urllib.parse.parse_qs(urllib.parse.urlparse(link).query)['token'][0]
    request = urllib.request.Request(base + '/api/pair',
                                    data=json.dumps({'credential': credential, 'deviceName': name}).encode(),
                                    headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)


try:
    launch(['node', str(args.reference.resolve() / 'companion/src/e2e/interop-server.ts'), '--port', '18991'])
    env = dict(os.environ, OMB_REFERENCE_DIR=str(args.reference.resolve()))
    launch(['node', str(root / 'tools/e2e-companion-test.mjs')], env=env)
    run('protocol')
    run('e2e', '--url', 'http://127.0.0.1:18991')
    run('app', '--link', get('/test/invite')['link'], '--e2e-locations')
    paired = plain_pair('Legacy migration fixture')
    run('upgrade', '--url', base, '--token', paired['token'])
    if args.relay:
        paired_relay = plain_pair('Relay fixture')
        descriptor = base64.urlsafe_b64encode(json.dumps(paired_relay['e2e']).encode()).decode().rstrip('=')
        run('e2e-relay', '--url', 'ws://127.0.0.1:18992/test/relay', '--descriptor', descriptor, '--token', paired_relay['token'])
    devices = get('/test/devices')
    assert devices and all(d.get('e2eAt') for d in devices), 'official DeviceRegistry did not mark encrypted devices'
    print('PASS official DeviceRegistry.e2eAt recorded for every paired device')
    request = urllib.request.Request(base + '/api/bots', headers={'Authorization': 'Bearer ' + paired['token']})
    try:
        urllib.request.urlopen(request, timeout=5)
        raise AssertionError('legacy HTTP still accepted after upgrade')
    except urllib.error.HTTPError as error:
        assert error.code == 426
    print('PASS official proxy refuses old HTTP after E2E upgrade (426)')
finally:
    for child in children:
        child.terminate()
    for child in children:
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
