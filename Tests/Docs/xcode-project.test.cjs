const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..', '..');
const project = fs.readFileSync(
  path.join(root, 'v2s.xcodeproj', 'project.pbxproj'),
  'utf8'
);
const packageManifest = fs.readFileSync(path.join(root, 'Package.swift'), 'utf8');
const packageResolutions = [
  ['Package.resolved', path.join(root, 'Package.resolved')],
  ['v2s.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved', path.join(root, 'v2s.xcodeproj', 'project.xcworkspace', 'xcshareddata', 'swiftpm', 'Package.resolved')],
]
  .filter(([, filePath]) => fs.existsSync(filePath))
  .map(([label, filePath]) => ({ label, text: fs.readFileSync(filePath, 'utf8') }));
const appModel = fs.readFileSync(
  path.join(root, 'Sources', 'V2SApp', 'App', 'AppModel.swift'),
  'utf8'
);
const updater = fs.readFileSync(
  path.join(root, 'Sources', 'V2SApp', 'Services', 'UpdaterService.swift'),
  'utf8'
);
const infoPlist = fs.readFileSync(path.join(root, 'Config', 'Info.plist'), 'utf8');
const readme = fs.readFileSync(path.join(root, 'README.md'), 'utf8');
const readmeChinese = fs.readFileSync(path.join(root, 'README.zh-CN.md'), 'utf8');
const websiteIndex = fs.readFileSync(path.join(root, 'docs', 'index.html'), 'utf8');
const websiteI18n = fs.readFileSync(path.join(root, 'docs', 'js', 'i18n.js'), 'utf8');
const websiteReadme = fs.readFileSync(path.join(root, 'docs', 'README.md'), 'utf8');
const homebrewTemplate = fs.readFileSync(
  path.join(root, 'packaging', 'homebrew', 'v2s.rb.template'),
  'utf8'
);
const homebrewReadme = fs.readFileSync(
  path.join(root, 'packaging', 'homebrew', 'README.md'),
  'utf8'
);
const releaseWorkflow = fs.readFileSync(
  path.join(root, '.github', 'workflows', 'release.yml'),
  'utf8'
);
const designSpec = fs.readFileSync(
  path.join(root, 'docs', 'superpowers', 'specs', '2026-09-04-mainline-rebuild-design.md'),
  'utf8'
);
const implementationPlan = fs.readFileSync(
  path.join(root, 'docs', 'superpowers', 'plans', '2026-09-04-mainline-rebuild.md'),
  'utf8'
);
const swiftTestScript = fs.readFileSync(path.join(root, 'scripts', 'test-swift.sh'), 'utf8');
const sileroVADEngine = fs.readFileSync(
  path.join(root, 'Sources', 'V2SApp', 'Services', 'SileroVADEngine.swift'),
  'utf8'
);

function sectionFrom(projectText, name) {
  const match = projectText.match(
    new RegExp(`/\\* Begin ${name} section \\*/([\\s\\S]*?)/\\* End ${name} section \\*/`)
  );
  return match?.[1] ?? null;
}

function relativeFilePaths(directory, rootDirectory = directory) {
  return fs.readdirSync(directory, { withFileTypes: true })
    .flatMap((entry) => {
      const entryPath = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        return relativeFilePaths(entryPath, rootDirectory);
      }
      return entry.isFile()
        ? [path.relative(rootDirectory, entryPath).split(path.sep).join('/')]
        : [];
    })
    .sort();
}

function productionSwiftRelativePaths() {
  return relativeFilePaths(path.join(root, 'Sources', 'V2SApp'))
    .filter((filePath) => filePath.endsWith('.swift'));
}

function indexBy(records, keyPath) {
  const index = new Map();
  for (const record of records) {
    const key = record[keyPath];
    index.set(key, [...(index.get(key) ?? []), record]);
  }
  return index;
}

