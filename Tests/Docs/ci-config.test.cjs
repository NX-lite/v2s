const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..', '..');
const workflowPath = path.join(root, '.github', 'workflows', 'ci.yml');

function indentedBlock(text, key, indent) {
  const lines = text.split(/\r?\n/);
  const prefix = ' '.repeat(indent);
  const header = `${prefix}${key}:`;
  const start = lines.findIndex((line) => line === header || line.startsWith(`${header} `));
  assert.notEqual(start, -1, `missing ${key} at indentation ${indent}`);

  const block = [];
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (line.trim() !== '' && line.length - line.trimStart().length <= indent) {
      break;
    }
    block.push(line);
  }
  return block.join('\n');
}

function branchValues(eventBlock) {
  const lines = eventBlock.split(/\r?\n/);
  const branchLine = lines.findIndex((line) => /^\s*branches:\s*/.test(line));
  assert.notEqual(branchLine, -1, 'event must restrict branches');

  const [, inlineValues = ''] = lines[branchLine].match(/^\s*branches:\s*(.*)$/) ?? [];
  if (inlineValues !== '') {
    assert.match(inlineValues, /^\[.*\]$/, 'inline branches must use a YAML list');
    return inlineValues.slice(1, -1).split(',').map((value) => value.trim().replace(/^['"]|['"]$/g, ''));
  }

  const branchIndent = lines[branchLine].length - lines[branchLine].trimStart().length;
  return lines
    .slice(branchLine + 1)
    .filter((line) => {
      const indent = line.length - line.trimStart().length;
      return indent > branchIndent && /^\s*-\s+/.test(line);
    })
    .map((line) => line.replace(/^\s*-\s+/, '').trim().replace(/^['"]|['"]$/g, ''));
}

function requireRunBlock(job, description, pattern) {
  assert.match(job, pattern, `${description} must be a run step in its intended job`);
}

test('CI workflow tests supported branches, Swift package, documentation, debug app, and universal release app', () => {
  const workflow = fs.readFileSync(workflowPath, 'utf8');
  const triggers = indentedBlock(workflow, 'on', 0);
  const push = indentedBlock(triggers, 'push', 2);
  const pullRequest = indentedBlock(triggers, 'pull_request', 2);

  assert.deepEqual(branchValues(push).sort(), ['codex/**', 'main']);
  assert.deepEqual(branchValues(pullRequest), ['main']);
  assert.match(triggers, /^  workflow_dispatch:\s*$/m);

  const jobs = indentedBlock(workflow, 'jobs', 0);
  const testJob = indentedBlock(jobs, 'test', 2);
  const buildJob = indentedBlock(jobs, 'build', 2);
  for (const job of [testJob, buildJob]) {
    assert.match(job, /^    runs-on: macos-26$/m);
    assert.match(job, /^      - uses: actions\/checkout@v4$/m);
  }

  requireRunBlock(testJob, 'Swift test', /^      - name: Swift tests\n        run: swift test$/m);
  requireRunBlock(testJob, 'documentation test', /^      - name: Documentation structure tests\n        run: node --test Tests\/Docs\/\*\.test\.cjs$/m);
  assert.match(buildJob, /^    needs: test$/m);
  requireRunBlock(
    buildJob,
    'Debug build',
    /xcodebuild[\s\\]+-project v2s\.xcodeproj[\s\\]+-scheme v2s[\s\\]+-configuration Debug[\s\\]+-derivedDataPath \.build\/debug[\s\\]+build/
  );
  requireRunBlock(
    buildJob,
    'Release build',
    /xcodebuild[\s\\]+-project v2s\.xcodeproj[\s\\]+-scheme v2s[\s\\]+-configuration Release[\s\\]+-derivedDataPath \.build\/release[\s\\]+build/
  );
  assert.match(buildJob, /\.build\/release\/Build\/Products\/Release\/v2s\.app\/Contents\/MacOS\/v2s/);
  assert.match(buildJob, /lipo -archs "\$APP_BINARY"/);
  assert.match(buildJob, /for required in arm64 x86_64;/);
  assert.match(buildJob, /missing the \$required slice/);
});
