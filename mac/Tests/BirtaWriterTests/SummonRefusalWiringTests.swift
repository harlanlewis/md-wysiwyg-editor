import XCTest
@testable import BirtaWriter

/// That the two screens reporting a refused summon are actually CONNECTED to the
/// registration, in the shipping app.
///
/// This exists because of what the other checks cannot see. `SettingsRowViewTests`
/// and `WelcomeScreenTests` hand each screen a `refusedSummonCombo` reader of
/// their own and read the sentence back off a real row, which pins the drawing
/// and says nothing about where production gets that reader. The parameter has a
/// default of `{ nil }` (ten checks build these two surfaces to look at something
/// else, and restating it in each is ten places to get it wrong), so deleting the
/// argument from either production call site leaves every one of those checks
/// green and the feature dead: the chord would be refused, the reader would
/// answer nil, and both screens would draw a row that reads as ordinary. That is
/// the shape AGENTS.md names, a guard that is ABSENT rather than wrong, and it is
/// invisible to every green run.
///
/// A source-text guard rather than a live one, in the shape and for the reason
/// `SummonReassertTests` gives: building the real `WindowSet` and `Coordinator`
/// means building a `WKWebView` and the WebKit helpers behind it, which nothing
/// in this suite starts, and a launch-time registration refusal cannot be staged
/// from a test process at all. Driving it for real means two copies of the app,
/// which is what the DEV flavour's separate chord exists for.
@MainActor
final class SummonRefusalWiringTests: XCTestCase {
    private func source(_ file: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BirtaWriterTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // mac
            .appendingPathComponent("Sources/BirtaWriter/\(file)")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("could not read \(url.path); if \(file) moved, this guard must follow it")
            return ""
        }
        return text
    }

    /// Every hop from the one registration to the two screens, named.
    ///
    /// Each is a place the chain can be cut, and cutting any of them is silent.
    /// Enumerated rather than written as four separate checks so the count is
    /// asserted: a sweep that reached nothing passes.
    func testEveryHopFromTheRegistrationToTheScreensShouldBeWired() {
        let hops: [(file: String, needle: String, what: String)] = [
            ("Hotkey.swift", "refusedCombo = status == noErr ? nil : combo",
             "GlobalHotkey stops keeping what it was refused"),
            ("WindowSet.swift", "var refusedSummonCombo: HotkeyCombo? { hotkey.refusedCombo }",
             "WindowSet stops exposing the refusal"),
            ("WindowSet.swift", "coordinator.refusedSummonCombo =",
             "a window is no longer told how to ask, so the first-run screen cannot"),
            // Each needle is the ARGUMENT at the construction site, not the name
            // of the parameter. `Coordinator` also declares a property by this
            // name, so the bare `refusedSummonCombo:` matched that declaration
            // and went on passing with the argument to `WelcomeView` deleted:
            // a guard that cannot fail for its own subject, found by mutating it
            // rather than by reading it.
            ("Coordinator.swift", "refusedSummonCombo: { [weak self] in self?.refusedSummonCombo?() }",
             "the first-run screen is built without the reader"),
            ("App.swift", "refusedSummonCombo: { [weak self] in self?.windows.refusedSummonCombo }",
             "the Settings pane is built without the reader"),
        ]
        var checked = 0
        for hop in hops {
            XCTAssertTrue(source(hop.file).contains(hop.needle),
                          "\(hop.file): \(hop.what) (looked for \(hop.needle))")
            checked += 1
        }
        XCTAssertEqual(checked, hops.count, "the sweep reached fewer hops than it names")
    }

    /// Both screens draw the row when they OPEN, not only when a chord is
    /// recorded.
    ///
    /// The bug was exactly this: the sentence lived in `hotkeyChosen` alone, so
    /// it existed for somebody who recorded a replacement and for nobody else,
    /// and a refused DEFAULT chord reached an `NSLog` and stopped (MAR-407). A
    /// refactor that moved `showSummon` back out of the open path would restore
    /// that, and the two drawing checks would still pass: they open the screen,
    /// but so does recording, and neither names which path drew the row.
    func testBothScreensShouldDrawTheSummonRowOnTheirOpenPath() {
        // Settings reaches it through `showPresence`, which is where it belongs:
        // the sentence names the surfaces that method decides, so the two
        // switches redraw it too.
        XCTAssertTrue(source("SettingsWindow.swift").contains("showSummon()"),
                      "the Settings pane no longer draws the summon row outside hotkeyChosen")
        XCTAssertTrue(source("WelcomeView.swift").contains("showSummon()"),
                      "the first-run screen no longer draws the summon row outside hotkeyChosen")
    }

    /// Nothing retries a refused registration.
    ///
    /// A deliberate answer rather than an omission, and the reason the launch
    /// answer is still true when a screen is opened later: a refusal this app
    /// never re-attempts is still a refusal, so the summon really is dead until
    /// somebody records a replacement. A timer that re-registered would make the
    /// stored answer stale AND make the chord start working at a moment nobody
    /// was watching, which leaves the same question these screens exist to
    /// answer, pointed the other way.
    ///
    /// Checked by COUNTING the ways in rather than by looking for a timer beside
    /// the call. Grepping the call's own line for `Timer` was the first cut and
    /// it could not catch what it named: a timer whose closure calls
    /// `registerHotkey()` on the next line passes it. Counting bites, because a
    /// retry has to be called from somewhere, and somewhere is a new call site.
    ///
    /// Three, all of them a person's own gesture: the launch, and the two
    /// recorders. A fourth is either the retry this decision refused, or a
    /// deliberate change that should arrive with this list updated and the
    /// decision re-argued.
    func testTheRegistrationShouldBeReachedOnlyFromALaunchOrARecorder() {
        let calls = (source("WindowSet.swift") + source("App.swift"))
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.contains("registerHotkey()") && !trimmed.hasPrefix("//")
                    && !trimmed.contains("func registerHotkey")
            }

        XCTAssertEqual(calls.count, 3,
                       "the ways into the summon registration changed; a new one is a retry "
                       + "unless somebody argued otherwise. Found:\n" + calls.joined(separator: "\n"))
    }
}
