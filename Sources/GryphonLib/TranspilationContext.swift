//
// Copyright 2018 Vinicius Jorge Vendramini
//
// Licensed under the Hippocratic License, Version 2.1;
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://firstdonoharm.dev/version/2/1/license.md
//
// To the full extent allowed by law, this software comes "AS IS,"
// WITHOUT ANY WARRANTY, EXPRESS OR IMPLIED, and licensor and any other
// contributor shall not be liable to anyone for any damages or other
// liability arising from, out of, or in connection with the sotfware
// or this license, under any kind of legal claim.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation

public class TranspilationContext {
	let toolchainName: String?
	let swiftVersion: String
	let indentationString: String
	let defaultsToFinal: Bool
	let isUsingSwiftSyntax: Bool
	var compilationArguments: SwiftCompilationArguments
	let xcodeProjectPath: String?
	let target: String?

	/// All arguments that should be included in this `swiftc` compilation.
	public struct SwiftCompilationArguments {
		/// Absolute paths to any files included in the compilation, as well
		/// as any other `swiftc` arguments. These are stored in a
		/// single list because it might not be trivial to separate them.
		let absoluteFilePathsAndOtherArguments: List<String>
		/// The path to the SDK that should be used. On Linux, this is `nil`.
		let absolutePathToSDK: String?

		/// If no SDK path is given, tries to get the SDK path for the current OS
		/// (as opposed to an iOS SDK).
		init(
			absoluteFilePathsAndOtherArguments: List<String>,
			absolutePathToSDK: String? = nil) throws
		{
			self.absoluteFilePathsAndOtherArguments = absoluteFilePathsAndOtherArguments
			self.absolutePathToSDK = try absolutePathToSDK ?? TranspilationContext.getSDKPath()
		}

		/// Returns all the necessary arguments for a SourceKit request,
		/// including "-sdk" and the SDK path.
		var argumentsForSourceKit: MutableList<String> {
			let mutableArguments = absoluteFilePathsAndOtherArguments.toMutableList()
			if let sdkPath = absolutePathToSDK {
				mutableArguments.append("-sdk")
				mutableArguments.append(sdkPath)
			}
			return mutableArguments
		}
	}

	#if swift(>=5.3)
		static let swiftSyntaxVersion = "5.3"
	#else
		static let swiftSyntaxVersion = "5.2"
	#endif

	/// The base contexts are used for information that all transpilation contexts should contain,
	/// such as the Gryphon templates library (which can be calculated once and is the same every
	/// time). All transpilation contexts are initialized with the information from the base
	/// context that corresponds to their Swift version and whether they use SwiftSyntax. Base
	/// contexts are indexed in these maps by their Swift versions.
	static private let baseContextsForASTDumps: MutableMap<String, TranspilationContext> = [:]
	static private let baseContextsForSwiftSyntax: MutableMap<String, TranspilationContext> = [:]

	/// Returns the base context for the requested Swift version and SwiftSyntax usage. If one
	/// hasn't been created yet, create it then return it.
	static internal func getBaseContext(
		forToolchain toolchainName: String?,
		usingSwiftSyntax: Bool)
		throws -> TranspilationContext
	{
		let swiftVersion = try TranspilationContext.getVersionOfToolchain(toolchainName)

		let baseContexts = usingSwiftSyntax ? baseContextsForSwiftSyntax : baseContextsForASTDumps

		if let result = baseContexts[swiftVersion] {
			return result
		}
		else {
			let newContext = try TranspilationContext(
				toolchainName: toolchainName,
				usingSwiftSyntax: usingSwiftSyntax)
			try Utilities.processGryphonTemplatesLibrary(for: newContext)
			baseContexts[swiftVersion] = newContext
			return newContext
		}
	}

	/// Normal contexts should be initialized using the correct base context, which is done with the
	/// the public `init` method. This method is only for initializing the base contexts themselves.
	private init(toolchainName: String?, usingSwiftSyntax: Bool) throws {
		try TranspilationContext.checkToolchainSupport(toolchainName)

		self.toolchainName = toolchainName
		self.swiftVersion = try TranspilationContext.getVersionOfToolchain(toolchainName)
		self.indentationString = ""
		self.defaultsToFinal = false
		self.isUsingSwiftSyntax = usingSwiftSyntax
		self.templates = []
		self.compilationArguments = try SwiftCompilationArguments(absoluteFilePathsAndOtherArguments:
			[SupportingFile.gryphonTemplatesLibrary.absolutePath])
		self.xcodeProjectPath = nil
		self.target = nil
	}