function parseFileReferences(projectText, errors) {
  const fileReferences = sectionFrom(projectText, 'PBXFileReference');
  if (fileReferences === null) {
    errors.push('missing PBXFileReference section');
    return [];
  }

  return [...fileReferences.matchAll(
    /^\s*([A-F0-9]{24}) \/\* [^*]+ \*\/ = \{isa = PBXFileReference;.*?path = ([^;]+);.*?\};$/gm
  )].map((match) => ({
    id: match[1],
    path: match[2].trim().replace(/^"(.*)"$/, '$1'),
  }));
}

function parseBuildFiles(projectText, errors) {
  const buildFiles = sectionFrom(projectText, 'PBXBuildFile');
  if (buildFiles === null) {
    errors.push('missing PBXBuildFile section');
    return [];
  }

  return [...buildFiles.matchAll(
    /^\s*([A-F0-9]{24}) \/\* [^*]+ \*\/ = \{isa = PBXBuildFile; fileRef = ([A-F0-9]{24}) \/\* [^*]+ \*\/; \};$/gm
  )].map((match) => ({ id: match[1], fileReferenceID: match[2] }));
}

function parseGroups(projectText, errors) {
  const groups = sectionFrom(projectText, 'PBXGroup');
  if (groups === null) {
    errors.push('missing PBXGroup section');
    return [];
  }

  return [...groups.matchAll(
    /^\s*([A-F0-9]{24})(?: \/\* [^*]+ \*\/)? = \{\n\s*isa = PBXGroup;\n([\s\S]*?)^\s*\};$/gm
  )].map((match) => {
    const body = match[2];
    const pathMatch = body.match(/^\s*path = ([^;]+);$/m);
    return {
      id: match[1],
      path: pathMatch?.[1].trim().replace(/^"(.*)"$/, '$1') ?? '',
      children: [...body.matchAll(/^\s*([A-F0-9]{24}) \/\* [^*]+ \*\/,$/gm)].map((child) => child[1]),
    };
  });
}

function parseSourceBuildFileIDs(projectText, errors) {
  const phases = sectionFrom(projectText, 'PBXSourcesBuildPhase');
  if (phases === null) {
    errors.push('missing PBXSourcesBuildPhase section');
    return [];
  }

  const sourcePhase = phases.match(
    /^\s*A00000000000000000000007 \/\* Sources \*\/ = \{\n\s*isa = PBXSourcesBuildPhase;\n([\s\S]*?)^\s*\};$/m
  );
  if (sourcePhase === null) {
    errors.push('missing v2s app Sources build phase');
    return [];
  }

  const files = sourcePhase[1].match(/^\s*files = \(\n([\s\S]*?)^\s*\);$/m);
  if (files === null) {
    errors.push('missing v2s app Sources build phase file list');
    return [];
  }

  return [...files[1].matchAll(/^\s*([A-F0-9]{24}) \/\* [^*]+ \*\/,$/gm)].map((match) => match[1]);
}

function validateV2STargetSourcesBuildPhase(projectText, errors) {
  const targets = sectionFrom(projectText, 'PBXNativeTarget');
  if (targets === null) {
    errors.push('missing PBXNativeTarget section');
    return;
  }

  const v2sTarget = targets.match(
    /^\s*[A-F0-9]{24} \/\* v2s \*\/ = \{\n\s*isa = PBXNativeTarget;\n([\s\S]*?)^\s*\};$/m
  );
  if (v2sTarget === null) {
    errors.push('missing v2s PBXNativeTarget');
    return;
  }

  const buildPhases = v2sTarget[1].match(/^\s*buildPhases = \(\n([\s\S]*?)^\s*\);$/m);
  if (buildPhases === null) {
    errors.push('missing v2s target build phases');
    return;
  }

  const sourcePhaseIDs = [...buildPhases[1].matchAll(/^\s*([A-F0-9]{24}) \/\* Sources \*\/,$/gm)]
    .map((match) => match[1]);
  if (sourcePhaseIDs.length !== 1 || sourcePhaseIDs[0] !== 'A00000000000000000000007') {
    errors.push('v2s target must include exactly one Sources build phase');
  }
}

