#!/usr/bin/env python3
"""Install the launcher for a persistent bundle; no system-wide writes or root."""
import argparse
import os
from pathlib import Path
import shutil

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('bundle', type=Path, help='Directory containing quran_reel_maker, data and lib')
args = parser.parse_args()
bundle = args.bundle.resolve()
executable = bundle / 'quran_reel_maker'
if not executable.is_file() or not os.access(executable, os.X_OK):
    parser.error('Build the Linux release first; bundle executable is missing.')
root = Path(__file__).resolve().parent.parent
# Desktop Entry Exec quoting is not shell quoting. Escape reserved characters.
if any(c in str(executable) for c in ('\n', '\r', '=')):
    parser.error('Use a bundle path without newlines or equals signs (Desktop Entry Exec restriction).')
quoted = ''.join('\\' + c if c in '\\"`$' else c for c in str(executable))
# General string escaping is decoded before Exec argument quoting.
quoted = quoted.replace('\\', '\\\\').replace('%', '%%')
data = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share'))
applications = data / 'applications'
applications.mkdir(parents=True, exist_ok=True)
app_id = 'com.example.quran_reel_maker'
text = (root / f'linux/packaging/{app_id}.desktop').read_text()
text = text.replace('Exec=quran_reel_maker', f'Exec="{quoted}"')
for size in (64, 128, 256, 512):
    icons = data / f'icons/hicolor/{size}x{size}/apps'
    icons.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(root / f'linux/packaging/icons/quran-reel-maker-{size}.png', icons / f'{app_id}.png')
destination = applications / f'{app_id}.desktop'
destination.write_text(text)
print(f'Installed {destination}. Keep the bundle at {bundle}.')
