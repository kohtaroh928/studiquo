import UIKit
import XCTest
@testable import studiquo

final class ScreenStateTransitionTests: XCTestCase {
    func testAnnouncementScreenTransitionsBetweenEmptyFailureAndUnreadActions() {
        XCTAssertEqual(AnnouncementScreenLogic.emptyMessageKey(loadFailed: false), "announcements.empty")
        XCTAssertEqual(AnnouncementScreenLogic.emptyMessageKey(loadFailed: true), "announcements.loadFailed")
        XCTAssertFalse(AnnouncementScreenLogic.showsMarkAllRead(unreadCount: 0))
        XCTAssertTrue(AnnouncementScreenLogic.showsMarkAllRead(unreadCount: 2))
    }

    func testAccountCreationValidationTracksFieldsAndBusyState() {
        XCTAssertFalse(AccountFlowLogic.canSubmitCredentials(email: "", password: "password", isBusy: false))
        XCTAssertFalse(AccountFlowLogic.canSubmitCredentials(email: "a@example.com", password: "", isBusy: false))
        XCTAssertFalse(AccountFlowLogic.canSubmitCredentials(email: "a@example.com", password: "password", isBusy: true))
        XCTAssertTrue(AccountFlowLogic.canSubmitCredentials(email: "a@example.com", password: "password", isBusy: false))
    }

    func testAccountVerificationSanitizesCodeAndOnboardingAdvances() {
        XCTAssertEqual(AccountFlowLogic.verificationCode(from: "12a34-5678"), "123456")
        XCTAssertEqual(AccountFlowLogic.nextOnboardingStep(current: 0, occupation: "大学生"), 1)
        XCTAssertEqual(AccountFlowLogic.nextOnboardingStep(current: 0, occupation: "社会人"), 2)
        XCTAssertEqual(AccountFlowLogic.nextOnboardingStep(current: 1, occupation: "大学生"), 2)
        XCTAssertNil(AccountFlowLogic.nextOnboardingStep(current: 2, occupation: "大学生"))
    }

    func testAutomaticBackupStateRefreshesAndOnlyRestoresListedBackup() {
        let first = NotebookBackupService.AutomaticBackup(
            url: URL(fileURLWithPath: "/tmp/first.json"), title: "first", date: Date(timeIntervalSince1970: 1)
        )
        let second = NotebookBackupService.AutomaticBackup(
            url: URL(fileURLWithPath: "/tmp/second.json"), title: "second", date: Date(timeIntervalSince1970: 2)
        )
        var state = AutomaticBackupRestoreState(load: { [] })
        XCTAssertTrue(state.backups.isEmpty)
        state.refresh { [second] }
        XCTAssertEqual(state.restoreURL(for: second), second.url)
        XCTAssertNil(state.restoreURL(for: first))
    }

    @MainActor
    func testIssueReportMovesFromIdleToSubmittingToSuccess() throws {
        var state = IssueReportFormState()
        state.description = "  保存時に画面が閉じます  "
        XCTAssertTrue(state.canSubmit)

        let submission = try XCTUnwrap(state.begin(capturedScreenshot: nil))
        XCTAssertEqual(submission.description, "保存時に画面が閉じます")
        XCTAssertNil(submission.screenshot)
        XCTAssertTrue(state.isSubmitting)
        XCTAssertFalse(state.canSubmit)

        state.completeSuccessfully()
        XCTAssertTrue(state.didSubmit)
        state.dismissSuccess()
        XCTAssertEqual(state.phase, .idle)
    }

    @MainActor
    func testIssueReportAttachmentIsOptIn() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        var withoutAttachment = IssueReportFormState()
        withoutAttachment.description = "問題"
        XCTAssertNil(try XCTUnwrap(withoutAttachment.begin(capturedScreenshot: image)).screenshot)

        var withAttachment = IssueReportFormState()
        withAttachment.description = "問題"
        withAttachment.attachScreenshot = true
        let payload = try XCTUnwrap(try XCTUnwrap(withAttachment.begin(capturedScreenshot: image)).screenshot)
        XCTAssertFalse(payload.data.isEmpty)
        XCTAssertEqual(payload.contentType, "image/jpeg")
    }

    func testIssueReportFailureTransitionsHaveSpecificMessages() {
        var rateLimited = IssueReportFormState()
        rateLimited.fail(rateLimited: true)
        XCTAssertEqual(rateLimited.errorMessage, "送信が多すぎます。少し時間をおいてからもう一度お試しください。")

        var general = IssueReportFormState()
        general.fail(rateLimited: false)
        XCTAssertEqual(general.errorMessage, "送信できませんでした。しばらくしてからもう一度お試しください。")
    }
}