function resolveGroupPaths(groups, fileReferences, errors) {
  const groupsByID = indexBy(groups, 'id');
  const fileReferencesByID = indexBy(fileReferences, 'id');
  const groupMemberships = new Map();
  const resolutions = [];

  function visit(groupID, parentPath, ancestors) {
    const matchingGroups = groupsByID.get(groupID) ?? [];
    if (matchingGroups.length !== 1) {
      errors.push(`Xcode group ${groupID} must have exactly one PBXGroup object`);
      return;
    }
    if (ancestors.has(groupID)) {
      errors.push(`Xcode group hierarchy contains a cycle at ${groupID}`);
      return;
    }

    const group = matchingGroups[0];
    const groupPath = group.path === '' ? parentPath : path.posix.join(parentPath, group.path);
    const nextAncestors = new Set(ancestors);
    nextAncestors.add(groupID);

    for (const childID of group.children) {
      if (groupsByID.has(childID)) {
        visit(childID, groupPath, nextAncestors);
        continue;
      }

      const matchingReferences = fileReferencesByID.get(childID) ?? [];
      if (matchingReferences.length === 0) {
        errors.push(`Xcode group ${groupID} references unknown child ${childID}`);
        continue;
      }

      groupMemberships.set(childID, [...(groupMemberships.get(childID) ?? []), groupPath]);
      for (const fileReference of matchingReferences) {
        resolutions.push({
          fileReferenceID: childID,
          groupPath,
          fullPath: path.posix.join(groupPath, fileReference.path),
        });
      }
    }
  }

  visit('A00000000000000000000002', '', new Set());
  return { groupMemberships, resolutions };
}

function validateProductionSwiftProject(projectText, sourcePaths) {
  const errors = [];
  const fileReferences = parseFileReferences(projectText, errors);
  const buildFiles = parseBuildFiles(projectText, errors);
  const groups = parseGroups(projectText, errors);
  const sourceBuildFileIDs = parseSourceBuildFileIDs(projectText, errors);
  validateV2STargetSourcesBuildPhase(projectText, errors);
  if (errors.length > 0) {
    return errors;
  }

  const fileReferencesByID = indexBy(fileReferences, 'id');
  const buildFilesByID = indexBy(buildFiles, 'id');
  const { groupMemberships, resolutions } = resolveGroupPaths(groups, fileReferences, errors);
  const sourcePathSet = new Set(sourcePaths);
  const swiftFileReferences = fileReferences.filter((fileReference) => fileReference.path.endsWith('.swift'));

  for (const buildFileID of sourceBuildFileIDs) {
    const matchingBuildFiles = buildFilesByID.get(buildFileID) ?? [];
    if (matchingBuildFiles.length !== 1) {
      errors.push(`app Sources build phase entry ${buildFileID} must reference exactly one PBXBuildFile`);
      continue;
    }
    if ((fileReferencesByID.get(matchingBuildFiles[0].fileReferenceID) ?? []).length !== 1) {
      errors.push(`app Sources build phase entry ${buildFileID} must reference an existing PBXFileReference`);
    }
  }

  for (const sourcePath of sourcePaths) {
    const expectedFullPath = path.posix.join('Sources', 'V2SApp', sourcePath);
    const matchingReferences = swiftFileReferences.filter((fileReference) =>
      resolutions.some((resolution) =>
        resolution.fileReferenceID === fileReference.id && resolution.fullPath === expectedFullPath
      )
    );
    if (matchingReferences.length !== 1) {
      errors.push(`${sourcePath} must have exactly one PBXFileReference`);
      continue;
    }

    const fileReference = matchingReferences[0];
    const matchingResolutions = resolutions.filter((resolution) =>
      resolution.fileReferenceID === fileReference.id && resolution.fullPath === expectedFullPath
    );
    const expectedGroupPath = path.posix.dirname(expectedFullPath);
    if ((groupMemberships.get(fileReference.id) ?? []).length !== 1) {
      errors.push(`${sourcePath} must appear in exactly one Xcode group`);
    } else if (matchingResolutions.length !== 1 || matchingResolutions[0].groupPath !== expectedGroupPath) {
      errors.push(`${sourcePath} must be a child of the matching Xcode group ${expectedGroupPath}`);
    }

    const matchingBuildFiles = buildFiles.filter((buildFile) => buildFile.fileReferenceID === fileReference.id);
    if (matchingBuildFiles.length !== 1) {
      errors.push(`${sourcePath} must have exactly one PBXBuildFile linked to its file reference`);
      continue;
    }
    if (sourceBuildFileIDs.filter((buildFileID) => buildFileID === matchingBuildFiles[0].id).length !== 1) {
      errors.push(`${sourcePath} must have exactly one app source-phase entry`);
    }
  }

  for (const fileReference of swiftFileReferences) {
    const matchingResolutions = resolutions.filter((resolution) => resolution.fileReferenceID === fileReference.id);
    if (matchingResolutions.length !== 1) {
      errors.push(`PBXFileReference ${fileReference.id} (${fileReference.path}) must resolve exactly once through the Xcode group hierarchy`);
      continue;
    }

    const resolution = matchingResolutions[0];
    const sourcePrefix = 'Sources/V2SApp/';
    if (resolution.fullPath.startsWith(sourcePrefix) === false) {
      errors.push(`PBXFileReference ${fileReference.id} (${fileReference.path}) must be inside Sources/V2SApp`);
      continue;
    }
    const sourcePath = resolution.fullPath.slice(sourcePrefix.length);
    if (sourcePathSet.has(sourcePath) === false) {
      errors.push(`PBXFileReference ${fileReference.id} points to missing production source ${resolution.fullPath}`);
    }
  }

  return errors;
}

