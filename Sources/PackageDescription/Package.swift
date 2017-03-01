/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

#if os(Linux)
import Glibc
#else
import Darwin.C
#endif

/// The description for a complete package.
public final class Package {
    /// The description for a package dependency.
    public class Dependency {
        public let versionRange: Range<Version>
        public let url: String

        init(_ url: String, _ versionRange: Range<Version>) {
            self.url = url
            self.versionRange = versionRange
        }

        convenience init(_ url: String, _ versionRange: ClosedRange<Version>) {
            self.init(url, versionRange.lowerBound..<versionRange.upperBound.successor())
        }

        public class func Package(url: String, versions: Range<Version>) -> Dependency {
            return Dependency(url, versions)
        }
        public class func Package(url: String, versions: ClosedRange<Version>) -> Dependency {
            return Package(url: url, versions: versions.lowerBound..<versions.upperBound.successor())
        }
        public class func Package(url: String, majorVersion: Int) -> Dependency {
            return Dependency(url, Version(majorVersion, 0, 0)..<Version(majorVersion, .max, .max))
        }
        public class func Package(url: String, majorVersion: Int, minor: Int) -> Dependency {
            return Dependency(url, Version(majorVersion, minor, 0)..<Version(majorVersion, minor, .max))
        }
        public class func Package(url: String, _ version: Version) -> Dependency {
            return Dependency(url, version...version)
        }
    }
    
    /// The name of the package.
    public let name: String
  
    /// pkgconfig name to use for C Modules. If present, swiftpm will try to search for
    /// <name>.pc file to get the additional flags needed for the system module.
    public let pkgConfig: String?
    
    /// Providers array for System module
    public let providers: [SystemPackageProvider]?
  
    /// The list of targets.
    public var targets: [Target]

    /// The list of dependencies.
    public var dependencies: [Dependency]

    /// The list of swift versions, this package is compatible with.
    public var swiftLanguageVersions: [Int]?

    /// The list of folders to exclude.
    public var exclude: [String]

    /// Construct a package.
    public init(
        name: String,
        pkgConfig: String? = nil,
        providers: [SystemPackageProvider]? = nil,
        targets: [Target] = [],
        dependencies: [Dependency] = [],
        swiftLanguageVersions: [Int]? = nil,
        exclude: [String] = []
    ) {
        self.name = name
        self.pkgConfig = pkgConfig
        self.providers = providers
        self.targets = targets
        self.dependencies = dependencies
        self.swiftLanguageVersions = swiftLanguageVersions
        self.exclude = exclude

        // Add custom exit handler to cause package to be dumped at exit, if requested.
        //
        // FIXME: This doesn't belong here, but for now is the mechanism we use
        // to get the interpreter to dump the package when attempting to load a
        // manifest.

        // FIXME: Additional hackery here to avoid accessing 'arguments' in a
        // process whose 'main' isn't generated by Swift.
        // See https://bugs.swift.org/browse/SR-1119.
        if CommandLine.argc > 0 {
            if let fileNoOptIndex = CommandLine.arguments.index(of: "-fileno"),
                   let fileNo = Int32(CommandLine.arguments[fileNoOptIndex + 1]) {
                dumpPackageAtExit(self, fileNo: fileNo)
            }
        }
    }
}

public enum SystemPackageProvider {
    case Brew(String)
    case Apt(String)
}

extension SystemPackageProvider {
    public var nameValue: (String, String) {
        switch self {
        case .Brew(let name):
            return ("Brew", name)
        case .Apt(let name):
            return ("Apt", name)
        }
    }
}

// MARK: Equatable
extension Package : Equatable { }
public func ==(lhs: Package, rhs: Package) -> Bool {
    return (lhs.name == rhs.name &&
        lhs.targets == rhs.targets &&
        lhs.dependencies == rhs.dependencies)
}

extension Package.Dependency : Equatable { }
public func ==(lhs: Package.Dependency, rhs: Package.Dependency) -> Bool {
    return lhs.url == rhs.url && lhs.versionRange == rhs.versionRange
}

// MARK: Package JSON serialization

extension SystemPackageProvider {
    func toJSON() -> JSON {
        let (name, value) = nameValue
        return .dictionary(["name": .string(name),
            "value": .string(value)
        ])
    }
}

extension Package.Dependency {
    func toJSON() -> JSON {
        return .dictionary([
            "url": .string(url),
            "version": .dictionary([
                "lowerBound": .string(versionRange.lowerBound.description),
                "upperBound": .string(versionRange.upperBound.description)
            ])
        ])
    }
}

extension Package {
    func toJSON() -> JSON {
        var dict: [String: JSON] = [:]
        dict["name"] = .string(name)
        if let pkgConfig = self.pkgConfig {
            dict["pkgConfig"] = .string(pkgConfig)
        }
        dict["dependencies"] = .array(dependencies.map { $0.toJSON() })
        dict["exclude"] = .array(exclude.map { .string($0) })
        dict["targets"] = .array(targets.map { $0.toJSON() })
        if let providers = self.providers {
            dict["providers"] = .array(providers.map { $0.toJSON() })
        }
        if let swiftLanguageVersions = self.swiftLanguageVersions {
            dict["swiftLanguageVersions"] = .array(swiftLanguageVersions.map(JSON.int))
        }
        return .dictionary(dict)
    }
}

extension Target {
    func toJSON() -> JSON {
        return .dictionary([
            "name": .string(name),
            "dependencies": .array(dependencies.map { $0.toJSON() })
        ])
    }
}

extension Target.Dependency {
    func toJSON() -> JSON {
        switch self {
        case .Target(let name):
            return .string(name)
        }
    }
}

// MARK: Package Dumping

struct Errors {
    /// Storage to hold the errors.
    private var errors = [String]()

    /// Adds error to global error array which will be serialized and dumped in JSON at exit.
    mutating func add(_ str: String) {
        // FIXME: This will produce invalid JSON if string contains quotes. Assert it for now
        // and fix when we have escaping in JSON.
        assert(!str.characters.contains("\""), "Error string shouldn't have quotes in it.")
        errors += [str]
    }

    func toJSON() -> JSON {
        return .array(errors.map(JSON.string))
    }
}

func manifestToJSON(_ package: Package) -> String {
    var dict: [String: JSON] = [:]
    dict["package"] = package.toJSON()
    dict["products"] = .array(products.map { $0.toJSON() })
    dict["errors"] = errors.toJSON()
    return JSON.dictionary(dict).toString()
}

// FIXME: This function is public to let other modules get the JSON representation
// of the package without exposing the enum JSON defined in this module (because that'll
// leak to clients of PackageDescription i.e every Package.swift file).
public func jsonString(package: Package) -> String {
    return package.toJSON().toString()
}

var errors = Errors()
private var dumpInfo: (package: Package, fileNo: Int32)? = nil
private func dumpPackageAtExit(_ package: Package, fileNo: Int32) {
    func dump() {
        guard let dumpInfo = dumpInfo else { return }
        let fd = fdopen(dumpInfo.fileNo, "w")
        guard fd != nil else { return }
        fputs(manifestToJSON(dumpInfo.package), fd)
        fclose(fd)
    }
    dumpInfo = (package, fileNo)
    atexit(dump)
}
