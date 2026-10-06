import json, statistics
from pathlib import Path

out = Path(__file__).resolve().parent
settings = json.loads((out / 'settings.json').read_text())
apps = ('swift-before', 'swift-after', 'rust')
runs = {app: [json.loads(p.read_text()) for p in sorted(out.glob(f'{app}-*.json'))] for app in apps}
routes = settings['workloads']
for app in apps:
    assert len(runs[app]) == settings['reps'], f'{app}: incomplete repetitions'
    for run in runs[app]:
        assert set(h['route'] for h in run['http']) == set(routes)
        for h in run['http']:
            assert h['errors'] == 0 and set(h['statuses']) == {'200'} and h['latency']['n'] > 0, (app, h['route'])

def measurements(app, route, field='rps'):
    rows = [next(h for h in run['http'] if h['route'] == route) for run in runs[app]]
    return [h['rps'] if field == 'rps' else h['latency'][field] for h in rows]

def median(values): return statistics.median(values)
def cell(values): return f'{median(values):,.1f} [{min(values):,.1f}–{max(values):,.1f}]'

lines = ['# Swift performance improvements — 2026-10-06', '',
'Three repetitions per image; 16 concurrent keep-alive clients; 8 seconds measured after 2 seconds of warmup per workload. Server CPUs: 0–3; load generator: 4–7; host networking. Each run resets a copy of the same Rust default seed. App order reverses on even repetitions.', '',
'Host: Intel Core i7-1255U, 12 hardware threads, 23 GB RAM. These results compare the implementations on this host; the published Basecamp table uses different hardware.', '',
'## HTTP throughput', '',
'Cells are median [minimum–maximum] requests/second.', '',
'| Workload | Swift original | Swift optimized | Rust | Swift gain |',
'|---|---:|---:|---:|---:|']
summary = {}
for route in routes:
    values = {app: measurements(app, route) for app in apps}
    gain = median(values['swift-after']) / median(values['swift-before'])
    summary[route] = {app: median(values[app]) for app in apps} | {'gain': gain}
    lines.append(f"| {route} | {cell(values['swift-before'])} | {cell(values['swift-after'])} | {cell(values['rust'])} | {gain:.1f}× |")
lines += ['', 'All five workloads returned HTTP 200 with zero transport errors in every measured repetition.', '',
'## Latency', '', '| Workload | Original p50 / p90 / p99 (ms) | Optimized p50 / p90 / p99 (ms) | Rust p50 / p90 / p99 (ms) |', '|---|---:|---:|---:|']
for route in routes:
    cells = [' / '.join(f'{median(measurements(app, route, p)):.2f}' for p in ('p50_ms', 'p90_ms', 'p99_ms')) for app in apps]
    lines.append(f"| {route} | {' | '.join(cells)} |")
lines += ['', '## Startup and memory', '', '| Metric | Swift original | Swift optimized | Rust |', '|---|---:|---:|---:|']
for name, getter in [
    ('Cold start (ms)', lambda r:r['cold_start_ms']),
    ('Idle cgroup memory (MiB)', lambda r:r['memory']['idle_current_mb']),
    ('Idle anonymous memory (MiB)', lambda r:r['memory']['idle_anon_mb']),
    ('Peak sampled cgroup memory (MiB)', lambda r:r['memory']['peak_current_mb']),
    ('Peak sampled anonymous memory (MiB)', lambda r:r['memory']['peak_anon_mb']),
]:
    lines.append(f"| {name} | " + ' | '.join(cell([getter(r) for r in runs[app]]) for app in apps) + ' |')
loads = [float(r['loadavg_start'].split()[0]) for app in apps for r in runs[app]]
lines += ['', f'One-minute load average at run starts ranged from {min(loads):.2f} to {max(loads):.2f}; normal host activity contributes measurement noise.', '',
'## Changes and validation', '',
'- PBKDF2 keys are retained across signer instances in a bounded cache keyed by secret, salt and length. The original iteration count and digest remain unchanged.',
'- Digest hexadecimal encoding uses UTF-8 bytes, preserving exact signatures and ETags.',
'- Immutable timestamp interpretations are memoized with a 4,096-entry limit. The existing date parser and rounding remain unchanged, and no database rows or HTTP responses are cached by this change.',
'- 36 release-mode tests passed in Swift 6.4 Linux, with the seed required and no skipped integration tests.',
'- Original and optimized read responses matched byte-for-byte with identical Host inputs; selected headers and ETags also matched. See `response-parity.json`.', '',
'The `crypto-only/` directory contains the first complete intermediate repetition. It showed that crypto reuse alone improved the sidebar greatly but left timestamp parsing as a bottleneck for message pages. Interrupted samples were excluded.', '',
'## Reproduce', '',
'Build with the repository Dockerfile and run the command in `command.txt`. The original image is from commit `65a938d`; the optimized image includes the local changes. Image IDs, settings and source checksums are in `settings.json` and `env.txt`. `run-http` copies the Rust harness at `ccece30`, adding Swift image aliases and limiting measurement to the five published HTTP workloads.', '',
'Action Cable, uploads and auxiliary asset routes are excluded. The previously observed Swift stylesheet 404 remains outside this performance change.', '',
'```text', (out/'env.txt').read_text().strip(), '```', '']
(out/'report.md').write_text('\n'.join(lines))
(out/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
print(json.dumps(summary, indent=2))
