#!/usr/bin/env python3
import os
import hashlib

PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
XCODEPROJ_DIR = os.path.join(PROJECT_DIR, "Handshake.xcodeproj")
SHAREDDATA_DIR = os.path.join(XCODEPROJ_DIR, "xcshareddata", "xcschemes")
WORKSPACE_DIR = os.path.join(XCODEPROJ_DIR, "project.xcworkspace")

os.makedirs(SHAREDDATA_DIR, exist_ok=True)
os.makedirs(WORKSPACE_DIR, exist_ok=True)

# Generate project.xcworkspace/contents.xcworkspacedata
workspace_content = """<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
   <FileRef
      location = "group:Packages/HandshakeCore">
   </FileRef>
</Workspace>
"""
with open(os.path.join(WORKSPACE_DIR, "contents.xcworkspacedata"), "w") as f:
    f.write(workspace_content)

# Helper to generate deterministic 24-char hex IDs
def make_id(key: str) -> str:
    h = hashlib.sha256(key.encode("utf-8")).hexdigest()[:24].upper()
    return h

def get_files(rel_dir):
    full_path = os.path.join(PROJECT_DIR, rel_dir)
    files = []
    for root, _, filenames in os.walk(full_path):
        for fn in sorted(filenames):
            if fn.endswith(".swift"):
                rel_f = os.path.relpath(os.path.join(root, fn), PROJECT_DIR)
                files.append(rel_f)
    return files

ios_swift_files = get_files("Applications/Handshake-iOS")
mac_swift_files = get_files("Applications/Handshake-macOS")

# IDs
ID_PROJECT = make_id("PROJECT_ROOT")
ID_MAIN_GROUP = make_id("MAIN_GROUP")
ID_PRODUCTS_GROUP = make_id("PRODUCTS_GROUP")
ID_FRAMEWORKS_GROUP = make_id("FRAMEWORKS_GROUP")
ID_APPS_GROUP = make_id("APPS_GROUP")
ID_IOS_GROUP = make_id("IOS_GROUP")
ID_MAC_GROUP = make_id("MAC_GROUP")
ID_PACKAGES_GROUP = make_id("PACKAGES_GROUP")

ID_IOS_TARGET = make_id("TARGET_IOS")
ID_MAC_TARGET = make_id("TARGET_MAC")

ID_IOS_APP_PRODUCT = make_id("PRODUCT_IOS_APP")
ID_MAC_APP_PRODUCT = make_id("PRODUCT_MAC_APP")

ID_IOS_SOURCES_PHASE = make_id("SOURCES_IOS")
ID_IOS_FRAMEWORKS_PHASE = make_id("FRAMEWORKS_IOS")
ID_IOS_RESOURCES_PHASE = make_id("RESOURCES_IOS")

ID_MAC_SOURCES_PHASE = make_id("SOURCES_MAC")
ID_MAC_FRAMEWORKS_PHASE = make_id("FRAMEWORKS_MAC")
ID_MAC_RESOURCES_PHASE = make_id("RESOURCES_MAC")

ID_LOCAL_PKG_REF = make_id("LOCAL_PACKAGE_HANDSHAKECORE")
ID_PKG_PRODUCT_DEP_IOS = make_id("PKG_DEP_IOS")
ID_PKG_PRODUCT_DEP_MAC = make_id("PKG_DEP_MAC")
ID_BUILDFILE_PKG_IOS = make_id("BUILDFILE_PKG_IOS")
ID_BUILDFILE_PKG_MAC = make_id("BUILDFILE_PKG_MAC")

ID_PROJECT_CONFIG_LIST = make_id("PROJECT_CONFIG_LIST")
ID_PROJECT_CONFIG_DEBUG = make_id("PROJECT_CONFIG_DEBUG")
ID_PROJECT_CONFIG_RELEASE = make_id("PROJECT_CONFIG_RELEASE")

ID_IOS_CONFIG_LIST = make_id("IOS_CONFIG_LIST")
ID_IOS_CONFIG_DEBUG = make_id("IOS_CONFIG_DEBUG")
ID_IOS_CONFIG_RELEASE = make_id("IOS_CONFIG_RELEASE")

