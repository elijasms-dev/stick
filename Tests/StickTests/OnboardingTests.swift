import AppKit
import XCTest
@testable import Stick

@MainActor
private final class PermissionFixture {
    var hasAccess = false
    var settingsCanOpen = true
    var requests = 0
    var settingsOpens = 0
    var reveals = 0
    var finishes = 0
    var noteListOpens = 0

    func makeController() -> OnboardingController {
        _ = NSApplication.shared
        return OnboardingController(
            checkAccess: { self.hasAccess },
            requestAccess: { self.requests += 1 },
            openSettings: { self.settingsOpens += 1; return self.settingsCanOpen },
            revealApp: { self.reveals += 1 },
            onFinish: { self.finishes += 1 },
            onShowNotes: { self.noteListOpens += 1 }
        )
    }
}

final class OnboardingTests: XCTestCase {
    func testDeniedAccessDoesNotPromptDuringInitializationOrRefresh() async {
        await MainActor.run {
            let permission = PermissionFixture()
            let controller = permission.makeController()
            defer { controller.close() }

            controller.refreshPermission()
            controller.refreshPermission()

            XCTAssertEqual(controller.stage, .needsAccess)
            XCTAssertEqual(permission.requests, 0)
            XCTAssertEqual(permission.settingsOpens, 0)
            XCTAssertEqual(permission.finishes, 0)
            XCTAssertFalse(controller.window?.isVisible ?? true)
        }
    }

    func testGrantAfterRequestBecomesReadyWithoutCompletingAutomatically() async {
        await MainActor.run {
            let permission = PermissionFixture()
            let controller = permission.makeController()
            defer { controller.close() }

            controller.performPrimaryAction()
            XCTAssertEqual(controller.stage, .waiting)
            XCTAssertEqual(permission.requests, 1)
            XCTAssertEqual(permission.settingsOpens, 0)

            controller.refreshPermission()
            XCTAssertEqual(controller.stage, .waiting)
            XCTAssertEqual(permission.requests, 1)

            permission.hasAccess = true
            controller.refreshPermission()
            XCTAssertEqual(controller.stage, .ready)
            XCTAssertEqual(permission.finishes, 0)
            XCTAssertEqual(permission.settingsOpens, 0)
            XCTAssertFalse(controller.window?.isVisible ?? true)

            controller.performPrimaryAction()
            XCTAssertEqual(permission.finishes, 1)
            XCTAssertEqual(permission.requests, 1)
        }
    }

    func testAlreadyGrantedAccessSkipsPermissionRequest() async {
        await MainActor.run {
            let permission = PermissionFixture()
            permission.hasAccess = true
            let controller = permission.makeController()
            defer { controller.close() }

            XCTAssertEqual(controller.stage, .ready)
            controller.performPrimaryAction()

            XCTAssertEqual(permission.finishes, 1)
            XCTAssertEqual(permission.requests, 0)
            XCTAssertEqual(permission.settingsOpens, 0)
        }
    }

    func testSettingsActionShowsNewlyGrantedStateBeforeFinishing() async {
        await MainActor.run {
            let permission = PermissionFixture()
            let controller = permission.makeController()
            defer { controller.close() }
            controller.performPrimaryAction()
            XCTAssertEqual(controller.stage, .waiting)

            // The user clicked "Open System Settings", but access changed before
            // the action ran. Show the ready instructions before accepting Finish.
            permission.hasAccess = true
            controller.performPrimaryAction()

            XCTAssertEqual(controller.stage, .ready)
            XCTAssertEqual(permission.finishes, 0)
            XCTAssertEqual(permission.settingsOpens, 0)
            XCTAssertEqual(permission.requests, 1)

            controller.performPrimaryAction()
            XCTAssertEqual(permission.finishes, 1)
        }
    }

    func testContinueRechecksRevokedAccessInsteadOfCompletingOrPrompting() async {
        await MainActor.run {
            let permission = PermissionFixture()
            permission.hasAccess = true
            let controller = permission.makeController()
            defer { controller.close() }
            XCTAssertEqual(controller.stage, .ready)

            // Permission can change in Settings between the ready screen and the click.
            permission.hasAccess = false
            controller.performPrimaryAction()

            XCTAssertEqual(controller.stage, .needsAccess)
            XCTAssertEqual(permission.finishes, 0)
            XCTAssertEqual(permission.requests, 0)
            XCTAssertEqual(permission.settingsOpens, 0)
        }
    }

    func testDismissedControllerCanDetectLaterGrantWithoutCompleting() async {
        await MainActor.run {
            let permission = PermissionFixture()
            let controller = permission.makeController()
            controller.performPrimaryAction()
            controller.close()
            XCTAssertEqual(permission.finishes, 0)

            // Revisit the same controller without ordering a window onscreen in tests.
            permission.hasAccess = true
            controller.refreshPermission()
            XCTAssertEqual(controller.stage, .ready)
            XCTAssertEqual(permission.finishes, 0)
            XCTAssertEqual(permission.requests, 1)

            controller.close()
            XCTAssertEqual(permission.finishes, 0)
            controller.performPrimaryAction()
            XCTAssertEqual(permission.finishes, 1)
        }
    }

    func testSettingsRetryIsExplicitAndFailureDoesNotGrantAccess() async {
        await MainActor.run {
            let permission = PermissionFixture()
            permission.settingsCanOpen = false
            let controller = permission.makeController()
            defer { controller.close() }

            controller.performPrimaryAction()
            controller.refreshPermission()
            XCTAssertEqual(permission.settingsOpens, 0)

            controller.performPrimaryAction()
            XCTAssertEqual(permission.settingsOpens, 1)
            XCTAssertEqual(controller.stage, .waiting)
            XCTAssertEqual(permission.requests, 1)
            XCTAssertEqual(permission.finishes, 0)

            controller.refreshPermission()
            XCTAssertEqual(permission.settingsOpens, 1)
            permission.settingsCanOpen = true
            controller.performPrimaryAction()
            XCTAssertEqual(permission.settingsOpens, 2)
            XCTAssertEqual(permission.requests, 1)
            XCTAssertEqual(controller.stage, .waiting)
            XCTAssertEqual(permission.finishes, 0)
        }
    }
}