function legacyONNXViolations({ project, packageManifest, packageResolutions, resourcePaths }) {
  const violations = [];
  if (/onnx/i.test(project)) {
    violations.push('project.pbxproj must not contain ONNX runtime or package references');
  }
  if (/onnx/i.test(packageManifest)) {
    violations.push('Package.swift must not contain ONNX runtime or package references');
  }
  for (const packageResolution of packageResolutions) {
    if (/onnx/i.test(packageResolution.text)) {
      violations.push(`${packageResolution.label} must not contain ONNX runtime or package references`);
    }
  }
  if (resourcePaths.some((resourcePath) => /onnx/i.test(resourcePath))) {
    violations.push('Resources must not contain ONNX model artifacts');
  }
  return violations;
}

test('Xcode target dynamically registers every production Swift source and rejects broken wiring', () => {
  const sourcePaths = productionSwiftRelativePaths();
  assert.ok(sourcePaths.includes('App/AppModel.swift'));
  assert.ok(sourcePaths.includes('UI/Settings/AssistantSettingsSection.swift'));

  assert.deepEqual(validateProductionSwiftProject(project, sourcePaths), []);

  const missingExistingSourcePhaseEntry = project.replace(
    '\t\t\t\tA00000000000000000000051 /* AppModel.swift in Sources */,\n',
    ''
  );
  assert.match(
    validateProductionSwiftProject(missingExistingSourcePhaseEntry, sourcePaths).join('\n'),
    /App\/AppModel\.swift must have exactly one app source-phase entry/
  );

  const duplicateExistingGroupEntry = project.replace(
    '\t\t\t\tA00000000000000000000031 /* AppModel.swift */,\n',
    '\t\t\t\tA00000000000000000000031 /* AppModel.swift */,\n\t\t\t\tA00000000000000000000031 /* AppModel.swift */,\n'
  );
  assert.match(
    validateProductionSwiftProject(duplicateExistingGroupEntry, sourcePaths).join('\n'),
    /App\/AppModel\.swift must appear in exactly one Xcode group/
  );

  const detachedSourcePhase = project.replace(
    '\t\t\t\tA00000000000000000000007 /* Sources */,\n',
    ''
  );
  assert.match(
    validateProductionSwiftProject(detachedSourcePhase, sourcePaths).join('\n'),
    /v2s target must include exactly one Sources build phase/
  );
});