ID_MAC_CONFIG_LIST = make_id("MAC_CONFIG_LIST")
ID_MAC_CONFIG_DEBUG = make_id("MAC_CONFIG_DEBUG")
ID_MAC_CONFIG_RELEASE = make_id("MAC_CONFIG_RELEASE")

# Map files to IDs
ios_file_ids = {f: (make_id("FILEREF_" + f), make_id("BUILDFILE_" + f)) for f in ios_swift_files}
mac_file_ids = {f: (make_id("FILEREF_" + f), make_id("BUILDFILE_" + f)) for f in mac_swift_files}

# Build PBXSections
pbx_build_files = []
pbx_file_refs = []
pbx_ios_sources = []
pbx_mac_sources = []

# Package build files
pbx_build_files.append(f"\t\t{ID_BUILDFILE_PKG_IOS} /* HandshakeCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {ID_PKG_PRODUCT_DEP_IOS} /* HandshakeCore */; }};")
pbx_build_files.append(f"\t\t{ID_BUILDFILE_PKG_MAC} /* HandshakeCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {ID_PKG_PRODUCT_DEP_MAC} /* HandshakeCore */; }};")

for f, (fileref_id, buildfile_id) in ios_file_ids.items():
    basename = os.path.basename(f)
    pbx_file_refs.append(f"\t\t{fileref_id} /* {basename} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"{f}\"; sourceTree = \"<group>\"; }};")
    pbx_build_files.append(f"\t\t{buildfile_id} /* {basename} in Sources */ = {{isa = PBXBuildFile; fileRef = {fileref_id} /* {basename} */; }};")
    pbx_ios_sources.append(f"\t\t\t\t{buildfile_id} /* {basename} in Sources */,")

for f, (fileref_id, buildfile_id) in mac_file_ids.items():
    basename = os.path.basename(f)
    pbx_file_refs.append(f"\t\t{fileref_id} /* {basename} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"{f}\"; sourceTree = \"<group>\"; }};")
    pbx_build_files.append(f"\t\t{buildfile_id} /* {basename} in Sources */ = {{isa = PBXBuildFile; fileRef = {fileref_id} /* {basename} */; }};")
    pbx_mac_sources.append(f"\t\t\t\t{buildfile_id} /* {basename} in Sources */,")

# Products
pbx_file_refs.append(f"\t\t{ID_IOS_APP_PRODUCT} /* Handshake-iOS.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = \"Handshake-iOS.app\"; sourceTree = BUILT_PRODUCTS_DIR; }};")
pbx_file_refs.append(f"\t\t{ID_MAC_APP_PRODUCT} /* Handshake-macOS.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = \"Handshake-macOS.app\"; sourceTree = BUILT_PRODUCTS_DIR; }};")

# Write Scheme files
ios_scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{ID_IOS_TARGET}"
               BuildableName = "Handshake-iOS.app"
               BlueprintName = "Handshake-iOS"
               ReferencedContainer = "container:Handshake.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{ID_IOS_TARGET}"
            BuildableName = "Handshake-iOS.app"
            BlueprintName = "Handshake-iOS"
            ReferencedContainer = "container:Handshake.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
</Scheme>
"""
with open(os.path.join(SHAREDDATA_DIR, "Handshake-iOS.xcscheme"), "w") as f:
    f.write(ios_scheme)

macos_scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{ID_MAC_TARGET}"
               BuildableName = "Handshake-macOS.app"
               BlueprintName = "Handshake-macOS"
               ReferencedContainer = "container:Handshake.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{ID_MAC_TARGET}"
            BuildableName = "Handshake-macOS.app"
            BlueprintName = "Handshake-macOS"
            ReferencedContainer = "container:Handshake.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
</Scheme>
"""
with open(os.path.join(SHAREDDATA_DIR, "Handshake-macOS.xcscheme"), "w") as f:
    f.write(macos_scheme)