	public init(
		toolchainName: String?,
		indentationString: String,
		defaultsToFinal: Bool,
		isUsingSwiftSyntax: Bool,
		compilationArguments: SwiftCompilationArguments,
		xcodeProjectPath: String?,
		target: String?)
		throws
	{
		try TranspilationContext.checkToolchainSupport(toolchainName)

		self.toolchainName = toolchainName
		self.swiftVersion = try TranspilationContext.getVersionOfToolchain(toolchainName)
		self.indentationString = indentationString
		self.defaultsToFinal = defaultsToFinal
		self.isUsingSwiftSyntax = isUsingSwiftSyntax
		self.compilationArguments = compilationArguments
		self.xcodeProjectPath = xcodeProjectPath
		self.target = target
		self.templates = try TranspilationContext
			.getBaseContext(forToolchain: toolchainName, usingSwiftSyntax: isUsingSwiftSyntax)
			.templates
			.toMutableList()
	}

	// MARK: - Templates

	//
	public struct TranspilationTemplate {
		let swiftExpression: Expression
		let templateExpression: Expression
	}

	var templates: MutableList<TranspilationTemplate> = []

	public func addTemplate(_ template: TranspilationTemplate) {
		templates.insert(template, at: 0)
	}

	// MARK: - Declaration records

	/// This variable is used to store enum definitions in order to allow the translator
	/// to translate them as sealed classes (see the `translate(dotSyntaxCallExpression)` method).
	/// Uses enum names as keys, and the declarations themselves as values.
	private var sealedClasses: Atomic<MutableMap<String, EnumDeclaration>> = Atomic([:])

	/// This variable is used to store enum definitions in order to allow the translator
	/// to translate them as enum classes (see the `translate(dotSyntaxCallExpression)` method).
	/// Uses enum names as keys, and the declarations themselves as values.
	private var enumClasses: Atomic<MutableMap<String, EnumDeclaration>> = Atomic([:])

	public func addEnumClass(_ declaration: EnumDeclaration) {
		enumClasses.mutateAtomically { $0[declaration.enumName] = declaration }
	}

	public func addSealedClass(_ declaration: EnumDeclaration) {
		sealedClasses.mutateAtomically { $0[declaration.enumName] = declaration }
	}

	/// Gets an enum class with the given name, if one was recorded
	public func getEnumClass(named name: String) -> EnumDeclaration? {
		return enumClasses.atomic[name]
	}

	/// Gets a sealed class with the given name, if one was recorded
	public func getSealedClass(named name: String) -> EnumDeclaration? {
		return sealedClasses.atomic[name]
	}

	/// Gets an enum class or a sealed class with the given name, if one was recorded
	public func getEnum(named name: String) -> EnumDeclaration? {
		return enumClasses.atomic[name] ?? sealedClasses.atomic[name]
	}

	/// Checks if an enum class with the given name was recorded
	public func hasEnumClass(named name: String) -> Bool {
		return getEnumClass(named: name) != nil
	}

	/// Checks if a sealed class with the given name was recorded
	public func hasSealedClass(named name: String) -> Bool {
		return getSealedClass(named: name) != nil
	}

	/// Checks if an enum class or a sealed class with the given name was recorded
	public func hasEnum(named name: String) -> Bool {
		return getEnum(named: name) != nil
	}

	///
	/// This variable is used to store protocol definitions in order to allow the translator
	/// to translate conformances to them correctly (instead of as class inheritances).
	///
	internal var protocols: Atomic<MutableList<String>> = Atomic([])

	public func addProtocol(_ protocolName: String) {
		protocols.mutateAtomically { $0.append(protocolName) }
	}

	///
	/// This variable is used to store the inheritances (superclasses and protocols) of each type.
	/// Keys correspond to the full type name (e.g. `A.B.C`), values correspond to its
	/// inheritances.
	///
	private var inheritances: Atomic<MutableMap<String, List<String>>> = Atomic([:])

