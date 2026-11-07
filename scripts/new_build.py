"""Starts a new build: raises the build number and records its patch note.

Run from the project root, before building:

    python scripts/new_build.py "Fixed the guide skipping channels"

Give the note more arguments for more bullet points.
"""
import datetime
import pathlib
import re
import sys

HEADER = '# Changelog\n'


def main(notes):
    if not any(n.strip() for n in notes):
        sys.exit('Every build needs a patch note.')

    pubspec = pathlib.Path('pubspec.yaml')
    text = pubspec.read_text(encoding='utf8')
    match = re.search(r'^version: (\d+\.\d+\.\d+)\+(\d+)\s*$', text, re.M)
    if match is None:
        sys.exit('No version: x.y.z+n line in pubspec.yaml.')
    version, build = match[1], int(match[2]) + 1
    text = text[:match.start()] + f'version: {version}+{build}' + text[match.end():]

    changelog = pathlib.Path('CHANGELOG.md')
    log = changelog.read_text(encoding='utf8')
    if not log.startswith(HEADER):
        sys.exit('CHANGELOG.md must start with its title.')
    bullets = ''.join(f'- {n.strip()}\n' for n in notes if n.strip())
    entry = f'\n## Build {build} ({version}) - {datetime.date.today()}\n\n{bullets}'

    # Written last and together, so a failure above leaves both files alone.
    changelog.write_text(HEADER + entry + log[len(HEADER):], encoding='utf8', newline='\n')
    pubspec.write_text(text, encoding='utf8', newline='\n')
    print(f'Build {build} ({version})')


if __name__ == '__main__':
    main(sys.argv[1:])
