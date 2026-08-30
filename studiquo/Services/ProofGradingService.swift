import Foundation
import UIKit

// MARK: - Result shapes

/// One line of the marking scheme, derived from the model answer before the
/// student's work is looked at.
struct ProofCriterion: Codable, Identifiable, Hashable {
    var name: String
    var maxPoints: Int
    /// What the answer must contain to earn the points.
    var requirement: String

    var id: String { name }
}

struct ProofRubric: Codable, Hashable {
    var criteria: [ProofCriterion]

    var totalPoints: Int { criteria.reduce(0) { $0 + $1.maxPoints } }
}

/// How a single criterion was met, once the answer has been read.
struct ProofCriterionResult: Codable, Identifiable, Hashable {
    var name: String
    var earnedPoints: Int
    var maxPoints: Int
    var comment: String

    var id: String { name }
}

/// A specific defect, classified so it can be colour-coded and so the student
/// can see what *kind* of mistake they keep making.
struct ProofIssue: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case logicalGap = "logical_gap"
        case counterexample
        case definitionError = "definition_error"
        case calculationError = "calculation_error"
        case unjustifiedAssumption = "unjustified_assumption"
        case presentation

        var title: String {
            switch self {
            case .logicalGap: "論理の飛躍"
            case .counterexample: "反例あり"
            case .definitionError: "定義の誤り"
            case .calculationError: "計算ミス"
            case .unjustifiedAssumption: "根拠のない仮定"
            case .presentation: "書き方"
            }
        }

        /// Severity ordering drives the colour: red for a broken proof, amber
        /// for a repairable gap, grey for style.
        var tint: String {
            switch self {
            case .counterexample, .definitionError: "red"
            case .logicalGap, .unjustifiedAssumption, .calculationError: "orange"
            case .presentation: "gray"
            }
        }
    }

    /// Which step of the student's work this is about, 1-based; 0 when it
    /// applies to the proof as a whole.
    var step: Int
    var kindRawValue: String
    /// The student's own words, quoted back so the remark can be located on
    /// the page.
    var excerpt: String
    var explanation: String
    var suggestion: String

    var id: String { "\(step)-\(kindRawValue)-\(excerpt.prefix(24))" }

    var kind: Kind { Kind(rawValue: kindRawValue) ?? .logicalGap }
}

struct ProofReviewResult: Codable, Hashable {
    var score: Int
    var maxScore: Int
    var verdict: String
    var criteria: [ProofCriterionResult]
    var issues: [ProofIssue]

    var percentage: Int {
        guard maxScore > 0 else { return 0 }
        return Int((Double(score) / Double(maxScore) * 100).rounded())
    }
}

// MARK: - Service

/// Marks a handwritten mathematical proof.
///
/// Two calls, deliberately:
///
/// 1. **Build a rubric** from the question and the model answer alone. Asking
///    for a score in one shot makes the result drift between runs; fixing the
///    criteria and their points *before* the student's work is visible is what
///    makes two runs of the same answer agree. The rubric is cached on the
///    page, so re-marking is a single call.
/// 2. **Mark the answer against that rubric**, from the page image.
///
/// The answer is sent as an image, not as recognised text. Handwritten
/// mathematics does not survive OCR — subscripts, quantifiers and fractions
/// are exactly what gets mangled — and a marker that reads a corrupted proof
/// grades the corruption.
enum ProofGradingService {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"
    private static let model = "claude-opus-5"

