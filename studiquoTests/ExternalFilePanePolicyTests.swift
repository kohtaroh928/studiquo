import XCTest
@testable import studiquo

final class ExternalFilePanePolicyTests: XCTestCase {
    private func state(
        _ resolution: ExternalFileBookmarkResolution = .resolved,
        exists: Bool = true,
        readable: Bool = true,
        download: ExternalFileDownloadStatus = .local
    ) -> ExternalFilePaneState {
        ExternalFilePanePolicy.state(
            resolution: resolution, fileExists: exists, isReadable: readable, downloadStatus: download
        )
    }

    func testReadableLocalFileIsReady() {
        XCTAssertEqual(state(), .ready, "読める手元のファイルは、そのまま表示できる状態になる必要があります。")
    }

    func testRefreshedBookmarkIsStillReady() {
        XCTAssertEqual(state(.refreshed), .ready, "古いブックマークを作り直せた場合も、ファイルを開ける必要があります。")
    }

    func testFailedBookmarkIsMissing() {
        XCTAssertEqual(state(.failed), .missing, "ブックマークを解決できないときは「見つかりません」になる必要があります。")
    }

    func testDeletedFileIsMissing() {
        XCTAssertEqual(state(exists: false), .missing, "ファイルが消えているときは「見つかりません」になる必要があります。")
    }

    func testUnreadableFileIsAccessDenied() {
        XCTAssertEqual(state(readable: false), .accessDenied, "ファイルはあるが読めないときは、権限なしとして区別する必要があります。")
    }

    func testNotDownloadedCloudFileIsLoadingEvenIfNotOnDisk() {
        XCTAssertEqual(
            state(exists: false, download: .notDownloaded), .loading,
            "未ダウンロードのクラウドファイルは、端末上に無くても「見つかりません」ではなく読み込み中にする必要があります。"
        )
        XCTAssertEqual(state(download: .downloading), .loading, "ダウンロード中は読み込み中を表示する必要があります。")
    }

    func testFailedBookmarkWinsOverDownloadStatus() {
        XCTAssertEqual(
            state(.failed, download: .downloading), .missing,
            "ブックマークが解決できないなら、ダウンロード状態に関わらず見つかりません扱いにする必要があります。"
        )
    }

    func testEmbeddedBrowserNeedsEnoughWidth() {
        let threshold = ExternalFilePanePolicy.minimumEmbeddedBrowserWidth
        XCTAssertFalse(ExternalFilePanePolicy.usesEmbeddedBrowser(paneWidth: threshold - 1), "狭いペインでは、ボタン経由のピッカーに切り替える必要があります。")
        XCTAssertTrue(ExternalFilePanePolicy.usesEmbeddedBrowser(paneWidth: threshold), "十分な幅があれば、ペイン内にブラウザを出せる必要があります。")
    }
}
