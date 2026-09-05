#!/usr/bin/env python3
"""Bounded, source-aware advisory reviews. Standard library only; never executes PR code."""

import base64
import hashlib
import html
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

MARKER = '<!-- spotty-opencode-review:v1 -->'
WORKFLOW = '.github/workflows/opencode-spike.yml'
BOT = 'github-actions[bot]'
SHA = re.compile(r'[0-9a-f]{40}')
MAX_FILE = 1_000_000
MAX_SNAPSHOT = 25_000_000
MAX_DIFF = 200_000
MAX_FINDINGS = 20


def require(condition, message):
    if not condition:
        raise ValueError(message)


def git(*args, check=True):
    return subprocess.run(['git', *args], check=check, capture_output=True).stdout


def api(path, token, method='GET', data=None):
    return request('https://api.github.com/' + path, token, method, data)


def request(url, token, method='GET', data=None):
    headers = {'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
               'Content-Type': 'application/json', 'User-Agent': 'Spotty-review'}
    raw = None if data is None else json.dumps(data).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, raw, headers, method=method), timeout=60) as response:
            body = response.read()
    except urllib.error.HTTPError as error:
        # Do not include response bodies or request headers (which can contain credentials).
        raise RuntimeError(f'HTTP {error.code} from {urllib.parse.urlsplit(url).hostname}') from None
    return json.loads(body) if body else None


def comments(repo, pr, token):
    result = []
    for page in range(1, 101):
        batch = api(f'repos/{repo}/issues/{pr}/comments?per_page=100&page={page}', token)
        result.extend(batch)
        if len(batch) < 100:
            return result
    raise ValueError('Comment pagination exceeded safety bound')


def owned_comments(items):
    return [item for item in items if item.get('user', {}).get('login') == BOT
            and (item.get('body') or '').startswith(MARKER + '\n')]


def decode_state(body):
    match = re.search(r'\n<!-- state:([A-Za-z0-9+/=]+) -->$', body)
    require(match is not None, 'Missing review state')
    require(len(match[1]) < 60_000, 'Review state too large')
    state = json.loads(base64.b64decode(match[1], validate=True))
    require(isinstance(state, dict) and state.get('schema') == 1, 'Unsupported review state')
    findings = state.get('findings')
    require(isinstance(findings, list) and len(findings) <= MAX_FINDINGS, 'Invalid baseline findings')
    identities = set()
    for item in findings:
        require(isinstance(item, dict) and set(item) == {'id', 'path', 'line', 'severity', 'title', 'body'},
                'Invalid baseline finding schema')
        require(isinstance(item['id'], str) and re.fullmatch(r'F[0-9a-f]{12}', item['id'])
                and item['id'] not in identities, 'Invalid baseline finding ID')
        require(isinstance(item['path'], str) and safe_path(item['path'])
                and type(item['line']) is int and item['line'] > 0, 'Invalid baseline location')
        require(item['severity'] in ('P1', 'P2', 'P3'), 'Invalid baseline severity')
        bounded_text(item['title'], 160, 'baseline title')
        bounded_text(item['body'], 1500, 'baseline body')
        identities.add(item['id'])
    return state


def policy_digest():
    digest = hashlib.sha256()
    for name in (WORKFLOW, '.github/review/review.py', '.github/review/prompt.txt'):
        digest.update(name.encode() + b'\0' + Path(name).read_bytes())
    return digest.hexdigest()


def compatible(state, meta, ancestor):
    """Only a compatible ancestor can narrow coverage. Reruns deliberately review in full."""
    return (state.get('repo') == meta['repo'] and state.get('pr') == meta['pr']
            and state.get('base') == meta['base'] and state.get('policy') == meta['policy']
            and isinstance(state.get('head'), str) and SHA.fullmatch(state['head']) is not None
            and ancestor(state['head'], meta['head']))


def is_ancestor(base, head):
    return subprocess.run(['git', 'merge-base', '--is-ancestor', base, head], capture_output=True).returncode == 0


def find_baseline(items, meta, token):
    for item in reversed(owned_comments(items)):
        try:
            state = decode_state(item['body'])
            if not compatible(state, meta, is_ancestor):
                continue
            run, attempt = state['run'], state['attempt']
            require(type(run) is int and run > 0 and type(attempt) is int and attempt > 0, 'Invalid run identity')
            proof = api(f"repos/{meta['repo']}/actions/runs/{run}/attempts/{attempt}", token)
            require(proof['conclusion'] == 'success' and proof['event'] == 'pull_request'
                    and proof['head_sha'] == state['head'] and proof['path'] == WORKFLOW
                    and proof['head_repository']['full_name'] == meta['repo'], 'Unverified baseline run')
            require(isinstance(state['findings'], list) and len(state['findings']) <= MAX_FINDINGS, 'Invalid baseline findings')
            return state
        except (ValueError, KeyError, TypeError, RuntimeError):
            # Invalid/incompatible state only causes MORE coverage, never an empty success.
            continue
    return None


