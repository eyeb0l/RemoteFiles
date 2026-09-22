#!/usr/bin/env python3
"""Generate the small app + hosted test project; package owns all library dependencies."""
from pathlib import Path
root = Path(__file__).resolve().parent.parent
objects = {}
def obj(key, value):
    ident = f'{len(objects)+1:024X}'
    objects[key] = (ident, value)
    return ident
hostapp = obj('hostapp', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = RemoteFilesTestHost.app; sourceTree = BUILT_PRODUCTS_DIR;')
app = obj('app', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = RemoteFiles.app; sourceTree = BUILT_PRODUCTS_DIR;')
test = obj('test', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = RemoteFilesTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
source = obj('source', 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = App/RemoteFilesApp.swift; sourceTree = SOURCE_ROOT;')
hostsource = obj('hostsource', 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = App/RemoteFilesTestHost.swift; sourceTree = SOURCE_ROOT;')
hostbuild = obj('hostbuild', f'isa = PBXBuildFile; fileRef = {hostsource};')
sourcebuild = obj('sourcebuild', f'isa = PBXBuildFile; fileRef = {source};')
local = obj('package', 'isa = XCLocalSwiftPackageReference; relativePath = .;')
ui = obj('ui', 'isa = XCSwiftPackageProductDependency; productName = RemoteFilesUI;')
core = obj('core', 'isa = XCSwiftPackageProductDependency; productName = RemoteFilesCore;')
uibuild = obj('uibuild', f'isa = PBXBuildFile; productRef = {ui};')
corebuild = obj('corebuild', f'isa = PBXBuildFile; productRef = {core};')
refs, builds = [], []
for p in sorted((root/'Tests/RemoteFilesCoreTests').glob('*.swift')):
    ref = obj('testref'+p.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{p.relative_to(root)}"; sourceTree = SOURCE_ROOT;')
    refs.append(ref)
    builds.append(obj('testbuild'+p.name, f'isa = PBXBuildFile; fileRef = {ref};'))
hostsources = obj('hostsources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({hostbuild},); runOnlyForDeploymentPostprocessing = 0;')
sources = obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({sourcebuild},); runOnlyForDeploymentPostprocessing = 0;')
testsources = obj('testsources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ('+','.join(builds)+'); runOnlyForDeploymentPostprocessing = 0;')
frameworks = obj('frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({uibuild},); runOnlyForDeploymentPostprocessing = 0;')
testframeworks = obj('testframeworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({corebuild},); runOnlyForDeploymentPostprocessing = 0;')
common = 'DEVELOPMENT_TEAM = 359794K46A; CODE_SIGN_STYLE = Automatic; CLANG_ENABLE_MODULES = YES; IPHONEOS_DEPLOYMENT_TARGET = 27.0; SDKROOT = iphoneos; SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = "1,2";'
appsettings = 'PRODUCT_BUNDLE_IDENTIFIER = dev.iris.RemoteFiles; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_CFBundleDisplayName = RemoteFiles; INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.productivity"; INFOPLIST_KEY_NSLocalNetworkUsageDescription = "Connect to the Mac you choose to browse files over SSH."; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"; CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; MARKETING_VERSION = 0.1.0;'
testsettings = 'PRODUCT_BUNDLE_IDENTIFIER = dev.iris.RemoteFilesTests; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; BUNDLE_LOADER = "$(TEST_HOST)"; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/RemoteFilesTestHost.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/RemoteFilesTestHost";'
def configs(name, settings):
    ids=[]
    for c in ['Debug','Release']:
        extra = 'ONLY_ACTIVE_ARCH = YES; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ENABLE_TESTABILITY = YES; DEBUG_INFORMATION_FORMAT = dwarf; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;' if c=='Debug' else 'SWIFT_COMPILATION_MODE = wholemodule; SWIFT_OPTIMIZATION_LEVEL = "-O";'
        ids.append(obj(name+c, f'isa = XCBuildConfiguration; name = {c}; buildSettings = {{ {common} {settings} {extra} }};'))
    return obj(name+'configs', f'isa = XCConfigurationList; buildConfigurations = ({ids[0]}, {ids[1]},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
uitestproduct = obj('uitestproduct', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = RemoteFilesUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
uitestsource = obj('uitestsource', 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Tests/RemoteFilesUITests/RemoteFilesUITests.swift; sourceTree = SOURCE_ROOT;')
uitestbuild = obj('uitestbuild', f'isa = PBXBuildFile; fileRef = {uitestsource};')
uitestsources = obj('uitestsources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({uitestbuild},); runOnlyForDeploymentPostprocessing = 0;')
uc = configs('uitest', 'PRODUCT_BUNDLE_IDENTIFIER = dev.iris.RemoteFilesUITests; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; TEST_TARGET_NAME = RemoteFiles;')
pc = configs('project','')
ac = configs('app',appsettings)
tc = configs('test',testsettings)
hc = configs('host',appsettings.replace('dev.iris.RemoteFiles;', 'dev.iris.RemoteFilesTestHost;'))
ht = obj('hosttarget', f'isa = PBXNativeTarget; buildConfigurationList = {hc}; buildPhases = ({hostsources},); buildRules = (); dependencies = (); name = RemoteFilesTestHost; productName = RemoteFilesTestHost; productReference = {hostapp}; productType = "com.apple.product-type.application"; packageProductDependencies = ();')
at = obj('apptarget', f'isa = PBXNativeTarget; buildConfigurationList = {ac}; buildPhases = ({sources}, {frameworks},); buildRules = (); dependencies = (); name = RemoteFiles; productName = RemoteFiles; productReference = {app}; productType = "com.apple.product-type.application"; packageProductDependencies = ({ui},);')
dep = obj('dependency', f'isa = PBXTargetDependency; target = {ht};')
tt = obj('testtarget', f'isa = PBXNativeTarget; buildConfigurationList = {tc}; buildPhases = ({testsources}, {testframeworks},); buildRules = (); dependencies = ({dep},); name = RemoteFilesTests; productName = RemoteFilesTests; productReference = {test}; productType = "com.apple.product-type.bundle.unit-test"; packageProductDependencies = ({core},);')
uidep = obj('uidependency', f'isa = PBXTargetDependency; target = {at};')
ut = obj('uitarget', f'isa = PBXNativeTarget; buildConfigurationList = {uc}; buildPhases = ({uitestsources},); buildRules = (); dependencies = ({uidep},); name = RemoteFilesUITests; productName = RemoteFilesUITests; productReference = {uitestproduct}; productType = "com.apple.product-type.bundle.ui-testing";')
products = obj('products',f'isa = PBXGroup; children = ({app},{hostapp},{test},{uitestproduct},); name = Products; sourceTree = "<group>";')
group = obj('group','isa = PBXGroup; children = ('+','.join([source,hostsource,uitestsource,*refs,products])+',); sourceTree = "<group>";')
project = obj('project',f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; }}; buildConfigurationList = {pc}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base,); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({at},{ht},{tt},{ut},); packageReferences = ({local},);')
pbx = '// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'
pbx += '\n'.join(f'{i} = {{ {v} }};' for i,v in objects.values())
pbx += f'\n}}; rootObject = {project}; }}\n'
(root/'RemoteFiles.xcodeproj/project.pbxproj').write_text(pbx)
def ref(i,n): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{i}" BuildableName="{n}" BlueprintName="{n.split(".")[0]}" ReferencedContainer="container:RemoteFiles.xcodeproj"/>'
scheme=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref(at,'RemoteFiles.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref(tt,'RemoteFilesTests.xctest')}</TestableReference><TestableReference skipped="NO">{ref(ut,'RemoteFilesUITests.xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(at,'RemoteFiles.app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(at,'RemoteFiles.app')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
(root/'RemoteFiles.xcodeproj/xcshareddata/xcschemes/RemoteFiles.xcscheme').write_text(scheme)
