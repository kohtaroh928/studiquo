// Full-fidelity Swift syntax SAST. It never emits source text or literal values.
import Foundation
import CryptoKit
import SwiftParser
import SwiftSyntax

struct Finding: Encodable {
    let tool = "swift-syntax"
    let rule: String
    let path: String
    let line: Int
    let severity = "WARNING"
}
struct FileCoverage: Encodable {
    let path: String
    let sourceBytes: Int
    let parsedBytes: Int
    let tokens: Int
    let calls: Int
    let sha256: String
}
struct Result: Encodable {
    var findings: [Finding] = []
    var coverage: [FileCoverage] = []
    var errors: [String] = []
}

final class SecurityVisitor: SyntaxVisitor {
    let path: String
    let converter: SourceLocationConverter
    var findings: [Finding] = []
    var calls = 0

    init(path: String, tree: SourceFileSyntax) {
        self.path = path
        converter = SourceLocationConverter(fileName: path, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    // Resolve a syntactic member chain without joining arbitrary source text.
    func memberName(_ expression: ExprSyntax) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base,
           let prefix = memberName(base) {
            return prefix + "." + member.declName.baseName.text
        }
        return nil
    }

    func mentionsCredential(_ expression: ExprSyntax) -> Bool {
        expression.tokens(viewMode: .sourceAccurate).contains { token in
            let text = token.text.lowercased()
            return ["token", "password", "secret", "credential"].contains { text.contains($0) }
        }
    }

    func add(_ rule: String, node: FunctionCallExprSyntax) {
        findings.append(Finding(rule: "studiquo.swift." + rule, path: path,
                                line: converter.location(for: node.positionAfterSkippingLeadingTrivia).line))
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        calls += 1
        let arguments = Array(node.arguments)
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "set", member.base != nil,
           arguments.count == 2, arguments[0].label == nil,
           arguments[1].label?.text == "forKey",
           arguments[1].expression.is(StringLiteralExprSyntax.self),
           mentionsCredential(arguments[1].expression) {
            add("userdefaults-credential", node: node)
        }
        let name = memberName(node.calledExpression)
        if name == "URLCredential", arguments.count == 1, arguments[0].label?.text == "trust" {
            add("trust-all-challenge", node: node)
        }
        if ["print", "debugPrint"].contains(name ?? ""), arguments.count == 1,
           mentionsCredential(arguments[0].expression) {
            add("credential-log", node: node)
        }
        if ["Insecure.MD5.hash", "Insecure.SHA1.hash"].contains(name ?? "") {
            add("weak-hash", node: node)
        }
        // Visit every child, including nested calls, closures, macros and #if branches.
        return .visitChildren
    }
}

var result = Result()
for path in CommandLine.arguments.dropFirst() {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let source = String(data: data, encoding: .utf8) else {
            result.errors.append("Invalid UTF-8: " + path)
            continue
        }
        let tree = Parser.parse(source: source)
        // Full-fidelity round-trip prevents skipped text from becoming a successful scan.
        guard !tree.hasError, tree.description == source,
              tree.endPosition.utf8Offset == data.count else {
            result.errors.append("Incomplete Swift syntax parse: " + path)
            continue
        }
        let visitor = SecurityVisitor(path: path, tree: tree)
        visitor.walk(tree)
        result.findings += visitor.findings
        result.coverage.append(FileCoverage(path: path, sourceBytes: data.count,
                                            parsedBytes: tree.endPosition.utf8Offset,
                                            tokens: Array(tree.tokens(viewMode: .sourceAccurate)).count,
                                            calls: visitor.calls,
                                            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
    } catch {
        result.errors.append("Swift source read failed: " + path)
    }
}
if CommandLine.arguments.count < 2 {
    result.errors.append("Swift scan has zero input files")
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
if let data = try? encoder.encode(result) {
    FileHandle.standardOutput.write(data)
} else {
    exit(2)
}
exit(result.errors.isEmpty ? 0 : 2)