def safe_path(name):
    path = PurePosixPath(name)
    return bool(name) and not path.is_absolute() and '..' not in path.parts and '\\' not in name \
        and all(ord(char) >= 32 for char in name) and '.git' not in path.parts


def snapshot(revision, destination):
    """Read raw Git blobs, ignoring export-ignore, filters and symlinks; no archive extraction."""
    entries = []
    omitted = []
    total = 0
    for record in git('ls-tree', '-r', '-z', '--long', revision).split(b'\0'):
        if not record:
            continue
        info, raw_name = record.split(b'\t', 1)
        mode, kind, oid, raw_size = info.decode().split()
        name = raw_name.decode('utf-8')
        require(safe_path(name), 'Unsupported repository path')
        if mode not in ('100644', '100755') or kind != 'blob' or int(raw_size) > MAX_FILE:
            omitted.append(name)
            continue
        entries.append((name, oid, int(raw_size)))
        total += int(raw_size)
    require(total <= MAX_SNAPSHOT, 'Source snapshot exceeds 25 MB; refusing partial source coverage')
    batch = subprocess.run(['git', 'cat-file', '--batch'], input=''.join(oid + '\n' for _, oid, _ in entries).encode(),
                           capture_output=True, check=True).stdout
    offset = 0
    files = {}
    for name, oid, size in entries:
        end = batch.index(b'\n', offset)
        require(batch[offset:end].decode() == f'{oid} blob {size}', 'Unexpected Git blob framing')
        content = batch[end + 1:end + 1 + size]
        offset = end + 2 + size
        try:
            text = content.decode('utf-8')
            require('\0' not in text, 'Binary file')
        except (UnicodeDecodeError, ValueError):
            omitted.append(name)
            continue
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        target.chmod(0o444)
        files[name] = len(text.splitlines())
    return files, omitted


def check_current(meta, token):
    pr = api(f"repos/{meta['repo']}/pulls/{meta['pr']}", token)
    require(pr['state'] == 'open' and pr['head']['sha'] == meta['head'] and pr['base']['sha'] == meta['base'],
            'PR moved or closed; refusing stale review publication')


def prepare(work):
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    pr = event['pull_request']
    repo = os.environ['GITHUB_REPOSITORY']
    require(pr['head']['repo']['full_name'] == repo, 'Fork input is not enabled for this trial')
    meta = {'schema': 1, 'repo': repo, 'pr': pr['number'], 'base': pr['base']['sha'], 'head': pr['head']['sha'],
            'run': int(os.environ['GITHUB_RUN_ID']), 'attempt': int(os.environ['GITHUB_RUN_ATTEMPT']),
            'policy': policy_digest(), 'model': os.environ['MODEL'], 'variant': os.environ['VARIANT'],
            'opencode': os.environ['OPENCODE_VERSION']}
    require(SHA.fullmatch(meta['head']) and SHA.fullmatch(meta['base']), 'Invalid revision')
    token = os.environ['GH_TOKEN']
    check_current(meta, token)
    baseline = find_baseline(comments(repo, pr['number'], token), meta, token)
    merge_base = git('merge-base', meta['base'], meta['head']).decode().strip()
    previous = baseline['findings'] if baseline else []
    incremental = baseline is not None and baseline['head'] != meta['head']
    start = baseline['head'] if incremental else merge_base
    meta.update(mode='incremental' if incremental else 'full', start=start,
                previous=previous, baseline=baseline['head'] if baseline else None)
    source = work / 'input'
    source.mkdir(parents=True)
    (work / 'output').mkdir()
    files, omitted = snapshot(meta['head'], source / 'source')
    _, omitted_before = snapshot(start, source / 'before')
    for name, base in (('pr.diff', merge_base), ('delta.diff', start)):
        diff = git('diff', '--no-ext-diff', '--no-textconv', '--no-renames', base, meta['head'], '--')
        require(len(diff) <= MAX_DIFF, 'Diff exceeds 200 KB; refusing silent truncation')
        (source / name).write_text(diff.decode('utf-8'))
    changed = git('diff', '--name-only', '-z', '--no-renames', merge_base, meta['head'], '--').decode().split('\0')
    meta.update(files=files, changed=[path for path in changed if path], omitted=omitted, omitted_before=omitted_before)
    (source / 'review-input.json').write_text(json.dumps(meta, indent=2))
    (work / 'meta.json').write_text(json.dumps(meta))
    print(f"Prepared {meta['mode']} review: {len(meta['changed'])} PR files, {len(previous)} open findings")


