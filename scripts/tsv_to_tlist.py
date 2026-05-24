#!/usr/bin/env python3
"""Convert a trace-metadata TSV file into a ChampSim trace list YML.

The TSV is expected to have a header row with at least these columns:
    name, path, version, workload, weight, category, tag

The output YML groups all traces under a single top-level key (default: "spec26")
and matches the indentation style of scripts/example_tlist.yml.
"""

import argparse
import csv
import sys
from pathlib import Path


def parse_tags(raw):
    """Parse a TSV tag cell like '[specrate, specint]' into a list of tokens."""
    if raw is None:
        return []
    s = raw.strip()
    if s.startswith('"') and s.endswith('"'):
        s = s[1:-1].strip()
    if s.startswith('['):
        s = s[1:]
    if s.endswith(']'):
        s = s[:-1]
    return [t.strip() for t in s.split(',') if t.strip()]


def format_tags(tags):
    return '[' + ', '.join(tags) + ']' if tags else '[]'


def convert(tsv_path: Path, out_path: Path, group: str) -> int:
    with tsv_path.open(newline='') as f:
        reader = csv.DictReader(f, delimiter='\t', quotechar='"')
        rows = list(reader)

    required = {'name', 'path', 'version', 'workload', 'weight', 'category', 'tag'}
    missing = required - set(reader.fieldnames or [])
    if missing:
        raise ValueError(f"TSV missing required columns: {sorted(missing)}")

    lines = ['---', '', f'{group}:']
    for row in rows:
        tags_yaml = format_tags(parse_tags(row['tag']))
        weight = row['weight'].strip()
        lines.append(f'      - {row["name"]}:')
        lines.append(f'                path: {row["path"]}')
        lines.append(f'                version: {row["version"]}')
        lines.append(f'                workload: {row["workload"]}')
        lines.append(f'                weight: {weight}')
        lines.append(f'                category: {row["category"]}')
        lines.append(f'                subcategory:')
        lines.append(f'                tags: {tags_yaml}')
        lines.append(f'                checksum:')

    out_path.write_text('\n'.join(lines) + '\n')
    return len(rows)


def main():
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        '--tsv',
        type=Path,
        default=repo_root / 'spec26_metadata.tsv',
        help='Input TSV file (default: %(default)s)',
    )
    parser.add_argument(
        '--out',
        type=Path,
        default=repo_root / 'spec26_tlist.yml',
        help='Output YML file (default: %(default)s)',
    )
    parser.add_argument(
        '--group',
        default='spec26',
        help='Top-level YML key under which all traces are grouped (default: %(default)s)',
    )
    args = parser.parse_args()

    if not args.tsv.is_file():
        print(f'error: TSV not found: {args.tsv}', file=sys.stderr)
        sys.exit(1)

    n = convert(args.tsv, args.out, args.group)
    print(f'Wrote {n} traces to {args.out}')


if __name__ == '__main__':
    main()
