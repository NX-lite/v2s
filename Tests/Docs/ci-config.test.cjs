const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..', '..');
const workflowPath = path.join(root, '.github', 'workflows', 'ci.yml');

function indentedBlock(text, key, indent) {
  const lines = text.split(/\r?\n/);
  const header = `${' '.repeat(indent)}${key}:`;
  const start = lines.findIndex((line) => line === header || line.startsWith(`${header} `));
  if (start === -1) {
    return null;
  }

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
  if (branchLine === -1) {
    return null;
  }

  const [, inlineValues = ''] = lines[branchLine].match(/^\s*branches:\s*(.*)$/) ?? [];
  if (inlineValues !== '') {
    if (/^\[.*\]$/.test(inlineValues) === false) {
      return null;
    }
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

function stepsIn(job) {
  const lines = job.split(/\r?\n/);
  const startIndices = lines
    .map((line, index) => (/^      - /.test(line) ? index : -1))
    .filter((index) => index !== -1);

  return startIndices.map((start, stepIndex) => {
    const end = startIndices[stepIndex + 1] ?? lines.length;
    const linesInStep = lines.slice(start, end);
    const name = linesInStep[0].match(/^      - name: (.+)$/)?.[1] ?? null;
    const uses = linesInStep[0].match(/^      - uses: (.+)$/)?.[1] ?? null;
    const runLine = linesInStep.findIndex((line) => /^        run:\s*/.test(line));
    let run = null;
    if (runLine !== -1) {
      const [, value = ''] = linesInStep[runLine].match(/^        run:\s*(.*)$/) ?? [];
      if (value === '|') {
        run = linesInStep.slice(runLine + 1)
          .filter((line) => line.trim() === '' || line.length - line.trimStart().length >= 10)
          .map((line) => line.startsWith('          ') ? line.slice(10) : line)
          .join('\n');
      } else {
        run = value;
      }
    }
    return { name, uses, run };
  });
}

function executableShellCommands(run) {
  if (typeof run !== 'string') {
    return [];
  }

  const commands = [];
  let command = '';
  for (const rawLine of run.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line === '' || line.startsWith('#')) {
      continue;
    }

    const continues = line.endsWith('\\');
    command += `${line.slice(0, continues ? -1 : undefined).trim()} `;
    if (continues === false) {
      commands.push(command.trim());
      command = '';
    }
  }
  if (command !== '') {
    commands.push(command.trim());
  }
  return commands;
}

function namedStep(steps, name) {
  return steps.find((step) => step.name === name) ?? null;
}

function expectedXcodebuildCommand(configuration, derivedDataPath) {
  return [
    'xcodebuild',
    '-project v2s.xcodeproj',
    '-scheme v2s',
    `-configuration ${configuration}`,
    'CODE_SIGNING_ALLOWED=NO',
    `-derivedDataPath ${derivedDataPath}`,
    'build',
  ].join(' ');
}

function expectedUniversalSafetyCommands() {
  return [
    'APP_BINARY=".build/release/Build/Products/Release/v2s.app/Contents/MacOS/v2s"',
    'ARCHS="$(lipo -archs "$APP_BINARY")"',
    'echo "Built architectures: $ARCHS"',
    'for required in arm64 x86_64; do',
    'case " $ARCHS " in',
    '*" $required "*)',
    ';;',
    '*)',
    'echo "::error::Release binary is missing the $required slice"',
    'exit 1',
    ';;',
    'esac',
    'done',
  ];
}

function validateWorkflow(workflow) {
  const errors = [];
  const triggers = indentedBlock(workflow, 'on', 0);
  if (triggers === null) {
    errors.push('missing top-level on trigger configuration');
  } else {
    const push = indentedBlock(triggers, 'push', 2);
    const pullRequest = indentedBlock(triggers, 'pull_request', 2);
    const expectedPushBranches = ['codex/**', 'main', 'test'];
    if (push === null || JSON.stringify((branchValues(push) ?? []).sort()) !== JSON.stringify(expectedPushBranches)) {
      errors.push('push must be limited to main, test, and codex/**');
    }
    if (pullRequest === null || JSON.stringify(branchValues(pullRequest)) !== JSON.stringify(['main'])) {
      errors.push('pull_request must be limited to main');
    }
    if (/^  workflow_dispatch:\s*$/m.test(triggers) === false) {
      errors.push('workflow_dispatch must be enabled');
    }
  }

  const permissionHeaders = [...workflow.matchAll(/^[ \t]*(?:["']permissions["']|permissions)\s*:/gm)];
  if (permissionHeaders.length !== 1 || /^permissions:\s*$/m.test(workflow) === false) {
    errors.push('permissions must appear exactly once as the top-level contents: read block');
  }
  const permissions = indentedBlock(workflow, 'permissions', 0);
  const permissionLines = (permissions ?? '')
    .split(/\r?\n/)
    .filter((line) => line.trim() !== '' && line.trimStart().startsWith('#') === false);
  if (permissionLines.length !== 1 || permissionLines[0] !== '  contents: read') {
    errors.push('CI must grant only read access to repository contents');
  }
  if (/^\s*contents:\s*write\s*(?:#.*)?$/m.test(workflow)) {
    errors.push('CI must not grant contents: write');
  }
  if (/\$\{\{[^}]*\bsecrets\b[^}]*\}\}/.test(workflow)) {
    errors.push('CI must not reference secrets');
  }
  if (/^[ \t]*(?:["']continue-on-error["']|continue-on-error)\s*:/mi.test(workflow)) {
    errors.push('CI must not use continue-on-error');
  }

  const jobs = indentedBlock(workflow, 'jobs', 0);
  const testJob = jobs === null ? null : indentedBlock(jobs, 'test', 2);
  const buildJob = jobs === null ? null : indentedBlock(jobs, 'build', 2);
  if (testJob === null) {
    errors.push('missing test job');
  }
  if (buildJob === null) {
    errors.push('missing build job');
  }
  if (testJob === null || buildJob === null) {
    return errors;
  }

  if (/^    runs-on: macos-26$/m.test(testJob) === false) {
    errors.push('test job must run on macos-26');
  }
  if (/^    runs-on: macos-26$/m.test(buildJob) === false) {
    errors.push('build job must run on macos-26');
  }
  if (/^    needs: test$/m.test(buildJob) === false) {
    errors.push('build job must depend on test');
  }

  const testSteps = stepsIn(testJob);
  const buildSteps = stepsIn(buildJob);
  for (const [jobName, steps] of [['test', testSteps], ['build', buildSteps]]) {
    if (steps.some((step) => step.uses === 'actions/checkout@v4') === false) {
      errors.push(`${jobName} job must use actions/checkout@v4`);
    }
  }

  if (namedStep(testSteps, 'Swift tests')?.run?.trim() !== 'bash scripts/diagnose-swift-tests.sh') {
    errors.push('Swift tests step must run the diagnostic Swift test wrapper');
  }
  if (namedStep(testSteps, 'Documentation structure tests')?.run?.trim() !== 'node --test Tests/Docs/*.test.cjs') {
    errors.push('documentation step must run all Tests/Docs checks');
  }

  const debugStep = namedStep(buildSteps, 'Build Debug app');
  const releaseStep = namedStep(buildSteps, 'Build Release app');
  for (const [name, step, configuration, derivedDataPath] of [
    ['Debug', debugStep, 'Debug', '.build/debug'],
    ['Release', releaseStep, 'Release', '.build/release'],
  ]) {
    const commands = executableShellCommands(step?.run);
    if (commands.some((command) => command.startsWith('xcodebuild ')) === false) {
      errors.push(`${name} build step must execute xcodebuild`);
    }
    if (commands.length !== 1 || commands[0] !== expectedXcodebuildCommand(configuration, derivedDataPath)) {
      errors.push(`${name} build step must contain only the exact xcodebuild command`);
    }
  }

  const universalStep = namedStep(buildSteps, 'Verify universal Release binary');
  const universalShellCommands = executableShellCommands(universalStep?.run);
  const universalCommands = universalShellCommands.join('\n');
  if (JSON.stringify(universalShellCommands) !== JSON.stringify(expectedUniversalSafetyCommands())) {
    errors.push('universal binary check must match the exact safety command sequence');
  }
  if (universalCommands.includes('.build/release/Build/Products/Release/v2s.app/Contents/MacOS/v2s') === false) {
    errors.push('universal binary check must target the Release app executable');
  }
  if (/\blipo -archs "\$APP_BINARY"/.test(universalCommands) === false) {
    errors.push('universal binary check must execute lipo -archs');
  }
  if (/for required in\s+arm64\s+x86_64; do/.test(universalCommands) === false) {
    errors.push('universal binary check must guard both arm64 and x86_64');
  }
  if (/missing the \$required slice/.test(universalCommands) === false) {
    errors.push('universal binary check must fail when a required slice is absent');
  }
  const missingSliceBranch = universalCommands.match(/(?:^|\n)\s*\*\)\s*\n([\s\S]*?)(?:\n\s*;;)(?:\n|$)/);
  if (missingSliceBranch === null || /\bexit\s+1\b/.test(missingSliceBranch[1]) === false) {
    errors.push('universal binary check must exit with failure when a required slice is absent');
  }
  return errors;
}

function transformStepRun(workflow, name, transform) {
  const header = `      - name: ${name}\n        run: |\n`;
  const start = workflow.indexOf(header);
  assert.notEqual(start, -1, `missing ${name} step in test fixture`);
  const runStart = start + header.length;
  const nextStep = workflow.indexOf('\n      - ', runStart);
  const runEnd = nextStep === -1 ? workflow.length : nextStep + 1;
  return `${workflow.slice(0, runStart)}${transform(workflow.slice(runStart, runEnd))}${workflow.slice(runEnd)}`;
}

test('CI workflow has executable gated test and universal-build steps', () => {
  const workflow = fs.readFileSync(workflowPath, 'utf8');
  assert.deepEqual(validateWorkflow(workflow), []);
});

test('CI validator rejects commented or removed build checks and privileged workflow mutations', () => {
  const workflow = fs.readFileSync(workflowPath, 'utf8');
  const commentFirstCommand = (run) => run.replace('          xcodebuild \\\n', '          # xcodebuild \\\n');

  const cases = [
    [
      'Debug xcodebuild command',
      transformStepRun(workflow, 'Build Debug app', commentFirstCommand),
      /Debug build step must execute xcodebuild/,
    ],
    [
      'Release xcodebuild command',
      transformStepRun(workflow, 'Build Release app', commentFirstCommand),
      /Release build step must execute xcodebuild/,
    ],
    [
      'lipo command',
      transformStepRun(workflow, 'Verify universal Release binary', (run) =>
        run.replace('          ARCHS="$(lipo -archs "$APP_BINARY")"', '          # ARCHS="$(lipo -archs "$APP_BINARY")"')
      ),
      /universal binary check must execute lipo -archs/,
    ],
    [
      'arm64 guard',
      transformStepRun(workflow, 'Verify universal Release binary', (run) =>
        run.replace('for required in arm64 x86_64; do', 'for required in x86_64; do')
      ),
      /guard both arm64 and x86_64/,
    ],
    [
      'x86_64 guard',
      transformStepRun(workflow, 'Verify universal Release binary', (run) =>
        run.replace('for required in arm64 x86_64; do', 'for required in arm64; do')
      ),
      /guard both arm64 and x86_64/,
    ],
    [
      'secret reference',
      `${workflow}\n      - name: leaked\n        run: echo \${{ secrets.X }}\n`,
      /must not reference secrets/,
    ],
    [
      'bracketed secret reference',
      `${workflow}\n      - name: leaked\n        run: echo \${{ secrets["X"] }}\n`,
      /must not reference secrets/,
    ],
    [
      'single-quoted bracketed secret reference',
      `${workflow}\n      - name: leaked\n        run: echo \${{ secrets['X'] }}\n`,
      /must not reference secrets/,
    ],
    [
      'whole secrets context expression',
      `${workflow}\n      - name: leaked\n        run: echo \${{ toJSON(secrets) }}\n`,
      /must not reference secrets/,
    ],
    [
      'write permission',
      workflow.replace('  contents: read', '  contents: write'),
      /must not grant contents: write/,
    ],
    [
      'extra id-token permission',
      workflow.replace('  contents: read', '  contents: read\n  id-token: write'),
      /grant only read access to repository contents/,
    ],
    [
      'extra actions permission',
      workflow.replace('  contents: read', '  contents: read\n  actions: read'),
      /grant only read access to repository contents/,
    ],
    [
      'extra pull-requests permission',
      workflow.replace('  contents: read', '  contents: read\n  pull-requests: read'),
      /grant only read access to repository contents/,
    ],
    [
      'non-read contents permission',
      workflow.replace('  contents: read', '  contents: none'),
      /grant only read access to repository contents/,
    ],
    [
      'job-level inline permissions',
      workflow.replace(
        '  test:\n    runs-on: macos-26',
        '  test:\n    permissions: { id-token: write }\n    runs-on: macos-26'
      ),
      /permissions must appear exactly once as the top-level contents: read block/,
    ],
    [
      'Debug xcodebuild failure mask',
      transformStepRun(workflow, 'Build Debug app', (run) => run.replace('            build', '            build || true')),
      /Debug build step must contain only the exact xcodebuild command/,
    ],
    [
      'Release xcodebuild failure mask',
      transformStepRun(workflow, 'Build Release app', (run) => run.replace('            build', '            build || true')),
      /Release build step must contain only the exact xcodebuild command/,
    ],
    [
      'Debug xcodebuild alternate failure mask',
      transformStepRun(workflow, 'Build Debug app', (run) => run.replace('            build', '            build || echo ignored')),
      /Debug build step must contain only the exact xcodebuild command/,
    ],
    [
      'lipo failure mask',
      transformStepRun(workflow, 'Verify universal Release binary', (run) =>
        run.replace('          ARCHS="$(lipo -archs "$APP_BINARY")"', '          ARCHS="$(lipo -archs "$APP_BINARY")" || true')
      ),
      /universal binary check must match the exact safety command sequence/,
    ],
    [
      'missing-slice exit',
      transformStepRun(workflow, 'Verify universal Release binary', (run) => run.replace('                exit 1\n', '')),
      /universal binary check must match the exact safety command sequence/,
    ],
    [
      'critical step continue-on-error',
      workflow.replace('      - name: Build Debug app\n        run:', '      - name: Build Debug app\n        continue-on-error: true\n        run:'),
      /CI must not use continue-on-error/,
    ],
    [
      'expression-based continue-on-error',
      workflow.replace('      - name: Swift tests\n        run:', '      - name: Swift tests\n        continue-on-error: \${{ true }}\n        run:'),
      /CI must not use continue-on-error/,
    ],
  ];

  for (const [name, mutation, expectedError] of cases) {
    assert.match(validateWorkflow(mutation).join('\n'), expectedError, name);
  }
});
