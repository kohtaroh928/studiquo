import Foundation

/// The single source of the long data-handling text for document search. Screens that ask for the
/// permission show only a short summary and open `RAGDisclosureView`, which renders this text in full.
enum RAGDisclosureText {
    static let automaticSummary = "許可した範囲のPDFを、アプリ使用中に自動で登録して資料検索に使います。本文などをCloudflareへ送信し、回答のため関連する抜粋をOpenAIへ送信します。送信内容の全文は「詳細を見る」で確認できます。"
    static let automaticDetails: [String] = [
        "許可した範囲のPDFを、アプリ使用中に小分けで自動登録します。本文・文字認識結果・タイトル・ページ番号をCloudflareへ送信し、本文と検索用データを保存します。質問もCloudflareへ送り、関連する抜粋をOpenAIへ送信して回答します。ロック・暗号化・ゴミ箱の資料と通常の手書きノートは対象外です。",
        "この端末の資料には、別アカウントで保存したものが含まれる場合があります。送信する権限があるPDFだけを対象にしてください。初回の許可で従来の手動検索データは失効し、新しい登録へ切り替わります。",
        "構造解析済みの資料では、見出し、要素の種類・位置、解析方式などの情報もCloudflareへ送信し、本文と一緒に保存します。検索で使う位置情報は出典と共にOpenAIへ送信します。原PDFはこの処理では送信しません。"
    ]
    static let manualSummary = "選択したノート・PDFの本文などをCloudflareへ送信して検索用データを作り、回答のため関連する抜粋をOpenAIへ送信します。送信内容と保存期間は「詳細を見る」で確認できます。"
    static let manualDetails: [String] = [
        "選択したノート・PDFの本文、文字認識した本文、タイトル、ページ番号をCloudflareへ送信します。構造解析済みの資料では、見出し、要素の種類・位置、解析方式などの情報も送信し、本文と一緒に保存します。CloudflareのAIで検索用データを作成し、質問との関連度を評価します。本文と検索用データは資料の検索データ削除またはアカウント削除まで保存されます。検索時には質問もCloudflareへ送り、曖昧な質問では直前の質問も検索に使います。検索で見つかった抜粋と出典の位置情報は回答のためOpenAIへ送信します。原PDFはこの処理では送信しません。保護されたノートは対象外です。"
    ]
}