# Construct PBXProject content
ios_children = "\n".join([f"\t\t\t\t{fileref_id} /* {os.path.basename(f)} */," for f, (fileref_id, _) in ios_file_ids.items()])
mac_children = "\n".join([f"\t\t\t\t{fileref_id} /* {os.path.basename(f)} */," for f, (fileref_id, _) in mac_file_ids.items()])

pbxproj = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{chr(10).join(pbx_build_files)}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{chr(10).join(pbx_file_refs)}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{ID_IOS_FRAMEWORKS_PHASE} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{ID_BUILDFILE_PKG_IOS} /* HandshakeCore in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{ID_MAC_FRAMEWORKS_PHASE} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{ID_BUILDFILE_PKG_MAC} /* HandshakeCore in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{ID_MAIN_GROUP} = {{
			isa = PBXGroup;
			children = (
				{ID_IOS_GROUP} /* Handshake-iOS */,
				{ID_MAC_GROUP} /* Handshake-macOS */,
				{ID_PRODUCTS_GROUP} /* Products */,
				{ID_FRAMEWORKS_GROUP} /* Frameworks */,
			);
			sourceTree = "<group>";
		}};
		{ID_IOS_GROUP} /* Handshake-iOS */ = {{
			isa = PBXGroup;
			children = (
{ios_children}
			);
			name = "Handshake-iOS";
			sourceTree = "<group>";
		}};
		{ID_MAC_GROUP} /* Handshake-macOS */ = {{
			isa = PBXGroup;
			children = (
{mac_children}
			);
			name = "Handshake-macOS";
			sourceTree = "<group>";
		}};
		{ID_PRODUCTS_GROUP} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{ID_IOS_APP_PRODUCT} /* Handshake-iOS.app */,
				{ID_MAC_APP_PRODUCT} /* Handshake-macOS.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
		{ID_FRAMEWORKS_GROUP} /* Frameworks */ = {{
			isa = PBXGroup;
			children = (
			);
			name = Frameworks;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{ID_IOS_TARGET} /* Handshake-iOS */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {ID_IOS_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "Handshake-iOS" */;
			buildPhases = (
				{ID_IOS_SOURCES_PHASE} /* Sources */,
				{ID_IOS_FRAMEWORKS_PHASE} /* Frameworks */,
				{ID_IOS_RESOURCES_PHASE} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = "Handshake-iOS";
			packageProductDependencies = (
				{ID_PKG_PRODUCT_DEP_IOS} /* HandshakeCore */,
			);
			productName = "Handshake-iOS";
			productReference = {ID_IOS_APP_PRODUCT} /* Handshake-iOS.app */;
			productType = "com.apple.product-type.application";
		}};
		{ID_MAC_TARGET} /* Handshake-macOS */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {ID_MAC_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "Handshake-macOS" */;
			buildPhases = (
				{ID_MAC_SOURCES_PHASE} /* Sources */,
				{ID_MAC_FRAMEWORKS_PHASE} /* Frameworks */,
				{ID_MAC_RESOURCES_PHASE} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = "Handshake-macOS";
			packageProductDependencies = (
				{ID_PKG_PRODUCT_DEP_MAC} /* HandshakeCore */,
			);
			productName = "Handshake-macOS";
			productReference = {ID_MAC_APP_PRODUCT} /* Handshake-macOS.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{ID_PROJECT} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {{
					{ID_IOS_TARGET} = {{
						CreatedOnToolsVersion = 16.0;
						DevelopmentTeam = DW8DPY9ALB;
						ProvisioningStyle = Automatic;
					}};
					{ID_MAC_TARGET} = {{
						CreatedOnToolsVersion = 16.0;
					}};
				}};
			}};
			buildConfigurationList = {ID_PROJECT_CONFIG_LIST} /* Build configuration list for PBXProject "Handshake" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {ID_MAIN_GROUP};
			packageReferences = (
				{ID_LOCAL_PKG_REF} /* HandshakeCore */,
			);
			productRefGroup = {ID_PRODUCTS_GROUP} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{ID_IOS_TARGET} /* Handshake-iOS */,
				{ID_MAC_TARGET} /* Handshake-macOS */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{ID_IOS_RESOURCES_PHASE} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{ID_MAC_RESOURCES_PHASE} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{ID_IOS_SOURCES_PHASE} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{chr(10).join(pbx_ios_sources)}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{ID_MAC_SOURCES_PHASE} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{chr(10).join(pbx_mac_sources)}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCLocalSwiftPackageReference section */
		{ID_LOCAL_PKG_REF} /* HandshakeCore */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = Packages/HandshakeCore;
		}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		{ID_PKG_PRODUCT_DEP_IOS} /* HandshakeCore */ = {{
			isa = XCSwiftPackageProductDependency;
			package = {ID_LOCAL_PKG_REF} /* HandshakeCore */;
			productName = HandshakeCore;
		}};
		{ID_PKG_PRODUCT_DEP_MAC} /* HandshakeCore */ = {{
			isa = XCSwiftPackageProductDependency;
			package = {ID_LOCAL_PKG_REF} /* HandshakeCore */;
			productName = HandshakeCore;
		}};
/* End XCSwiftPackageProductDependency section */

/* Begin XCBuildConfiguration section */
		{ID_PROJECT_CONFIG_DEBUG} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNDEFINED_VARIABLES = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				MTL_FAST_MATH = YES;
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			}};
			name = Debug;
		}};
		{ID_PROJECT_CONFIG_RELEASE} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNDEFINED_VARIABLES = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				MTL_ENABLE_DEBUG_INFO = NO;
				MTL_FAST_MATH = YES;
				SWIFT_COMPILATION_MODE = "wholemodule";
				SWIFT_OPTIMIZATION_LEVEL = "-O";
			}};
			name = Release;
		}};
		{ID_IOS_CONFIG_DEBUG} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_IDENTITY = "Apple Development";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = DW8DPY9ALB;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = "Applications/Handshake-iOS/Resources/Info.plist";
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.shrihaan.handshake.ios;
				PRODUCT_NAME = "$(TARGET_NAME)";
				PROVISIONING_PROFILE_SPECIFIER = "";
				SDKROOT = iphoneos;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Debug;
		}};
		{ID_IOS_CONFIG_RELEASE} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_IDENTITY = "Apple Development";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = DW8DPY9ALB;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = "Applications/Handshake-iOS/Resources/Info.plist";
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.shrihaan.handshake.ios;
				PRODUCT_NAME = "$(TARGET_NAME)";
				PROVISIONING_PROFILE_SPECIFIER = "";
				SDKROOT = iphoneos;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Release;
		}};
		{ID_MAC_CONFIG_DEBUG} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_ENTITLEMENTS = "Applications/Handshake-macOS/Resources/Handshake-macOS.entitlements";
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Manual;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = "Applications/Handshake-macOS/Resources/Info.plist";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.shrihaan.handshake.mac;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = macosx;
				SUPPORTED_PLATFORMS = macosx;
				SWIFT_VERSION = 5.0;
			}};
			name = Debug;
		}};
		{ID_MAC_CONFIG_RELEASE} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_ENTITLEMENTS = "Applications/Handshake-macOS/Resources/Handshake-macOS.entitlements";
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Manual;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = "Applications/Handshake-macOS/Resources/Info.plist";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.shrihaan.handshake.mac;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = macosx;
				SUPPORTED_PLATFORMS = macosx;
				SWIFT_VERSION = 5.0;
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{ID_PROJECT_CONFIG_LIST} /* Build configuration list for PBXProject "Handshake" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ID_PROJECT_CONFIG_DEBUG} /* Debug */,
				{ID_PROJECT_CONFIG_RELEASE} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{ID_IOS_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "Handshake-iOS" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ID_IOS_CONFIG_DEBUG} /* Debug */,
				{ID_IOS_CONFIG_RELEASE} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{ID_MAC_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "Handshake-macOS" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ID_MAC_CONFIG_DEBUG} /* Debug */,
				{ID_MAC_CONFIG_RELEASE} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {ID_PROJECT} /* Project object */;
}}
"""

with open(os.path.join(XCODEPROJ_DIR, "project.pbxproj"), "w") as f:
    f.write(pbxproj)

print("Generated Handshake.xcodeproj successfully!")
