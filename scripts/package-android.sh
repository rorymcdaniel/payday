#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
if [ -z "${JAVA_HOME:-}" ] && [ -x /usr/libexec/java_home ]; then
    export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
fi
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export PAYDAY_SIGNING_PROPERTIES="${PAYDAY_SIGNING_PROPERTIES:-$HOME/.local/share/payday/android-signing/signing.properties}"
python3 - <<'PY'
import os
from pathlib import Path
import secrets
import subprocess
properties = Path(os.environ['PAYDAY_SIGNING_PROPERTIES']).expanduser().resolve()
if not properties.exists():
    directory = properties.parent
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = directory / 'payday-personal.p12'
    if key.exists():
        raise SystemExit('A signing key already exists without its settings. Restore signing.properties; the key will not be replaced.')
    password = secrets.token_urlsafe(36)
    environment = dict(os.environ, PAYDAY_KEY_PASSWORD=password)
    keytool = str(Path(os.environ['JAVA_HOME']) / 'bin/keytool') if os.environ.get('JAVA_HOME') else 'keytool'
    subprocess.run([keytool, '-genkeypair', '-keystore', str(key), '-storetype', 'PKCS12', '-storepass:env', 'PAYDAY_KEY_PASSWORD',
        '-keypass:env', 'PAYDAY_KEY_PASSWORD', '-alias', 'payday-personal', '-keyalg', 'RSA', '-keysize', '3072',
        '-validity', '10000', '-dname', 'CN=Payday Personal', '-noprompt'], env=environment, check=True)
    properties.write_text(f'storeFile={key}\nstorePassword={password}\nkeyAlias=payday-personal\nkeyPassword={password}\n')
    key.chmod(0o600)
    properties.chmod(0o600)
PY
android/gradlew -p android :app:testDebugUnitTest :app:lintRelease :app:assembleRelease --console=plain
mkdir -p dist
cp android/app/build/outputs/apk/release/app-release.apk dist/Payday-android.apk
"$ANDROID_HOME/build-tools/35.0.0/apksigner" verify --verbose dist/Payday-android.apk
printf 'Built dist/Payday-android.apk\nKeep the private signing folder for future app updates: %s\n' "$(dirname "$PAYDAY_SIGNING_PROPERTIES")"
