const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..', '..');
const project = fs.readFileSync(
  path.join(root, 'v2s.xcodeproj', 'project.pbxproj'),
  'utf8'
);
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

function section(name) {
  const match = project.match(
    new RegExp(`/\\* Begin ${name} section \\*/([\\s\\S]*?)/\\* End ${name} section \\*/`)
  );
  assert.ok(match, `missing ${name} section`);
  return match[1];
}

function objectBlock(identifier) {
  const match = project.match(
    new RegExp(`\\n\\s*${identifier}[^\\n]*= \\{([\\s\\S]*?)\\n\\s*\\};`)
  );
  assert.ok(match, `missing project object ${identifier}`);
  return match[0];
}

function occurrences(text, pattern) {
  const flags = pattern.flags.includes('g') ? pattern.flags : `${pattern.flags}g`;
  return [...text.matchAll(new RegExp(pattern.source, flags))].length;
}

const restoredSources = [
  ['AssistantModels.swift', 'A00000000000000000000100', 'A00000000000000000000110', 'A0000000000000000000000E'],
  ['AssistantSettings.swift', 'A00000000000000000000101', 'A00000000000000000000111', 'A0000000000000000000000E'],
  ['AssistantCoordinator.swift', 'A00000000000000000000102', 'A00000000000000000000112', 'A0000000000000000000000F'],
  ['AssistantPromptBuilder.swift', 'A00000000000000000000103', 'A00000000000000000000113', 'A0000000000000000000000F'],
  ['GlobalHotKeyController.swift', 'A00000000000000000000104', 'A00000000000000000000114', 'A0000000000000000000000F'],
  ['HTTPTransport.swift', 'A00000000000000000000105', 'A00000000000000000000115', 'A0000000000000000000000F'],
  ['OpenAIResponsesClient.swift', 'A00000000000000000000106', 'A00000000000000000000116', 'A0000000000000000000000F'],
  ['ScreenContextProvider.swift', 'A00000000000000000000107', 'A00000000000000000000117', 'A0000000000000000000000F'],
  ['AssistantReplyView.swift', 'A00000000000000000000108', 'A00000000000000000000118', 'A00000000000000000000011'],
  ['AssistantSettingsSection.swift', 'A00000000000000000000109', 'A00000000000000000000119', 'A00000000000000000000012'],
];

test('Xcode target registers every rebuilt production source exactly once', () => {
  const buildFiles = section('PBXBuildFile');
  const fileReferences = section('PBXFileReference');
  const sourcePhase = objectBlock('A00000000000000000000007 /\\* Sources \\*/');

  for (const [name, fileReferenceID, buildFileID, groupID] of restoredSources) {
    assert.equal(
      occurrences(fileReferences, new RegExp(`${fileReferenceID} /\\* ${name.replace('.', '\\.')} \\*/ = \\{isa = PBXFileReference;`)),
      1,
      `${name} must have one PBXFileReference`
    );
    assert.match(
      fileReferences,
      new RegExp(`${fileReferenceID} /\\* ${name.replace('.', '\\.')} \\*/ = \\{isa = PBXFileReference;[^\\n]*path = ${name.replace('.', '\\.')};`),
      `${name} file reference must point to the production source`
    );
    assert.equal(
      occurrences(buildFiles, new RegExp(`${buildFileID} /\\* ${name.replace('.', '\\.')} in Sources \\*/ = \\{isa = PBXBuildFile; fileRef = ${fileReferenceID} /\\* ${name.replace('.', '\\.')} \\*/; \\};`)),
      1,
      `${name} must have one PBXBuildFile wired to its file reference`
    );
    assert.equal(
      occurrences(sourcePhase, new RegExp(`${buildFileID} /\\* ${name.replace('.', '\\.')} in Sources \\*/,`, 'g')),
      1,
      `${name} must be in the v2s sources build phase exactly once`
    );
    assert.match(
      objectBlock(`${groupID} /\\* (?:Models|Services|Overlay|Settings) \\*/`),
      new RegExp(`${fileReferenceID} /\\* ${name.replace('.', '\\.')} \\*/,`),
      `${name} must be placed in its matching Xcode group`
    );
  }
});

test('Xcode project keeps Core ML and universal architecture without legacy ONNX entries', () => {
  const fileReferences = section('PBXFileReference');
  const sourcePhase = objectBlock('A00000000000000000000007 /\\* Sources \\*/');
  const modelsGroup = objectBlock('A0000000000000000000000E /\\* Models \\*/');

  assert.doesNotMatch(project, /onnx/i);
  assert.match(fileReferences, /SileroVAD\.mlpackage/);
  assert.match(sourcePhase, /SileroVAD\.mlpackage in Sources/);
  assert.match(project, /ARCHS = "\$\(ARCHS_STANDARD\)";/);
  assert.equal(
    occurrences(modelsGroup, /OverlayStyle\.swift \*\//g),
    1,
    'OverlayStyle.swift must not be duplicated in the Models group'
  );
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
});