def bounded_text(value, limit, label):
    require(isinstance(value, str) and 0 < len(value.strip()) <= limit, 'Invalid ' + label)
    return value.strip()


def validate_result(result, meta):
    require(isinstance(result, dict) and set(result) == {'summary', 'findings', 'resolved'}, 'Invalid response schema')
    summary = bounded_text(result['summary'], 2000, 'summary')
    require(isinstance(result['findings'], list) and len(result['findings']) <= MAX_FINDINGS, 'Too many findings')
    require(isinstance(result['resolved'], list), 'Invalid resolutions')
    previous = {finding['id']: finding for finding in meta['previous']}
    seen = set()
    findings = []
    for item in result['findings']:
        require(isinstance(item, dict) and set(item) == {'id', 'path', 'line', 'severity', 'title', 'body'}, 'Invalid finding schema')
        path, line = item['path'], item['line']
        require(isinstance(path, str) and path in meta['changed'] and path in meta['files'], 'Finding outside reviewed source')
        require(type(line) is int and 1 <= line <= meta['files'][path], 'Invalid finding line')
        require(item['severity'] in ('P1', 'P2', 'P3'), 'Invalid severity')
        title = bounded_text(item['title'], 160, 'title')
        body = bounded_text(item['body'], 1500, 'finding body')
        identity = item['id']
        canonical = 'F' + hashlib.sha256((path + '\0' + title.casefold()).encode()).hexdigest()[:12]
        require(isinstance(identity, str) and (not identity or identity in previous or identity == canonical), 'Unknown finding ID')
        if not identity:
            identity = canonical
            require(identity not in previous, 'Existing finding must retain its ID')
        require(identity not in seen, 'Duplicate finding ID')
        seen.add(identity)
        findings.append(dict(id=identity, path=path, line=line, severity=item['severity'], title=title, body=body))
    resolved = []
    for item in result['resolved']:
        require(isinstance(item, dict) and set(item) == {'id', 'reason'}, 'Invalid resolution schema')
        identity = item['id']
        require(isinstance(identity, str) and identity in previous and identity not in seen, 'Unknown/duplicate resolution')
        seen.add(identity)
        resolved.append({'id': identity, 'reason': bounded_text(item['reason'], 1000, 'resolution reason')})
    require(previous.keys() <= seen, 'A previous finding was silently dropped')
    return {'summary': summary, 'findings': findings, 'resolved': resolved}


def parse_events(raw):
    require(len(raw) <= 10_000_000, 'Model event stream too large')
    events = [json.loads(line) for line in raw.splitlines() if line.strip()]
    require(not any(event.get('type') == 'error' for event in events), 'OpenCode reported an error')
    finishes = [event['part'] for event in events if event.get('type') == 'step_finish']
    require(finishes and finishes[-1].get('reason') == 'stop', 'Model response incomplete or truncated')
    texts = [event['part']['text'] for event in events if event.get('type') == 'text']
    require(texts, 'Model returned no response')
    text = texts[-1].strip()
    if text.startswith('```json\n') and text.endswith('\n```'):
        text = text[8:-4]
    require(len(text) <= 50_000, 'Model response too large')
    return json.loads(text), events


def run_model(work, binary):
    meta = json.loads((work / 'meta.json').read_text())
    # No GitHub/App/OIDC/runner tokens, local credentials or shell environment reach the model.
    env = {'PATH': os.environ['PATH'], 'OPENCODE_DISABLE_PROJECT_CONFIG': 'true',
           'OPENCODE_DISABLE_AUTOUPDATE': 'true', 'OPENCODE_DISABLE_AUTOCOMPACT': 'true',
           'npm_config_cache': str(work / 'runtime' / 'npm-cache'),
           'OPENCODE_CONFIG_CONTENT': json.dumps({'share': 'disabled', 'small_model': meta['model'],
               'lsp': False, 'formatter': False,
               'permission': {'*': 'deny', 'read': 'allow', 'glob': 'allow', 'grep': 'allow', 'external_directory': 'deny'},
               'agent': {'build': {'steps': 30}}})}
    for kind in ('CONFIG', 'DATA', 'STATE', 'CACHE'):
        env[f'XDG_{kind}_HOME'] = str(work / 'runtime' / kind.lower())
    prompt = Path('.github/review/prompt.txt').read_text()
    started = time.monotonic()
    with (work / 'output/events.jsonl').open('w') as output, (work / 'output/model.log').open('w') as errors:
        subprocess.run([str(binary.resolve()), '--pure', 'run', '--model', meta['model'], '--variant', meta['variant'],
                        '--format', 'json', '--title', 'Spotty advisory review'],
                       cwd=work / 'input', env=env, input=prompt, text=True, stdout=output, stderr=errors,
                       check=True, timeout=600)
    result, events = parse_events((work / 'output/events.jsonl').read_text())
    validated = validate_result(result, meta)
    report = {'meta': meta, 'result': validated, 'seconds': round(time.monotonic() - started, 1),
              'tool_calls': sum(event.get('type') == 'tool_use' for event in events)}
    (work / 'output/report.json').write_text(json.dumps(report, indent=2))
    print(f"Validated {len(validated['findings'])} active findings and {len(validated['resolved'])} resolutions")


