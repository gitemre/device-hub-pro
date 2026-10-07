#!/usr/bin/env python3
"""Writes DeviceHubProAgent.xcodeproj (project.pbxproj and a shared scheme).

No third-party generator: run `python3 ios/agent/gen_project.py` after adding or
renaming a source file. No signing team, identity or profile is stored in the
project; pass DEVELOPMENT_TEAM=... CODE_SIGN_STYLE=Automatic to xcodebuild.
"""
import hashlib
import os

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.join(HERE, "DeviceHubProAgent.xcodeproj")

HOST_SOURCES = ["Host/AgentHostApp.swift"]
TEST_SOURCES = ["Tests/AgentServer.swift", "Tests/AgentActions.swift", "Tests/DeviceHubProAgentUITests.swift"]
HOST_BUNDLE = "com.devicehubpro.agent.host"
TEST_BUNDLE = "com.devicehubpro.agent.uitests"
DEPLOY = "26.0"


def oid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


objs = []  # (id, comment, body)


def add(name, body, comment=None):
    objs.append((oid(name), comment or name, body))
    return oid(name)


def ref(name):
    return oid(name)


# file references
file_ids = {}
for path in HOST_SOURCES + TEST_SOURCES:
    n = os.path.basename(path)
    file_ids[path] = add("file:" + path,
        f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {n}; sourceTree = "<group>";', n)
host_prod = add("prod:host", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = DeviceHubProAgentHost.app; sourceTree = BUILT_PRODUCTS_DIR;', "DeviceHubProAgentHost.app")
test_prod = add("prod:test", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = DeviceHubProAgentUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;', "DeviceHubProAgentUITests.xctest")

# build files
build_ids = {}
for path in HOST_SOURCES + TEST_SOURCES:
    build_ids[path] = add("build:" + path, f'isa = PBXBuildFile; fileRef = {file_ids[path]};', os.path.basename(path) + " in Sources")

# groups
host_group = add("group:host", "isa = PBXGroup; children = (%s); path = Host; sourceTree = \"<group>\";" % ", ".join(file_ids[p] for p in HOST_SOURCES), "Host")
test_group = add("group:tests", "isa = PBXGroup; children = (%s); path = Tests; sourceTree = \"<group>\";" % ", ".join(file_ids[p] for p in TEST_SOURCES), "Tests")
products = add("group:products", "isa = PBXGroup; children = (%s, %s); name = Products; sourceTree = \"<group>\";" % (host_prod, test_prod), "Products")
main_group = add("group:main", "isa = PBXGroup; children = (%s, %s, %s); sourceTree = \"<group>\";" % (host_group, test_group, products), "Main")

# phases
def phase(kind, name, files):
    return add(f"phase:{name}", f"isa = {kind}; buildActionMask = 2147483647; files = ({', '.join(files)}); runOnlyForDeploymentPostprocessing = 0;", name)

host_src = phase("PBXSourcesBuildPhase", "host-sources", [build_ids[p] for p in HOST_SOURCES])
host_fw = phase("PBXFrameworksBuildPhase", "host-frameworks", [])
host_res = phase("PBXResourcesBuildPhase", "host-resources", [])
test_src = phase("PBXSourcesBuildPhase", "test-sources", [build_ids[p] for p in TEST_SOURCES])
test_fw = phase("PBXFrameworksBuildPhase", "test-frameworks", [])
test_res = phase("PBXResourcesBuildPhase", "test-resources", [])

# configurations
common = {
    "SDKROOT": "iphoneos",
    "IPHONEOS_DEPLOYMENT_TARGET": DEPLOY,
    "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY": "1",
    "ONLY_ACTIVE_ARCH": "YES",
    "CLANG_ENABLE_MODULES": "YES",
}


def cfg_body(settings, name):
    lines = "; ".join(f'{k} = "{v}"' for k, v in sorted(settings.items()))
    return f"isa = XCBuildConfiguration; buildSettings = {{ {lines}; }}; name = {name};"


def cfg_list(tag, settings):
    ids = [add(f"cfg:{tag}:{n}", cfg_body(settings, n), n) for n in ("Debug", "Release")]
    return add(f"cfglist:{tag}", f"isa = XCConfigurationList; buildConfigurations = ({', '.join(ids)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;", tag)


proj_cfg = cfg_list("project", dict(common, ENABLE_TESTABILITY="YES"))
host_cfg = cfg_list("host", {
    "PRODUCT_BUNDLE_IDENTIFIER": HOST_BUNDLE,
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_KEY_CFBundleDisplayName": "Device Hub Pro Agent Host",
    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations": "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight UIInterfaceOrientationPortraitUpsideDown",
    "CURRENT_PROJECT_VERSION": "1",
    "MARKETING_VERSION": "1.0",
    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
})
test_cfg = cfg_list("tests", {
    "PRODUCT_BUNDLE_IDENTIFIER": TEST_BUNDLE,
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "GENERATE_INFOPLIST_FILE": "YES",
    "TEST_TARGET_NAME": "DeviceHubProAgentHost",
    "CURRENT_PROJECT_VERSION": "1",
    "MARKETING_VERSION": "1.0",
    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @loader_path/Frameworks",
})

# targets
host_t = add("target:host", f'isa = PBXNativeTarget; buildConfigurationList = {host_cfg}; buildPhases = ({host_src}, {host_fw}, {host_res}); buildRules = (); dependencies = (); name = DeviceHubProAgentHost; productName = DeviceHubProAgentHost; productReference = {host_prod}; productType = "com.apple.product-type.application";', "DeviceHubProAgentHost")
proxy = add("proxy", f'isa = PBXContainerItemProxy; containerPortal = {oid("project")}; proxyType = 1; remoteGlobalIDString = {host_t}; remoteInfo = DeviceHubProAgentHost;', "PBXContainerItemProxy")
dep = add("dep", f'isa = PBXTargetDependency; target = {host_t}; targetProxy = {proxy};', "PBXTargetDependency")
test_t = add("target:test", f'isa = PBXNativeTarget; buildConfigurationList = {test_cfg}; buildPhases = ({test_src}, {test_fw}, {test_res}); buildRules = (); dependencies = ({dep}); name = DeviceHubProAgentUITests; productName = DeviceHubProAgentUITests; productReference = {test_prod}; productType = "com.apple.product-type.bundle.ui-testing";', "DeviceHubProAgentUITests")

project = add("project", f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 2700; LastUpgradeCheck = 2700; TargetAttributes = {{ {test_t} = {{ TestTargetID = {host_t}; }}; }}; }}; buildConfigurationList = {proj_cfg}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {main_group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({host_t}, {test_t});', "Project object")
assert project == oid("project")

order = ["PBXBuildFile", "PBXContainerItemProxy", "PBXFileReference", "PBXFrameworksBuildPhase", "PBXGroup",
         "PBXNativeTarget", "PBXProject", "PBXResourcesBuildPhase", "PBXSourcesBuildPhase", "PBXTargetDependency",
         "XCBuildConfiguration", "XCConfigurationList"]
out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 56;", "\tobjects = {", ""]
for kind in order:
    section = [(i, c, b) for i, c, b in objs if b.startswith(f"isa = {kind};")]
    if not section:
        continue
    out.append(f"/* Begin {kind} section */")
    for i, c, b in sorted(section):
        out.append(f"\t\t{i} /* {c} */ = {{{b}}};")
    out.append(f"/* End {kind} section */\n")
out += ["\t};", f"\trootObject = {project} /* Project object */;", "}", ""]

os.makedirs(PROJ, exist_ok=True)
with open(os.path.join(PROJ, "project.pbxproj"), "w") as f:
    f.write("\n".join(out))

scheme_dir = os.path.join(PROJ, "xcshareddata", "xcschemes")
os.makedirs(scheme_dir, exist_ok=True)
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2700" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{host_t}" BuildableName = "DeviceHubProAgentHost.app" BlueprintName = "DeviceHubProAgentHost" ReferencedContainer = "container:DeviceHubProAgent.xcodeproj"/>
         </BuildActionEntry>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "NO" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{test_t}" BuildableName = "DeviceHubProAgentUITests.xctest" BlueprintName = "DeviceHubProAgentUITests" ReferencedContainer = "container:DeviceHubProAgent.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{test_t}" BuildableName = "DeviceHubProAgentUITests.xctest" BlueprintName = "DeviceHubProAgentUITests" ReferencedContainer = "container:DeviceHubProAgent.xcodeproj"/>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{host_t}" BuildableName = "DeviceHubProAgentHost.app" BlueprintName = "DeviceHubProAgentHost" ReferencedContainer = "container:DeviceHubProAgent.xcodeproj"/>
      </BuildableProductRunnable>
   </LaunchAction>
</Scheme>
'''
with open(os.path.join(scheme_dir, "DeviceHubProAgent.xcscheme"), "w") as f:
    f.write(scheme)
print("wrote", PROJ)