	/// Stores the inheritances for a given type. The type's name should include its parent
	/// types, e.g. `A.B.C` instead of just `C`.
	public func addInheritances(
		forFullType typeName: String,
		inheritances typeInheritances: List<String>)
	{
		inheritances.mutateAtomically { $0[typeName] = typeInheritances }
	}

	/// Gets the inheritances for a given type. The type's name should include its parent
	/// types, e.g. `A.B.C` instead of just `C`.
	public func getInheritance(forFullType typeName: String) -> List<String>? {
		return inheritances.atomic[typeName]
	}

	// MARK: - Function translations

	/// Stores information on how a Swift function should be translated into Kotlin, including what
	/// its prefix should be and what its parameters should be named. The `swiftAPIName` and the
	/// `type` properties are used to look up the right function translation, and they should match
	/// declarationReferences that reference this function.
	/// This is used, for instance, to translate a function to Kotlin using the internal parameter
	/// names instead of Swift's API label names, improving correctness and readability of the
	/// translation. The information has to be stored because declaration references don't include
	/// the internal parameter names, only the API names.
	public struct FunctionTranslation {
		let swiftAPIName: String
		let typeName: String
		let prefix: String
		let parameters: List<FunctionParameter>
	}

	private var functionTranslations: Atomic<MutableList<FunctionTranslation>> = Atomic([])

	public func addFunctionTranslation(_ newValue: FunctionTranslation) {
		functionTranslations.mutateAtomically { $0.append(newValue) }
	}

	public func getFunctionTranslation(forName name: String, typeName: String)
		-> FunctionTranslation?
	{
		// Functions with unnamed parameters here are identified only by their prefix. For instance
		// `f(_:_:)` here is named `f` but has been stored earlier as `f(_:_:)`.
		let allTranslations = functionTranslations.atomic
		for functionTranslation in allTranslations {
			// Avoid confusions with Void and ()
			let translationType = functionTranslation.typeName
				.replacingOccurrences(of: "Void", with: "()")
				.replacingOccurrences(of: "@autoclosure", with: "")
				.replacingOccurrences(of: "@escaping", with: "")
				.replacingOccurrences(of: " ", with: "")
				.replacingOccurrences(of: "throws", with: "")
			let functionType = typeName
				.replacingOccurrences(of: "Void", with: "()")
				.replacingOccurrences(of: "@autoclosure", with: "")
				.replacingOccurrences(of: "@escaping", with: "")
				.replacingOccurrences(of: " ", with: "")
				.replacingOccurrences(of: "throws", with: "")

			let translationPrefix = functionTranslation.swiftAPIName
				.prefix(while: { $0 != "(" && $0 != "<" })
			let namePrefix = name.prefix(while: { $0 != "(" && $0 != "<" })

			if translationPrefix == namePrefix,
				translationType == functionType
			{
				return functionTranslation
			}
		}

		return nil
	}

	// MARK: - Pure functions

	/// Stores pure functions so we can reference them later
	private var pureFunctions: Atomic<MutableList<FunctionDeclaration>> = Atomic([])

	public func recordPureFunction(_ newValue: FunctionDeclaration) {
		pureFunctions.mutateAtomically { $0.append(newValue) }
	}

	public func isReferencingPureFunction(
		_ callExpression: CallExpression)
		-> Bool
	{
		var finalCallExpression = callExpression.function
		while true {
			if let nextCallExpression = finalCallExpression as? DotExpression {
				finalCallExpression = nextCallExpression.rightExpression
			}
			else {
				break
			}
		}

		if let declarationExpression = finalCallExpression as? DeclarationReferenceExpression {
			let allPureFunctions = pureFunctions.atomic
			for functionDeclaration in allPureFunctions {
				if declarationExpression.identifier.hasPrefix(functionDeclaration.prefix),
					declarationExpression.typeName == functionDeclaration.functionType
				{
					return true
				}
			}
		}

		return false
	}

	// MARK: - Swift versions

	/// Currently supported versions. If 5.1 is supported, 5.1.x will be too.
	public static let supportedSwiftVersions: List = [
		"5.1", "5.2", "5.3",
	]

