#!/usr/bin/env python3
"""Validate roadmap traceability without requiring the original source archive."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import sys
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / 'docs' / 'roadmap'
DOC_PATHS = {
    'README.md', 'DOCUMENTATION.md', 'ROADMAP.md', 'RELEASE_NOTES.md',
    'UI_SYSTEM.md', 'VALIDATION.md', 'docs/MODERN_WORKFLOWS.md',
    'docs/TRANSPORT_DEPENDENCIES.md', 'relay-kafka-client/README.md',
    'packaging/macos/README.md', 'docs/RELEASE_PREPARATION.md',
}


def scoped(path):
    if not path.startswith('relay/') or path.endswith('/') or '/docs/javadoc/' in path:
        return False
    relative = path[len('relay/'):]
    return (relative in DOC_PATHS
            or (('/src/main/' in path or '/src/test/' in path) and path.endswith('.java'))
            or path.endswith('pom.xml') or relative.endswith('.sh')
            or relative.startswith('scripts/') or '/src/main/resources/' in path
            or relative == 'BASELINE_TEST_SHA256.json')


def render(rows):
    lines = [
        '# Capability register', '',
        'Audit date: 2026-10-24. Reference: supplied Relay 1.0.0 archive. Baseline Rill: `abd4371`.', '',
        f'{len(rows)} tracked capabilities. **Partial** means a subset exists in Rill, not that parity is established. **Planned** means no dedicated implementation has been verified. No baseline row is marked parity-complete.', '',
        'Each row is a required scope item, not a promise of full protocol/specification conformance. A row becomes **verified** only with linked Rill implementation, tests and any necessary manual evidence. Approved intentional differences use **deviation** with rationale and owner approval; they never disappear from the register.', '',
        'The authoritative editable checklist is [capabilities.csv](capabilities.csv). This readable register is generated from it. Evidence keys resolve to source paths and hashes in [reference-inventory.json](reference-inventory.json); the original archive is deliberately not committed.', '',
        'See [roadmap](../../ROADMAP.md) for sequencing and dependencies.', '',
    ]
    for group in dict.fromkeys(row['group'] for row in rows):
        lines.extend([
            '## ' + group, '',
            '| ID | Stage | Rill baseline/status | Capability | Acceptance evidence required | Reference keys | Rill verification / decision |',
            '| --- | --- | --- | --- | --- | --- | --- |',
        ])
        for row in rows:
            if row['group'] != group:
                continue
            cells = [row[key] for key in ['id', 'milestone', 'status', 'capability', 'acceptance', 'evidence']]
            cells.append('; '.join(value for value in [row['verification'], row['decision']] if value))
            lines.append('| ' + ' | '.join(cell.replace('|', '\\|').replace('\n', ' ') for cell in cells) + ' |')
        lines.append('')
    return '\n'.join(lines).rstrip() + '\n'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def audit(args):
    with (DOCS / 'capabilities.csv').open(newline='') as stream:
        reader = csv.DictReader(stream)
        require(reader.fieldnames == ['id', 'group', 'milestone', 'status', 'capability', 'acceptance', 'evidence', 'verification', 'decision'], 'Unexpected checklist columns')
        rows = list(reader)
    require(bool(rows), 'Checklist is empty')
    ids = {row['id'] for row in rows}
    require(len(ids) == len(rows), 'Duplicate capability ID')
    require({row['milestone'] for row in rows} == {f'M{i}' for i in range(10)}, 'Milestone set must cover M0 through M9')
    manifest = json.loads((DOCS / 'reference-inventory.json').read_text())
    sources = manifest['sources']
    require(len({source['path'] for source in sources}) == len(sources), 'Duplicate inventory path')
    evidence_keys = {source['key'] for source in sources} | {source['key'] for source in manifest['local_evidence']}
    for row in rows:
        require(re.fullmatch(r'[A-Z]+-\d{2,}', row['id']) is not None, f"Invalid ID: {row['id']}")
        require(row['status'] in {'planned', 'partial', 'verified', 'deviation'}, f"Invalid status: {row['id']}")
        for key in ['group', 'capability', 'acceptance', 'evidence']:
            require(bool(row[key].strip()), f"Missing {key}: {row['id']}")
        require(set(row['evidence'].split(';')) <= evidence_keys, f"Unknown evidence key: {row['id']}")
        if row['status'] == 'verified':
            require(bool(row['verification'].strip()), f"Verified row needs implementation and test evidence: {row['id']}")
        if row['status'] == 'deviation':
            require(bool(row['decision'].strip()), f"Deviation needs owner-approved decision: {row['id']}")
    for source in sources:
        require(scoped(source['path']), f"Out-of-scope inventory entry: {source['path']}")
        require(bool(source['capability_ids']) and set(source['capability_ids']) <= ids, f"Unowned/invalid source mapping: {source['path']}")
        require(re.fullmatch(r'[0-9a-f]{64}', source['sha256']) is not None, f"Invalid source fingerprint: {source['path']}")
    for source in manifest['local_evidence']:
        if 'path' in source:
            require((ROOT / source['path']).is_file(), f"Missing Rill evidence: {source['path']}")
    expected = render(rows)
    register = DOCS / 'CAPABILITIES.md'
    if args.render:
        register.write_text(expected)
    require(register.read_text() == expected, 'Readable register is stale; run python3 scripts/audit-roadmap.py --render')
    for name in ['ROADMAP.md', 'docs/roadmap/PARITY-BOUNDARIES.md', 'docs/roadmap/ACCEPTANCE.md']:
        require((ROOT / name).is_file(), f'Missing roadmap document: {name}')
    if args.archive:
        archive = Path(args.archive)
        require(hashlib.sha256(archive.read_bytes()).hexdigest() == manifest['archive_sha256'], 'Archive fingerprint differs from the audited baseline')
        with ZipFile(archive) as zipped:
            require({name for name in zipped.namelist() if scoped(name)} == {source['path'] for source in sources}, 'Archive inventory coverage differs')
            for source in sources:
                require(hashlib.sha256(zipped.read(source['path'])).hexdigest() == source['sha256'], f"Source fingerprint differs: {source['path']}")
    counts = {status: sum(row['status'] == status for row in rows) for status in ['planned', 'partial', 'verified', 'deviation']}
    print(f'Roadmap audit passed: {len(rows)} capabilities, {len(sources)} indexed files, {counts}')
    print('Archive fingerprints verified.' if args.archive else 'Original archive not supplied; reference fingerprints were not reverified.')
    print('Traceability is not behavioral verification; close rows with implementation and acceptance evidence.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', help='Optional path to the separately retained Relay ZIP; never downloaded or committed')
    parser.add_argument('--render', action='store_true', help='Regenerate CAPABILITIES.md from the editable CSV')
    args = parser.parse_args()
    try:
        audit(args)
    except (ValueError, KeyError, OSError, csv.Error) as error:
        print(f'Roadmap audit failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
