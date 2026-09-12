import AppKit
import Carbon.HIToolbox
import XCTest
@testable import BirtaWriter
@testable import BirtaWriterCore

/// What `GlobalHotkey` remembers about a registration macOS would not give it.
///
/// The surfaces that report a refused summon are checked against an injected
/// reader (`SettingsRowViewTests`, `WelcomeScreenTests`), which pins what they
/// DRAW and says nothing about where the answer comes from. This is the other
/// end: a real `RegisterEventHotKey` refusal against the real type, so the one
/// assignment joining them is executed by something rather than only reasoned
/// about.
///
/// ## What provokes the refusal here, and what that does NOT establish
///
/// A second registration for the same chord, taken out by this file under its
/// own `EventHotKeyID`. That is a SAME-PROCESS duplicate, and it is worth being
/// plain about, because the same distinction is what MAR-407 was filed on the
/// wrong side of: the ticket claimed reading the status detects another app's
/// claim, and a same-process duplicate is the only thing the status ever caught
/// before `kEventHotKeyExclusive` was asked for.
///
/// So these arms establish that a refused registration is recorded and a taken
/// one clears it. They establish nothing about the four-row holder/contender
/// table in `GlobalHotkey.registrationOptions`, which is a CROSS-process
/// measurement and cannot be made from one process: measured here, a duplicate
/// inside one process is refused whichever way either side asked, so an arm
/// written to assert that table would pass or fail for a reason with nothing to
/// do with what it named. Two such arms were written and deleted rather than
/// kept as decoration. The table stays a measurement in that header, and
/// checking it again needs two processes.
///
/// The app cannot collide with itself this way, incidentally: `register`
/// unregisters first. The collision below is with a registration the app does
/// not own and cannot clear, which is why it is available as a provocation at
/// all.
///
/// The chord is deliberately not one the app or this Mac uses, and every arm
/// hands it back.
@MainActor
final class HotkeyRegistrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    /// F16 with all four modifiers. Not in `HotkeyCombo`'s own key vocabulary
    /// and not any default of the app's, so nothing here contends with a copy of
    /// Birta Writer that happens to be running on this machine.
    private let chord = HotkeyCombo(keyCode: UInt32(kVK_F16),
                                    modifiers: HotkeyCombo.cmdKey | HotkeyCombo.optionKey
                                        | HotkeyCombo.controlKey | HotkeyCombo.shiftKey,
                                    spelling: "cmd+alt+ctrl+shift+f16")

    /// Take the chord out from under the app, under an id the app does not own.
    private func hold() -> (EventHotKeyRef?, OSStatus) {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x54535448), id: 99) // 'TSTH'
        let status = RegisterEventHotKey(chord.keyCode, chord.modifiers, id,
                                        GetEventDispatcherTarget(),
                                        OptionBits(kEventHotKeyExclusive), &ref)
        return (ref, status)
    }

    /// The control that makes the refusal below mean something: with nobody
    /// holding it, this chord registers cleanly. Without this arm a refusal
    /// could be the chord being unusable on this Mac rather than taken.
    func testAnUnheldChordShouldRegisterAndLeaveNothingRecordedAsRefused() {
        let hotkey = GlobalHotkey()
        defer { hotkey.unregister() }

        let status = hotkey.register(chord)

        XCTAssertEqual(status, noErr, "the control arm could not take a chord nobody holds")
        XCTAssertNil(hotkey.refusedCombo)
    }

    /// A refused registration is KEPT, which is the line the whole fix rests on:
    /// the surfaces that report it are opened long after the attempt, so a
    /// status read and dropped at the call site is a refusal nobody can draw.
    func testARefusedRegistrationShouldBeRecorded() {
        let (held, holdStatus) = hold()
        defer { if let held { UnregisterEventHotKey(held) } }
        // Asserted, not assumed. A holder that failed to install would leave the
        // arm below reading a CLEAN registration, and "nothing was refused" is
        // exactly what this test exists to rule out, so the instrument has to
        // say it reached its subject.
        XCTAssertEqual(holdStatus, noErr, "could not take the chord, so nothing below is a refusal")

        let hotkey = GlobalHotkey()
        defer { hotkey.unregister() }
        let status = hotkey.register(chord)

        XCTAssertNotEqual(status, noErr, "the chord was not refused, so this arm measured nothing")
        XCTAssertEqual(hotkey.refusedCombo, chord,
                       "the refusal was dropped, which is the failure MAR-407 is about")
        XCTAssertNil(hotkey.combo, "a chord it does not hold must not read as the one in force")
    }

    /// The other direction, which is what stops a build that records every chord
    /// as refused from passing the arm above.
    func testAReplacementTheSystemTakesShouldClearTheRefusal() {
        let (held, holdStatus) = hold()
        XCTAssertEqual(holdStatus, noErr, "could not take the chord, so nothing below is a refusal")

        let hotkey = GlobalHotkey()
        defer { hotkey.unregister() }
        XCTAssertNotEqual(hotkey.register(chord), noErr)
        XCTAssertEqual(hotkey.refusedCombo, chord)

        // The holder goes away, and the person records the same chord again.
        if let held { UnregisterEventHotKey(held) }
        let second = hotkey.register(chord)

        XCTAssertEqual(second, noErr)
        XCTAssertNil(hotkey.refusedCombo, "a refusal outlived the registration that replaced it")
        XCTAssertEqual(hotkey.combo, chord)
    }

    /// `register` unregisters first, so a rebind cannot be refused by the
    /// registration it is replacing.
    ///
    /// Worth an arm of its own because it is the thing the ticket's original
    /// cause mistook for a cross-process conflict: if this ever started
    /// refusing, every recorder gesture would report the app's own previous
    /// chord as another app owning the new one.
    func testRebindingShouldNotBeRefusedByTheRegistrationItReplaces() {
        let hotkey = GlobalHotkey()
        defer { hotkey.unregister() }
        XCTAssertEqual(hotkey.register(chord), noErr)

        let again = hotkey.register(chord)

        XCTAssertEqual(again, noErr, "the app refused itself its own chord")
        XCTAssertNil(hotkey.refusedCombo)
    }
}