	/// Cache for the Swift version used by each toolchain (the key is the toolchain, the value is
	/// the Swift version). Toolchains inserted here should already have been checked. The default
	/// toolchain is represented as "".
	static private var toolchainSwiftVersions: MutableMap<String, String> = [:]

	/// Returns a string like "5.1" corresponding to the Swift version used by the given toolchain.
	static internal func getVersionOfToolchain(_ toolchain: String?) throws -> String {
		if let result = toolchainSwiftVersions[toolchain ?? ""] {
			return result
		}

		let arguments: List<String>
		if let toolchain = toolchain {
			arguments = ["xcrun", "--toolchain", toolchain, "swift", "--version"]
		}
		else if OS.osType == .macOS {
			arguments = ["xcrun", "swift", "--version"]
		}
		else {
			arguments = ["swift", "--version"]
		}

		let swiftVersionCommandResult = Shell.runShellCommand(arguments)

		guard swiftVersionCommandResult.status == 0 else {
			throw GryphonError(errorMessage: "Unable to determine Swift version:\n" +
				swiftVersionCommandResult.standardOutput +
				swiftVersionCommandResult.standardError)
		}

		// The output is expected to be something like
		// "Apple Swift version 5.1 (swift-5.1-RELEASE)"
		var swiftVersion = swiftVersionCommandResult.standardOutput
		let prefixToRemove = swiftVersion.prefix { !$0.isNumber }
		swiftVersion = String(swiftVersion.dropFirst(prefixToRemove.count))
		let endIndex = swiftVersion.index(swiftVersion.startIndex, offsetBy: 3)
		swiftVersion = String(swiftVersion[..<endIndex])

		try checkToolchainAndVersionSupport(toolchain, swiftVersion)

		toolchainSwiftVersions[toolchain ?? ""] = swiftVersion

		return swiftVersion
	}

	/// Checks if the given toolchain uses a supported version of Swift. If it doesn't, throw an
	/// error.
	static internal func checkToolchainSupport(_ toolchain: String?) throws {
		let swiftVersion = try getVersionOfToolchain(toolchain)
		try checkToolchainAndVersionSupport(toolchain, swiftVersion)
	}

	static private func checkToolchainAndVersionSupport(
		_ toolchain: String?,
		_ swiftVersion: String)
		throws
	{
		// If we already checked
		if let checkedVersion = toolchainSwiftVersions[toolchain ?? ""],
			checkedVersion == swiftVersion
		{
			return
		}

		guard supportedSwiftVersions.contains(where: { swiftVersion.hasPrefix($0) }) else {
			var errorMessage = ""

			if let toolchain = toolchain {
				errorMessage += "Swift version \(swiftVersion) (from toolchain \(toolchain)) " +
					"is not supported.\n"
			}
			else {
				errorMessage += "Swift version \(swiftVersion) is not supported.\n"
			}

			let supportedVersionsString = supportedSwiftVersions.joined(separator: ", ")
			errorMessage +=
				"Currently supported Swift versions: \(supportedVersionsString).\n" +
				"You can use the `--toolchain=<toolchain name>` option to choose a toolchain " +
				"with a supported Swift version."

			throw GryphonError(errorMessage: errorMessage)
		}
	}

	// MARK: - macOS SDK
	private static var sdkPath: String?
	private static let sdkLock: Semaphore = NSLock()

	/// On macOS, tries to find the SDK path using `xcrun`, and throws an error if that fails.
	/// On Linux, returns `nil`.
	static func getSDKPath() throws -> String? {
		sdkLock.lock()

		defer {
			sdkLock.unlock()
		}

		#if os(macOS)

		if let macOSSDKPath = sdkPath {
			return macOSSDKPath
		}
		else {
			let commandResult = Shell.runShellCommand(
				["xcrun", "--show-sdk-path", "--sdk", "macosx"])
			if commandResult.status == 0 {
				// Drop the \n at the end
				let result = String(commandResult.standardOutput.prefix(while: { $0 != "\n" }))
				sdkPath = result
				return result
			}
			else {
				throw GryphonError(errorMessage: "Unable to get macOS SDK path")
			}
		}

		#else

		return nil

		#endif
	}
}
