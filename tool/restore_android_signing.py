"""Restore the persistent ProjectTabi signing key from Actions secrets."""
import argparse
import base64
import os
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--require', action='store_true')
args = parser.parse_args()
names = ['ANDROID_KEYSTORE_BASE64', 'ANDROID_KEYSTORE_PASSWORD', 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD']
available = all(os.environ.get(name) for name in names)
if not available:
    print('Persistent Android signing is not configured. No installable release will be published.')
    if args.require:
        raise SystemExit(1)
else:
    key_name = 'projecttabi-release.jks'
    Path('android/app', key_name).write_bytes(
        base64.b64decode(os.environ[names[0]], validate=True)
    )
    key = Path('android/app', key_name)
    key.chmod(0o600)

    def prop(value):
        return (value.replace('\\', '\\\\').replace('\n', '\\n')
                .replace('\r', '\\r').replace('=', '\\=')
                .replace(':', '\\:').replace(' ', '\\ '))

    values = {
        'storeFile': key_name,
        'storePassword': os.environ[names[1]],
        'keyAlias': os.environ[names[2]],
        'keyPassword': os.environ[names[3]],
    }
    props = Path('android/key.properties')
    props.write_text(''.join(f'{name}={prop(value)}\n' for name, value in values.items()))
    props.chmod(0o600)
    print('Persistent ProjectTabi signing restored.')
if os.environ.get('GITHUB_OUTPUT'):
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'ready={str(available).lower()}\n')
