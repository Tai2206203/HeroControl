#!/usr/bin/env python3
"""Generate a dependency-free, shared-scheme Xcode project. Python stdlib only."""
from pathlib import Path
import hashlib
import json
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent

def ident(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

def quote(value):
    return json.dumps(str(value), ensure_ascii=True)

objects = []

def obj(name, isa, fields):
    objects.append(f'{ident(name)} = {{ isa = {isa}; {fields} }};')
    return ident(name)

def array(values):
    return '(' + ', '.join(values) + (',' if values else '') + ')'

def settings(values):
    return '{ ' + ' '.join(f'{k} = {quote(v)};' for k, v in values.items()) + ' }'

source_names = sorted(f.name for f in (ROOT / 'HeroControl').glob('*.swift'))
test_names = sorted(f.name for f in (ROOT / 'HeroControlTests').glob('*.swift'))
for group, names in [('App', source_names), ('Tests', test_names)]:
    for name in names:
        ref = obj(f'{group}/{name}', 'PBXFileReference', f'lastKnownFileType = sourcecode.swift; path = {quote(name)}; sourceTree = "<group>";')
        obj(f'Build/{group}/{name}', 'PBXBuildFile', f'fileRef = {ref};')
obj('Info', 'PBXFileReference', 'lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";')
obj('Theme', 'PBXFileReference', 'lastKnownFileType = folder; path = "../Assets/Theme"; sourceTree = "<group>";')
obj('Build/Theme', 'PBXBuildFile', f'fileRef = {ident("Theme")};')
obj('Product/App', 'PBXFileReference', 'explicitFileType = wrapper.application; includeInIndex = 0; path = HeroControl.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('Product/Tests', 'PBXFileReference', 'explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = HeroControlTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj('Group/App', 'PBXGroup', f'children = {array([ident("App/" + n) for n in source_names] + [ident("Info"), ident("Theme")])}; path = HeroControl; sourceTree = "<group>";')
obj('Group/Tests', 'PBXGroup', f'children = {array([ident("Tests/" + n) for n in test_names])}; path = HeroControlTests; sourceTree = "<group>";')
obj('Group/Products', 'PBXGroup', f'children = {array([ident("Product/App"), ident("Product/Tests")])}; name = Products; sourceTree = "<group>";')
obj('Group/Main', 'PBXGroup', f'children = {array([ident("Group/App"), ident("Group/Tests"), ident("Group/Products")])}; sourceTree = "<group>";')

for group, names in [('App', source_names), ('Tests', test_names)]:
    for phase, isa in [('Sources', 'PBXSourcesBuildPhase'), ('Frameworks', 'PBXFrameworksBuildPhase'), ('Resources', 'PBXResourcesBuildPhase')]:
        files = [ident(f'Build/{group}/{name}') for name in names] if phase == 'Sources' else []
        if group == 'App' and phase == 'Resources': files.append(ident('Build/Theme'))
        obj(f'Phase/{group}/{phase}', isa, f'buildActionMask = 2147483647; files = {array(files)}; runOnlyForDeploymentPostprocessing = 0;')

obj('TestProxy', 'PBXContainerItemProxy', f'containerPortal = {ident("Project")}; proxyType = 1; remoteGlobalIDString = {ident("Target/App")}; remoteInfo = HeroControl;')
obj('TestDependency', 'PBXTargetDependency', f'target = {ident("Target/App")}; targetProxy = {ident("TestProxy")};')

for group, name, kind in [('App', 'HeroControl', 'application'), ('Tests', 'HeroControlTests', 'bundle.unit-test')]:
    dependencies = [ident('TestDependency')] if group == 'Tests' else []
    phases = [ident(f'Phase/{group}/{p}') for p in ['Sources', 'Frameworks', 'Resources']]
    obj(f'Target/{group}', 'PBXNativeTarget',
        f'buildConfigurationList = {ident("Configurations/"+group)}; buildPhases = {array(phases)}; buildRules = (); dependencies = {array(dependencies)}; name = {name}; productName = {name}; productReference = {ident("Product/"+group)}; productType = {quote("com.apple.product-type."+kind)};')

project_settings = {
    'CLANG_ENABLE_MODULES': 'YES', 'CLANG_ENABLE_OBJC_ARC': 'YES',
    'IPHONEOS_DEPLOYMENT_TARGET': '17.0', 'SDKROOT': 'iphoneos',
    'SWIFT_VERSION': '5.0', 'SWIFT_STRICT_CONCURRENCY': 'minimal',
    'ENABLE_USER_SCRIPT_SANDBOXING': 'YES'
}
app_settings = {
    'PRODUCT_NAME': '$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER': 'local.herocontrol.app',
    'INFOPLIST_FILE': 'HeroControl/Info.plist', 'GENERATE_INFOPLIST_FILE': 'NO',
    'TARGETED_DEVICE_FAMILY': '1', 'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator',
    'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks',
    'CODE_SIGN_STYLE': 'Automatic', 'CURRENT_PROJECT_VERSION': '28', 'MARKETING_VERSION': '0.12.1'
}
test_settings = {
    'PRODUCT_NAME': '$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER': 'local.herocontrol.tests',
    'GENERATE_INFOPLIST_FILE': 'YES', 'TARGETED_DEVICE_FAMILY': '1',
    'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/HeroControl.app/HeroControl', 'BUNDLE_LOADER': '$(TEST_HOST)',
    'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator', 'CODE_SIGN_STYLE': 'Automatic'
}
for group, base in [('Project', project_settings), ('App', app_settings), ('Tests', test_settings)]:
    for mode in ['Debug', 'Release']:
        values = dict(base)
        if group == 'Project':
            values.update({'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if mode == 'Debug' else '-O',
                           'DEBUG_INFORMATION_FORMAT': 'dwarf' if mode == 'Debug' else 'dwarf-with-dsym',
                           'ENABLE_TESTABILITY': 'YES' if mode == 'Debug' else 'NO'})
        obj(f'Configuration/{group}/{mode}', 'XCBuildConfiguration', f'buildSettings = {settings(values)}; name = {mode};')
    obj(f'Configurations/{group}', 'XCConfigurationList', f'buildConfigurations = {array([ident(f"Configuration/{group}/{m}") for m in ["Debug", "Release"]])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('Project', 'PBXProject',
    f'attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; TargetAttributes = {{ {ident("Target/Tests")} = {{ TestTargetID = {ident("Target/App")}; }}; }}; }}; buildConfigurationList = {ident("Configurations/Project")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = vi; hasScannedForEncodings = 0; knownRegions = (vi, en, Base); mainGroup = {ident("Group/Main")}; productRefGroup = {ident("Group/Products")}; projectDirPath = ""; projectRoot = ""; targets = {array([ident("Target/App"), ident("Target/Tests")])};')
project = ROOT / 'HeroControl.xcodeproj'
project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{\narchiveVersion = 1; classes = {}; objectVersion = 56;\nobjects = {\n' + '\n'.join(objects) + '\n};\nrootObject = ' + ident('Project') + ';\n}\n', encoding='utf8', newline='\n')

scheme = ET.Element('Scheme', LastUpgradeVersion='1600', version='1.3')
build = ET.SubElement(scheme, 'BuildAction', parallelizeBuildables='YES', buildImplicitDependencies='YES')
entries = ET.SubElement(build, 'BuildActionEntries')
def reference(parent, group):
    is_app = group == 'App'
    ET.SubElement(parent, 'BuildableReference', BuildableIdentifier='primary', BlueprintIdentifier=ident('Target/'+group),
                  BuildableName='HeroControl.app' if is_app else 'HeroControlTests.xctest',
                  BlueprintName='HeroControl' if is_app else 'HeroControlTests', ReferencedContainer='container:HeroControl.xcodeproj')
for group in ['App', 'Tests']:
    entry = ET.SubElement(entries, 'BuildActionEntry', buildForTesting='YES', buildForRunning='YES' if group == 'App' else 'NO',
                          buildForProfiling='YES' if group == 'App' else 'NO', buildForArchiving='YES' if group == 'App' else 'NO',
                          buildForAnalyzing='YES')
    reference(entry, group)
test = ET.SubElement(scheme, 'TestAction', buildConfiguration='Debug', selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB',
                     selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', shouldUseLaunchSchemeArgsEnv='YES')
reference(ET.SubElement(ET.SubElement(test, 'Testables'), 'TestableReference', skipped='NO'), 'Tests')
launch = ET.SubElement(scheme, 'LaunchAction', buildConfiguration='Debug', selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB',
                       selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', launchStyle='0', useCustomWorkingDirectory='NO',
                       ignoresPersistentStateOnLaunch='NO', debugDocumentVersioning='YES', allowLocationSimulation='YES')
reference(ET.SubElement(launch, 'BuildableProductRunnable', runnableDebuggingMode='0'), 'App')
ET.SubElement(scheme, 'AnalyzeAction', buildConfiguration='Debug')
ET.SubElement(scheme, 'ArchiveAction', buildConfiguration='Release', revealArchiveInOrganizer='YES')
scheme_path = project / 'xcshareddata' / 'xcschemes'
scheme_path.mkdir(parents=True, exist_ok=True)
ET.indent(scheme)
(scheme_path / 'HeroControl.xcscheme').write_bytes(ET.tostring(scheme, encoding='UTF-8', xml_declaration=True))
print('Generated HeroControl.xcodeproj and shared test scheme')