test('Xcode project keeps Core ML and excludes legacy ONNX runtime, package, and model artifacts', () => {
  const resourcePaths = relativeFilePaths(path.join(root, 'Sources', 'V2SApp', 'Resources'));
  const inputs = { project, packageManifest, packageResolutions, resourcePaths };

  assert.deepEqual(legacyONNXViolations(inputs), []);
  assert.match(
    legacyONNXViolations({ ...inputs, packageManifest: 'dependencies: ["onnxruntime"]' }).join('\n'),
    /Package\.swift must not contain ONNX runtime or package references/
  );
  assert.match(
    legacyONNXViolations({ ...inputs, resourcePaths: [...resourcePaths, 'silero_vad.onnx'] }).join('\n'),
    /Resources must not contain ONNX model artifacts/
  );

  assert.ok(resourcePaths.includes('SileroVAD.mlpackage/Manifest.json'));
  assert.ok(resourcePaths.includes('SileroVAD.mlpackage/Data/com.apple.CoreML/model.mlmodel'));
  assert.match(project, /ARCHS = "\$\(ARCHS_STANDARD\)";/);
});

test('Command Line Tools tests bypass unavailable coremlc without changing Xcode resources', () => {
  assert.match(swiftTestScript, /V2S_CLT_TESTING=1/);
  assert.match(packageManifest, /ProcessInfo\.processInfo\.environment\["V2S_CLT_TESTING"\]/);
  assert.match(packageManifest, /\.define\("V2S_CLT_TESTING"\)/);
  assert.match(packageManifest, /v2sExcludedResources[\s\S]*SileroVAD\.mlpackage/);
  assert.match(packageManifest, /exclude: v2sExcludedResources/);
  assert.match(sileroVADEngine, /#if V2S_CLT_TESTING/);
  assert.match(sileroVADEngine, /Resources\/SileroVAD\.mlpackage/);
  assert.match(swiftTestScript, /SwiftUIMacros/);
  assert.match(swiftTestScript, /testing\/libTestingMacros\.dylib/);
  assert.match(swiftTestScript, /-load-plugin-library/);
  assert.match(swiftTestScript, /COPYFILE_DISABLE=1/);
  assert.doesNotMatch(swiftTestScript, /xattr -cr/);
  assert.match(swiftTestScript, /task_tmp_root="\$\{TMPDIR:-\/private\/tmp\}"/);
  assert.match(swiftTestScript, /clt_scratch_dir="\$\{task_tmp_root%\/?\}\/v2s-swiftpm-/);
  assert.doesNotMatch(swiftTestScript, /clt_scratch_dir="\$repo_root\/\.build\/clt-scratch/);
  const fullXcodeBranch = swiftTestScript.indexOf('if xcodebuild -version');
  const fullXcodeBranchEnd = swiftTestScript.indexOf('\nfi', fullXcodeBranch);
  const cltTestExport = swiftTestScript.indexOf('export V2S_CLT_TESTING=1');
  assert.ok(fullXcodeBranch >= 0);
  assert.ok(fullXcodeBranchEnd > fullXcodeBranch);
  assert.ok(cltTestExport > fullXcodeBranchEnd);
  assert.match(project, /SileroVAD\.mlpackage in Sources/);
});

test('fork identity keeps upstream versioning and documents the opt-in assistant data flow', () => {
  assert.match(appModel, /static let marketingVersion = "0\.3\.38"/);
  assert.match(appModel, /static let buildNumber = "42"/);
  assert.match(appModel, /static let repositoryURLString = "https:\/\/github\.com\/NX-lite\/v2s"/);
  assert.match(infoPlist, /https:\/\/github\.com\/NX-lite\/v2s\/releases\/latest\/download\/appcast\.xml/);
  assert.match(updater, /Logger\(subsystem: "com\.nxlite\.v2s", category: "updater"\)/);
  assert.match(updater, /Logger\(subsystem: "com\.nxlite\.v2s", category: "launchAtLogin"\)/);
  assert.match(project, /PRODUCT_BUNDLE_IDENTIFIER = com\.franklioxygen\.v2s;/);

  for (const document of [readme, readmeChinese]) {
    assert.match(document, /NX-lite\/v2s/);
    assert.match(document, /Follow Up/);
    assert.match(document, /Ask/);
    assert.match(document, /OpenAI/);
    assert.match(document, /Gemini/);
    assert.match(document, /OCR/);
    assert.match(document, /Invisible in Recording/);
  }

  assert.match(readme, /only after an explicit Follow Up or Ask/i);
  assert.match(readme, /text-only fallback/i);
  assert.match(readme, /configured provider/i);
  assert.match(readme, /hotkey/i);
  assert.match(readmeChinese, /仅在你明确执行 Follow Up 或 Ask 后/);
  assert.match(readmeChinese, /纯文本回退/);
  assert.match(readmeChinese, /你配置的服务商/);
  assert.match(readmeChinese, /快捷键/);

  for (const forkFacingArtifact of [websiteIndex, websiteI18n, homebrewTemplate, homebrewReadme]) {
    assert.doesNotMatch(forkFacingArtifact, /github\.com\/franklioxygen\/v2s/i);
  }
  assert.doesNotMatch(websiteReadme, /franklioxygen\.github\.io\/v2s/i);
  assert.match(websiteIndex, /github\.com\/NX-lite\/v2s/);
  assert.match(websiteI18n, /github\.com\/NX-lite\/v2s/);
  assert.match(websiteReadme, /NX-lite\.github\.io\/v2s/i);
  assert.match(homebrewTemplate, /github\.com\/NX-lite\/v2s/);
  assert.match(homebrewReadme, /NX-lite\/homebrew-v2s/);
  assert.match(releaseWorkflow, /TAP_REPO: NX-lite\/homebrew-v2s/);
  assert.doesNotMatch(releaseWorkflow, /TAP_REPO: franklioxygen\/homebrew-v2s/);
});

test('documentation records bounded meeting-assistant references and local provider-key handling', () => {
  const meetilyReference = 'https://github.com/Zackriya-Solutions/meetily/tree/a2cb62e827da7ef59f65064c97233efb2313878e';
  const summaryReference = 'https://github.com/Disalazario/meeting-summary-ai/tree/640efa955e62f6dfebfe4ac7e8c9651119469229';

  assert.match(readme, /## Design references/);
  assert.match(readme, new RegExp(meetilyReference.replace(/[./-]/g, '\\$&')));
  assert.match(readme, new RegExp(summaryReference.replace(/[./-]/g, '\\$&')));
  assert.match(readme, /local-first privacy, cancellable provider operations, and synthetic tests\/structural assertions/i);
  assert.match(readme, /independent Swift implementation; no code was copied/i);
  assert.match(readme, /not fully local/i);
  assert.match(readme, /API key is stored only in local settings/i);
  assert.match(readme, /Model discovery and API test use it to contact your configured provider/i);

  assert.match(readmeChinese, /## 设计参考/);
  assert.match(readmeChinese, new RegExp(meetilyReference.replace(/[./-]/g, '\\$&')));
  assert.match(readmeChinese, new RegExp(summaryReference.replace(/[./-]/g, '\\$&')));
  assert.match(readmeChinese, /本地优先隐私、可取消的服务商操作和合成测试\/结构断言/);
  assert.match(readmeChinese, /独立的 Swift 实现，未复制代码/);
  assert.match(readmeChinese, /并非完全本地/);
  assert.match(readmeChinese, /API Key 只保存在本地设置中/);
  assert.match(readmeChinese, /模型列表拉取和 API 连接测试会使用它联系你配置的服务商/);

  for (const document of [designSpec, implementationPlan]) {
    assert.match(document, /## Reference boundary/);
    assert.match(document, new RegExp(meetilyReference.replace(/[./-]/g, '\\$&')));
    assert.match(document, new RegExp(summaryReference.replace(/[./-]/g, '\\$&')));
    assert.match(document, /Structured meeting minutes, action items, templates, export, archive,\s+robots, Telegram, Ollama, and bundled Whisper are outside `?origin\/main`? and are not\s+added/i);
    assert.match(document, /If the user provides a different 1meeting-summary-ai URL, replace the\s+candidate reference/i);
  }
});
