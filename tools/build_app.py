#!/usr/bin/env python3
"""Build the V1 app with only its Android AK, never private places/server keys."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

from scan_apk_secrets import read_env

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--release', action='store_true')
args = parser.parse_args()
key = os.environ.get('BAIDU_ANDROID_AK') or read_env(root / '.env.local').get('BAIDU_ANDROID_AK')
if not key:
    sys.exit('Missing BAIDU_ANDROID_AK in environment or ignored .env.local')
env = os.environ.copy()
env['BAIDU_ANDROID_AK'] = key
for name in ('BAIDU_MAP_AK', 'BAIDU_MAP_SK', 'BAIDU_AK', 'BAIDU_SK', 'PROBE_PLACES_JSON'):
    env.pop(name, None)
subprocess.run(['flutter', 'build', 'apk', '--release' if args.release else '--debug',
                '--target=lib/main.dart'], cwd=root / 'app', env=env, check=True)