    enum GradingError: LocalizedError {
        case missingKey
        case missingModelAnswer
        case http(status: Int, message: String)
        case malformedResponse
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return L("AIのAPIキーが設定されていません。AIトークの設定から登録してください。")
            case .missingModelAnswer:
                return L("問題文と模範解答を入力すると添削できます。")
            case .http(let status, let message):
                if status == 401 { return L("APIキーが正しくないようです。") }
                if status == 429 { return L("リクエストが多すぎます。少し待ってからもう一度試してください。") }
                return L("添削できませんでした（\(status)）。\(message)")
            case .malformedResponse:
                return L("採点結果を読み取れませんでした。もう一度試してください。")
            case .transport(let message):
                return L("通信に失敗しました：\(message)")
            }
        }
    }

    // MARK: Stage 1 — rubric

    static func buildRubric(question: String, modelAnswer: String) async throws -> ProofRubric {
        let trimmedAnswer = modelAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnswer.isEmpty else { throw GradingError.missingModelAnswer }

        let system = """
        あなたは数学の証明を採点する教員です。これから問題文と模範解答を渡します。\
        答案はまだ見せません。この段階では採点基準（ルーブリック）だけを作ってください。

        - 模範解答を論証のステップに分け、各ステップを1つの基準にすること。
        - 各基準には「その点を得るために答案が満たさなければならない条件」を具体的に書くこと。
        - 配点の合計は100点にすること。
        - 表記の丁寧さより、論理の正しさに配点を厚くすること。
        - 基準は4〜8個に収めること。
        """

        let user = """
        <問題>
        \(question.trimmingCharacters(in: .whitespacesAndNewlines))
        </問題>

        <模範解答>
        \(trimmedAnswer)
        </模範解答>
        """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "criteria": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"],
                            "maxPoints": ["type": "integer"],
                            "requirement": ["type": "string"],
                        ],
                        "required": ["name", "maxPoints", "requirement"],
                        "additionalProperties": false,
                    ],
                ]
            ],
            "required": ["criteria"],
            "additionalProperties": false,
        ]

        let data = try await send(
            system: system,
            content: [["type": "text", "text": user]],
            schema: schema
        )
        guard let rubric = try? JSONDecoder().decode(ProofRubric.self, from: data) else {
            throw GradingError.malformedResponse
        }
        return rubric
    }

    // MARK: Stage 2 — mark the answer

    static func grade(
        answerImage: UIImage,
        question: String,
        rubric: ProofRubric
    ) async throws -> ProofReviewResult {
        guard let png = answerImage.pngData() else { throw GradingError.malformedResponse }

        let rubricText = rubric.criteria
            .map { "・\($0.name)（\($0.maxPoints)点）: \($0.requirement)" }
            .joined(separator: "\n")

        let system = """
        あなたは数学の証明を採点する教員です。画像は学生が手書きした答案です。

        採点の手順:
        1. まず答案を読み、論証のステップに分けて理解すること。
        2. 渡された採点基準の各項目について、答案が条件を満たしているか判定し、部分点を決めること。
        3. 誤りを見つけたら、その種類を分類すること。
           - logical_gap: 前のステップから次のステップへの根拠が不足している
           - counterexample: 主張が偽で、反例が存在する
           - definition_error: 定義や定理の使い方が誤っている
           - calculation_error: 論理は正しいが計算が誤っている
           - unjustified_assumption: 証明すべきことを仮定している、条件を勝手に足している
           - presentation: 内容は正しいが記述が不明瞭

        重要な原則:
        - 模範解答と違う道筋でも、論理が正しければ満点にすること。
        - 読み取れない箇所は推測で減点せず、その旨を excerpt に書くこと。
        - excerpt には学生自身が書いた表現を短く引用すること（採点者の言い換えではなく）。
        - suggestion は「次にどう直すか」を1文で書くこと。
        - verdict は2文以内で、まず良い点、次に最大の課題を述べること。
        - 日本語で書くこと。
        """

        let user = """
        <問題>
        \(question.trimmingCharacters(in: .whitespacesAndNewlines))
        </問題>

        <採点基準>
        \(rubricText)
        </採点基準>

        上の基準で、画像の答案を採点してください。
        """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "score": ["type": "integer"],
                "maxScore": ["type": "integer"],
                "verdict": ["type": "string"],
                "criteria": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"],
                            "earnedPoints": ["type": "integer"],
                            "maxPoints": ["type": "integer"],
                            "comment": ["type": "string"],
                        ],
                        "required": ["name", "earnedPoints", "maxPoints", "comment"],
                        "additionalProperties": false,
                    ],
                ],
                "issues": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "step": ["type": "integer"],
                            "kindRawValue": [
                                "type": "string",
                                "enum": ProofIssue.Kind.allCases.map(\.rawValue),
                            ],
                            "excerpt": ["type": "string"],
                            "explanation": ["type": "string"],
                            "suggestion": ["type": "string"],
                        ],
                        "required": ["step", "kindRawValue", "excerpt", "explanation", "suggestion"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["score", "maxScore", "verdict", "criteria", "issues"],
            "additionalProperties": false,
        ]

        let data = try await send(
            system: system,
            content: [
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/png",
                        "data": png.base64EncodedString(),
                    ],
                ],
                ["type": "text", "text": user],
            ],
            schema: schema
        )
        guard let result = try? JSONDecoder().decode(ProofReviewResult.self, from: data) else {
            throw GradingError.malformedResponse
        }
        return result
    }

    // MARK: Transport

    /// One structured-output request. Marking is slow, careful work rather
    /// than a chat turn, so it runs at high effort with adaptive thinking —
    /// the student is already waiting behind a progress indicator.
    private static func send(
        system: String,
        content: [[String: Any]],
        schema: [String: Any]
    ) async throws -> Data {
        guard let key = ClaudeChatService.apiKey else { throw GradingError.missingKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "thinking": ["type": "adaptive"],
            "output_config": [
                "effort": "high",
                "format": ["type": "json_schema", "schema": schema],
            ],
            "messages": [["role": "user", "content": content]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GradingError.transport(L("応答を読み取れませんでした。"))
            }
            guard 200..<300 ~= http.statusCode else {
                throw GradingError.http(status: http.statusCode, message: errorMessage(from: data))
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let blocks = object["content"] as? [[String: Any]] else {
                throw GradingError.malformedResponse
            }
            // With `output_config.format` set, the JSON arrives as the first
            // text block. Thinking blocks are skipped rather than parsed.
            guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
                  let payload = text.data(using: .utf8) else {
                throw GradingError.malformedResponse
            }
            return payload
        } catch let error as GradingError {
            throw error
        } catch {
            throw GradingError.transport(error.localizedDescription)
        }
    }

    private static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else { return "" }
        return message
    }
}
