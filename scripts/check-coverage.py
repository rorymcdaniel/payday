#!/usr/bin/env python3
"""Enforce LLVM line coverage without a hosted service or uploaded financial data."""
import argparse
import json
from pathlib import Path
import re
import subprocess


def executable_lines(segments):
    """Map executable lines to their highest count, including multiline regions."""
    result = {}
    previous = None
    for segment in segments:
        line, column, count, has_count = segment[:4]
        if previous is not None and previous[3]:
            end = line if column > 1 else line - 1
            for number in range(previous[0], end + 1):
                result[number] = max(result.get(number, 0), previous[2])
        if has_count:
            result[line] = max(result.get(line, 0), count)
        previous = segment
    return result


def changed_lines(diff):
    result = {}
    path = None
    for line in diff.splitlines():
        if line.startswith('+++ b/'):
            path = line[6:]
        elif line.startswith('+++ '):
            path = None
        elif path and line.startswith('@@ '):
            match = re.search(r'\+(\d+)(?:,(\d+))? @@', line)
            if match:
                start = int(match[1])
                count = int(match[2]) if match[2] is not None else 1
                result.setdefault(path, set()).update(range(start, start + count))
    return result


def measured(path):
    return path.startswith('Sources/PaydayCore/') or path in {
        'Sources/Payday/AppModel.swift', 'Sources/Payday/CentsTextField.swift'
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report')
    parser.add_argument('--base', help='PR base commit; compare its merge base with HEAD')
    args = parser.parse_args()
    root = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip())
    files = {}
    for data in json.loads(Path(args.report).read_text())['data']:
        for item in data['files']:
            try:
                path = str(Path(item['filename']).relative_to(root))
            except ValueError:
                continue
            files[path] = item
    failures = []

    def require(label, covered, total, threshold):
        if total == 0:
            failures.append(f'{label}: no executable coverage data')
            return
        percentage = 100 * covered / total
        print(f'{label}: {covered}/{total} lines ({percentage:.2f}%; minimum {threshold}%)')
        if percentage < threshold:
            failures.append(f'{label} is below {threshold}%')

    core = [f['summary']['lines'] for p, f in files.items() if p.startswith('Sources/PaydayCore/')]
    require('Financial core', sum(f['covered'] for f in core), sum(f['count'] for f in core), 90)
    engine = files.get('Sources/PaydayCore/AllocationEngine.swift', {}).get('summary', {}).get('lines', {})
    require('Allocation engine', engine.get('covered', 0), engine.get('count', 0), 95)
    if args.base:
        diff = subprocess.check_output(['git', 'diff', '--no-ext-diff', '--unified=0', f'{args.base}...HEAD', '--', 'Sources'], text=True)
        covered = total = 0
        for path, changed in changed_lines(diff).items():
            if not measured(path) or not path.endswith('.swift') or not changed:
                continue
            if path not in files:
                failures.append(f'{path}: changed source missing from coverage report')
                continue
            lines = executable_lines(files[path]['segments'])
            affected = changed & lines.keys()
            total += len(affected)
            covered += sum(lines[line] > 0 for line in affected)
        if total:
            require('Changed executable lines', covered, total, 80)
        else:
            print('No changed executable lines in measured source.')
    if failures:
        raise SystemExit('\n'.join(failures))


if __name__ == '__main__':
    main()