def render(report):
    meta, result = report['meta'], report['result']
    escape = lambda text: html.escape(text).replace('@', '&#64;')
    lines = [MARKER, '## OpenCode advisory review — not approval',
             f"Head `{meta['head']}` · {meta['mode']} · `{meta['model']}` / `{meta['variant']}`",
             f"[Run {meta['run']}, attempt {meta['attempt']}](https://github.com/{meta['repo']}/actions/runs/{meta['run']}/attempts/{meta['attempt']})",
             '<pre>' + escape(result['summary']) + '</pre>', '### Active findings']
    for finding in result['findings']:
        url = f"https://github.com/{meta['repo']}/blob/{meta['head']}/{urllib.parse.quote(finding['path'], safe='/')}#L{finding['line']}"
        lines += [f"**{finding['id']} · {finding['severity']}** [source]({url})",
                  '<pre>' + escape(finding['title'] + '\n' + finding['body']) + '</pre>']
    if not result['findings']:
        lines.append('No active findings reported. This does not establish correctness.')
    if result['resolved']:
        lines.append('### Resolved on this pass (model assessment)')
        for item in result['resolved']:
            lines.append('<pre>' + escape(item['id'] + ': ' + item['reason']) + '</pre>')
    omitted = meta['omitted'] + meta['omitted_before']
    if omitted:
        lines += ['<details><summary>Files omitted from source snapshots</summary>',
                  '<pre>' + escape('\n'.join(sorted(set(omitted)))) + '</pre>', '</details>']
    state = {key: meta[key] for key in ('schema', 'repo', 'pr', 'base', 'head', 'run', 'attempt', 'policy')}
    state['findings'] = result['findings']
    encoded = base64.b64encode(json.dumps(state, separators=(',', ':')).encode()).decode()
    lines.append('<!-- state:' + encoded + ' -->')
    body = '\n\n'.join(lines)
    # The marker has one newline so owned_comments cannot match quoted/nested markers.
    body = body.replace(MARKER + '\n\n', MARKER + '\n', 1)
    require(len(body.encode()) <= 60_000, 'Rendered review exceeds comment budget')
    return body


def publish(work):
    report = json.loads((work / 'report.json').read_text())
    meta = report['meta']
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    require(meta['repo'] == os.environ['GITHUB_REPOSITORY'] and meta['pr'] == event['pull_request']['number']
            and meta['head'] == event['pull_request']['head']['sha'] and meta['base'] == event['pull_request']['base']['sha']
            and meta['run'] == int(os.environ['GITHUB_RUN_ID']) and meta['attempt'] == int(os.environ['GITHUB_RUN_ATTEMPT'])
            and meta['policy'] == policy_digest(), 'Artifact does not match this run/reviewer revision')
    # Never trust a model job's artifact as executable code or unvalidated publication content.
    report['result'] = validate_result(report['result'], meta)
    body = render(report)
    token = os.environ['GH_TOKEN']
    check_current(meta, token)
    matches = owned_comments(comments(meta['repo'], meta['pr'], token))
    if matches:
        target = f"repos/{meta['repo']}/issues/comments/{matches[-1]['id']}"
        response = api(target, token, 'PATCH', {'body': body})
    else:
        target = f"repos/{meta['repo']}/issues/{meta['pr']}/comments"
        response = api(target, token, 'POST', {'body': body})
    check_current(meta, token)
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
        summary.write(f"[Advisory review]({response['html_url']}) for `{meta['head']}`; no approval issued.\n")
    print('Published advisory review: ' + response['html_url'])



if __name__ == '__main__':
    command = sys.argv[1]
    work = Path(sys.argv[2]).resolve()
    if command == 'prepare':
        prepare(work)
    elif command == 'run':
        run_model(work, Path(sys.argv[3]))
    elif command == 'publish':
        publish(work)
    else:
        raise SystemExit('Expected prepare, run or publish')
