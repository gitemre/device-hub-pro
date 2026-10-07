import Foundation
import Darwin

struct UHIDReportWords {
    var word0: UInt = 0
    var word1: UInt = 0
}

typealias UHIDHIDReport = UHIDReportWords
typealias UHIDDigitizerReport = UHIDReportWords
typealias UHIDDigitizerContact = UHIDReportWords
typealias UHIDDockSwipeReport = UHIDReportWords
typealias UHIDNavigationSwipeReport = UHIDReportWords
typealias UHIDPointerReport = UHIDReportWords
typealias UHIDScrollReport = UHIDReportWords
typealias UHIDScrollCollection = UHIDReportWords

var retainedHIDReports: [UHIDHIDReport] = []

@_silgen_name("$s12UniversalHID9HIDReportV8bitCount2idACSi_AA8ReportIDVtcfC")
func uhidHIDReportInit(_ bitCount: Int, _ reportID: UInt8) -> UHIDHIDReport

@_silgen_name("$s12UniversalHID15DigitizerReportV7_reportAcA9HIDReportV_tcfC")
func uhidDigitizerReportInitUnderscore(_ report: UHIDHIDReport) -> UHIDDigitizerReport

@_silgen_name("$s12UniversalHID15DigitizerReportV6reportAA9HIDReportVvg")
func uhidDigitizerReportGetReport(_ report: UHIDDigitizerReport) -> UHIDHIDReport

@_silgen_name("$s12UniversalHID16DigitizerContactVACycfC")
func uhidDigitizerContactInit() -> UHIDDigitizerContact

@_silgen_name("$s12UniversalHID9HIDReportV4data10Foundation4DataVvg")
func uhidHIDReportData(_ report: UHIDHIDReport) -> Data

@_silgen_name("$s12UniversalHID9HIDReportV4dataAC10Foundation4DataV_tcfC")
func uhidHIDReportInitData(_ data: Data) -> UHIDHIDReport

@_silgen_name("$s12UniversalHID9HIDReportV16debugDescriptionSSvg")
func uhidHIDReportDebugDescription(_ report: UHIDHIDReport) -> String

@_silgen_name("$s12UniversalHID15DockSwipeReportV07initialE8BitCountSivgZ")
func uhidDockSwipeReportInitialBitCount() -> Int

@_silgen_name("$s12UniversalHID15DockSwipeReportV8reportIDAA0eG0VvgZ")
func uhidDockSwipeReportID() -> UInt8

@_silgen_name("$s12UniversalHID15DockSwipeReportV7_reportAcA9HIDReportV_tcfC")
func uhidDockSwipeReportInitUnderscore(_ report: UHIDHIDReport) -> UHIDDockSwipeReport

@_silgen_name("$s12UniversalHID15DockSwipeReportV6reportAA9HIDReportVvg")
func uhidDockSwipeReportGetReport(_ report: UHIDDockSwipeReport) -> UHIDHIDReport

@_silgen_name("$s12UniversalHID15DockSwipeReportVMa")
func uhidDockSwipeReportMetadata(_ request: Int) -> UnsafeRawPointer

@_silgen_name("$s12UniversalHID21NavigationSwipeReportV07initialE8BitCountSivgZ")
func uhidNavigationSwipeReportInitialBitCount() -> Int

@_silgen_name("$s12UniversalHID21NavigationSwipeReportV8reportIDAA0eG0VvgZ")
func uhidNavigationSwipeReportID() -> UInt8

@_silgen_name("$s12UniversalHID21NavigationSwipeReportV7_reportAcA9HIDReportV_tcfC")
func uhidNavigationSwipeReportInitUnderscore(_ report: UHIDHIDReport) -> UHIDNavigationSwipeReport

@_silgen_name("$s12UniversalHID21NavigationSwipeReportV6reportAA9HIDReportVvg")
func uhidNavigationSwipeReportGetReport(_ report: UHIDNavigationSwipeReport) -> UHIDHIDReport

@_silgen_name("$s12UniversalHID21NavigationSwipeReportVMa")
func uhidNavigationSwipeReportMetadata(_ request: Int) -> UnsafeRawPointer

@_silgen_name("$s12UniversalHID13PointerReportV07initialD8BitCountSivgZ")
func uhidPointerReportInitialBitCount() -> Int

@_silgen_name("$s12UniversalHID13PointerReportV8reportIDAA0dF0VvgZ")
func uhidPointerReportID() -> UInt8

@_silgen_name("$s12UniversalHID13PointerReportV7_reportAcA9HIDReportV_tcfC")
func uhidPointerReportInitUnderscore(_ report: UHIDHIDReport) -> UHIDPointerReport

@_silgen_name("$s12UniversalHID13PointerReportV6reportAA9HIDReportVvg")
func uhidPointerReportGetReport(_ report: UHIDPointerReport) -> UHIDHIDReport

@_silgen_name("$s12UniversalHID12ScrollReportV07initialD8BitCountSivgZ")
func uhidScrollReportInitialBitCount() -> Int

@_silgen_name("$s12UniversalHID12ScrollReportV8reportIDAA0dF0VvgZ")
func uhidScrollReportID() -> UInt8

@_silgen_name("$s12UniversalHID12ScrollReportV7_reportAcA9HIDReportV_tcfC")
func uhidScrollReportInitUnderscore(_ report: UHIDHIDReport) -> UHIDScrollReport

@_silgen_name("$s12UniversalHID12ScrollReportV6reportAA9HIDReportVvg")
func uhidScrollReportGetReport(_ report: UHIDScrollReport) -> UHIDHIDReport

@_silgen_name("$s12UniversalHID16ScrollCollectionVACycfC")
func uhidScrollCollectionInit() -> UHIDScrollCollection

@_silgen_name("uhid_digitizer_contact_set_index_abi")
func uhidDigitizerContactSetIndexABI(_ contact: UnsafeMutablePointer<UHIDDigitizerContact>, _ index: Int)

@_silgen_name("uhid_hid_report_set_bit_abi")
func uhidHIDReportSetBitABI(_ report: UnsafeMutablePointer<UHIDHIDReport>, _ index: Int, _ value: UInt)

@_silgen_name("uhid_pointer_report_set_x_abi")
func uhidPointerReportSetXABI(_ report: UnsafeMutablePointer<UHIDPointerReport>, _ x: Int)

@_silgen_name("uhid_pointer_report_set_y_abi")
func uhidPointerReportSetYABI(_ report: UnsafeMutablePointer<UHIDPointerReport>, _ y: Int)

@_silgen_name("uhid_pointer_report_set_button_mask_abi")
func uhidPointerReportSetButtonMaskABI(_ report: UnsafeMutablePointer<UHIDPointerReport>, _ buttonMask: UInt8)

@_silgen_name("uhid_pointer_report_set_flags_abi")
func uhidPointerReportSetFlagsABI(_ report: UnsafeMutablePointer<UHIDPointerReport>, _ flags: UInt32)

@_silgen_name("uhid_pointer_report_set_accel_x_abi")
func uhidPointerReportSetAccelXABI(_ report: UnsafeMutablePointer<UHIDPointerReport>, _ accelX: Double)

@_silgen_name("uhid_pointer_report_set_accel_y_abi")
func uhidPointerReportSetAccelYABI(_ report: UnsafeMutablePointer<UHIDPointerReport>, _ accelY: Double)

@_silgen_name("uhid_scroll_collection_set_flags_abi")
func uhidScrollCollectionSetFlagsABI(_ collection: UnsafeMutablePointer<UHIDScrollCollection>, _ flags: UInt8)

@_silgen_name("uhid_scroll_collection_set_phase_abi")
func uhidScrollCollectionSetPhaseABI(_ collection: UnsafeMutablePointer<UHIDScrollCollection>, _ phase: UInt8)

@_silgen_name("uhid_scroll_collection_set_momentum_abi")
func uhidScrollCollectionSetMomentumABI(_ collection: UnsafeMutablePointer<UHIDScrollCollection>, _ momentum: UInt8)

@_silgen_name("uhid_scroll_collection_set_x_abi")
func uhidScrollCollectionSetXABI(_ collection: UnsafeMutablePointer<UHIDScrollCollection>, _ x: Int)

@_silgen_name("uhid_scroll_collection_set_y_abi")
func uhidScrollCollectionSetYABI(_ collection: UnsafeMutablePointer<UHIDScrollCollection>, _ y: Int)

@_silgen_name("uhid_scroll_collection_set_accel_x_abi")
func uhidScrollCollectionSetAccelXABI(_ collection: UnsafeMutablePointer<UHIDScrollCollection>, _ accelX: Double)

@_silgen_name("uhid_scroll_collection_set_accel_y_abi")
func uhidScrollCollectionSetAccelYABI(_ collection: UnsafeMutablePointer<UHIDScrollCollection>, _ accelY: Double)

@_silgen_name("uhid_scroll_report_set_collection_abi")
func uhidScrollReportSetCollectionABI(_ report: UnsafeMutablePointer<UHIDScrollReport>, _ collection: UnsafePointer<UHIDScrollCollection>)

@_silgen_name("uhid_digitizer_contact_set_touch_abi")
func uhidDigitizerContactSetTouchABI(_ contact: UnsafeMutablePointer<UHIDDigitizerContact>, _ touch: UInt8)

@_silgen_name("uhid_digitizer_contact_set_range_abi")
func uhidDigitizerContactSetRangeABI(_ contact: UnsafeMutablePointer<UHIDDigitizerContact>, _ range: UInt8)

@_silgen_name("uhid_digitizer_contact_set_resting_abi")
func uhidDigitizerContactSetRestingABI(_ contact: UnsafeMutablePointer<UHIDDigitizerContact>, _ resting: UInt8)

@_silgen_name("uhid_digitizer_contact_set_x_abi")
func uhidDigitizerContactSetXABI(_ contact: UnsafeMutablePointer<UHIDDigitizerContact>, _ x: Double)

@_silgen_name("uhid_digitizer_contact_set_y_abi")
func uhidDigitizerContactSetYABI(_ contact: UnsafeMutablePointer<UHIDDigitizerContact>, _ y: Double)

@_silgen_name("uhid_digitizer_report_set_contact_count_abi")
func uhidDigitizerReportSetContactCountABI(_ report: UnsafeMutablePointer<UHIDDigitizerReport>, _ count: UInt8)

@_silgen_name("uhid_digitizer_report_set_contact_count_maximum_abi")
func uhidDigitizerReportSetContactCountMaximumABI(_ report: UnsafeMutablePointer<UHIDDigitizerReport>, _ count: UInt8)

@_silgen_name("uhid_digitizer_report_set_contact_abi")
func uhidDigitizerReportSetContactABI(_ report: UnsafeMutablePointer<UHIDDigitizerReport>, _ contact: UnsafePointer<UHIDDigitizerContact>, _ index: Int)

@_silgen_name("uhid_digitizer_report_set_contact_swipe_pending_abi")
func uhidDigitizerReportSetContactSwipePendingABI(_ report: UnsafeMutablePointer<UHIDDigitizerReport>, _ pending: UInt8, _ index: Int)

@_silgen_name("uhid_digitizer_report_set_contact_swipe_locked_abi")
func uhidDigitizerReportSetContactSwipeLockedABI(_ report: UnsafeMutablePointer<UHIDDigitizerReport>, _ locked: UInt8, _ index: Int)

@_silgen_name("uhid_digitizer_report_set_contact_swipe_up_abi")
func uhidDigitizerReportSetContactSwipeUpABI(_ report: UnsafeMutablePointer<UHIDDigitizerReport>, _ up: UInt8, _ index: Int)

@_silgen_name("uhid_fluid_set_phase_abi")
func uhidFluidSetPhaseABI(_ report: UnsafeMutableRawPointer, _ metadata: UnsafeRawPointer, _ witness: UnsafeRawPointer, _ phase: UInt8)

@_silgen_name("uhid_fluid_set_swipe_mask_abi")
func uhidFluidSetSwipeMaskABI(_ report: UnsafeMutableRawPointer, _ metadata: UnsafeRawPointer, _ witness: UnsafeRawPointer, _ swipeMask: UInt32)

@_silgen_name("uhid_fluid_set_gesture_motion_abi")
func uhidFluidSetGestureMotionABI(_ report: UnsafeMutableRawPointer, _ metadata: UnsafeRawPointer, _ witness: UnsafeRawPointer, _ gestureMotion: UInt16)

@_silgen_name("uhid_fluid_set_flavor_abi")
func uhidFluidSetFlavorABI(_ report: UnsafeMutableRawPointer, _ metadata: UnsafeRawPointer, _ witness: UnsafeRawPointer, _ flavor: UInt16)

@_silgen_name("uhid_fluid_set_progress_abi")
func uhidFluidSetProgressABI(_ report: UnsafeMutableRawPointer, _ metadata: UnsafeRawPointer, _ witness: UnsafeRawPointer, _ progress: Double)

@_silgen_name("uhid_fluid_set_x_abi")
func uhidFluidSetXABI(_ report: UnsafeMutableRawPointer, _ metadata: UnsafeRawPointer, _ witness: UnsafeRawPointer, _ x: Double)

@_silgen_name("uhid_fluid_set_y_abi")
func uhidFluidSetYABI(_ report: UnsafeMutableRawPointer, _ metadata: UnsafeRawPointer, _ witness: UnsafeRawPointer, _ y: Double)

let universalHIDFrameworkPath = "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Frameworks/UniversalHID.framework/UniversalHID"
// Digitizer report length in bits (swipe fields and padding included), as upstream measured it.
let digitizerReportBitCount = 464
// ScrollReport layout: remoteTimestamp occupies bits 104..<168. Leave it zero,
// as ScrollReport.init(scrollEvent:) does; initialD8BitCount only covers 104 bits.
let scrollReportBitCount = 168
// AbsolutePointerReport's ID, from its reportID getter (a constant `movz`).
let absolutePointerReportID: UInt8 = 19
let universalHIDHandle = dlopen(universalHIDFrameworkPath, RTLD_NOW | RTLD_GLOBAL)

func universalHIDSymbol(_ name: String) -> UnsafeRawPointer {
    guard let handle = universalHIDHandle else {
        let message = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
        fatalError("Unable to open UniversalHID: \(message)")
    }
    guard let pointer = dlsym(handle, name) else {
        let message = dlerror().map { String(cString: $0) } ?? "unknown dlsym error"
        fatalError("Unable to resolve \(name): \(message)")
    }
    return UnsafeRawPointer(pointer)
}

let dockSwipeFluidWitness = universalHIDSymbol("$s12UniversalHID15DockSwipeReportVAA017FluidTouchGestureE8ProtocolAAWP")
let navigationSwipeFluidWitness = universalHIDSymbol("$s12UniversalHID21NavigationSwipeReportVAA017FluidTouchGestureE8ProtocolAAWP")

func makeDigitizerReportData(x: Double, y: Double, touching: Bool, inRange: Bool) -> Data {
    let digitizerReportID: UInt8 = 0x09

    let hidReport = uhidHIDReportInit(digitizerReportBitCount, digitizerReportID)
    var report = uhidDigitizerReportInitUnderscore(hidReport)
    var contact = uhidDigitizerContactInit()

    uhidDigitizerContactSetIndexABI(&contact, 0)
    uhidDigitizerContactSetTouchABI(&contact, touching ? 1 : 0)
    uhidDigitizerContactSetRangeABI(&contact, inRange ? 1 : 0)
    uhidDigitizerContactSetRestingABI(&contact, 0)
    uhidDigitizerContactSetXABI(&contact, x)
    uhidDigitizerContactSetYABI(&contact, y)

    uhidDigitizerReportSetContactABI(&report, &contact, 0)
    // Contact Count is "how many contacts this report describes", not "how many are still down"
    // (HID spec, and the report descriptor: bits 8-16, logical max 5). A lift still describes
    // contact 0, with Touch cleared, so it must be 1. Sending 0 meant a decoder iterating
    // 0..<contactCount never saw contact 0 lift: the finger was announced down and never up.
    uhidDigitizerReportSetContactCountABI(&report, 1)
    uhidDigitizerReportSetContactCountMaximumABI(&report, 1)

    return uhidHIDReportData(uhidDigitizerReportGetReport(report))
}

func clampUnit(_ value: Double) -> Double {
    if value.isNaN || value < 0 {
        return 0
    }
    if value > 1 {
        return 1
    }
    return value
}

func scaledUInt16(_ value: Double) -> UInt16 {
    UInt16((clampUnit(value) * 65535.0).rounded())
}

func putUInt16LE(_ value: UInt16, into data: inout Data, at index: Int) {
    data[index] = UInt8(value & 0xff)
    data[index + 1] = UInt8((value >> 8) & 0xff)
}

// Reports assembled directly from the wire layout captured from Device Hub.
//
// These do not go through ABI shims. The shims exist as the oracle for what
// Apple's own client sends, and for these two types the capture *is* that
// oracle: every field below was read off Device Hub's own traffic and checked
// against it (see docs/protocol.md, "Scroll: the full sequence"). Assembling
// the bytes here is also the only way to set remoteTimestamp, which the shim
// path leaves unset and which Device Hub populates on every report.

/// Device Hub stamps every report with `mach_absolute_time()`, in raw ticks
/// rather than nanoseconds.
///
/// Worked out by arithmetic on a capture: Device Hub's values were ~1.4e12
/// while `CLOCK_UPTIME_RAW` on the same host read ~6.4e13 ns. 1.4e12 ticks at
/// the 24 MHz Apple Silicon timebase is 16.2 hours, and 6.4e13 ns is 17.8
/// hours -- consistent once the ~1.5 hours between the capture and the check
/// are accounted for. Nanoseconds would have been off by a factor of ~46.
func reportTimestamp() -> UInt64 {
    mach_absolute_time()
}

private func putLE<T: FixedWidthInteger>(_ value: T, _ bytes: inout [UInt8], _ offset: Int) {
    var le = value.littleEndian
    withUnsafeBytes(of: &le) { raw in
        for (i, byte) in raw.enumerated() {
            bytes[offset + i] = byte
        }
    }
}

/// 16.16 fixed point, clamped to the 0...1 the device expects.
private func fixed16_16(_ value: Double) -> Int32 {
    Int32((max(0.0, min(1.0, value)) * 65536.0).rounded())
}

/// Build a report of `bitCount` bits with `reportID`, then write `bytes` into
/// it a bit at a time.
///
/// The obvious alternative -- assembling a `Data` and calling
/// `uhidHIDReportInitData` -- does not work here. That entry point stores the
/// `Data` value it is given, and a Swift-native `Data` built from an array has
/// a different internal representation than the one UniversalHID hands back
/// from its own reports: dereferencing the storage at +16 yields the bytes for
/// the latter and null for the former, and CoreDevice's send traps on it
/// (SIGTRAP, exit 133, after the report itself builds fine). Allocating through
/// `uhidHIDReportInit` produces a report owned the same way as every other
/// report this file builds.
///
/// Byte 0 is skipped: `uhidHIDReportInit` has already written the report ID
/// there, which is why the keyboard builder starts its bit offsets at 8.
private func reportFromBytes(_ bytes: [UInt8], bitCount: Int, reportID: UInt8) -> UHIDHIDReport {
    var report = uhidHIDReportInit(bitCount, reportID)
    withUnsafeMutablePointer(to: &report) { pointer in
        for (index, byte) in bytes.enumerated() where index > 0 && byte != 0 {
            for bit in 0..<8 where (byte >> bit) & 1 == 1 {
                uhidHIDReportSetBitABI(pointer, index * 8 + bit, 1)
            }
        }
    }
    return report
}

/// AbsolutePointerReport, ID 19, 19 bytes / 152 bits.
///
///     13 87 35 00 00  10 57 00 00  00 00  57 d9 a5 87 45 01 00 00
///     |  \__________/ \__________/ |  |   \____________________/
///     |   x (16.16)    y (16.16)   |  reserved   remoteTimestamp
///     |                            buttons
///     report ID
///
/// x and y are normalised 0...1, which is the same normalisation `ipb` already
/// uses at the CLI boundary. Confirmed across a slow left-right mouse sweep:
/// x ranged 0.032...0.977 and y 0.168...0.900, never outside 0...1.
func makeAbsolutePointerHIDReport(x: Double, y: Double, buttons: UInt8) -> UHIDHIDReport {
    var bytes = [UInt8](repeating: 0, count: 19)
    bytes[0] = absolutePointerReportID
    putLE(fixed16_16(x), &bytes, 1)
    putLE(fixed16_16(y), &bytes, 5)
    bytes[9] = buttons
    putLE(reportTimestamp(), &bytes, 11)
    return reportFromBytes(bytes, bitCount: 152, reportID: absolutePointerReportID)
}

/// ScrollReport, ID 7, 21 bytes / 168 bits.
///
///     07 02 00 00 fb  f4 fd ff ff  6e da ff ff  52 0c 79 06 46 01 00 00
///     |  |  |  |  |   \__________/ \__________/ \____________________/
///     |  |  |  x  y    accelX       accelY       remoteTimestamp
///     |  |  momentum
///     |  flags (phase)
///     report ID
///
/// x and y are signed byte deltas; accelX/accelY are signed 16.16.
func makeScrollWireHIDReport(
    x: Int8,
    y: Int8,
    flags: UInt8,
    momentum: UInt8,
    accelX: Double,
    accelY: Double
) -> UHIDHIDReport {
    var bytes = [UInt8](repeating: 0, count: 21)
    bytes[0] = uhidScrollReportID()
    bytes[1] = flags
    bytes[2] = momentum
    bytes[3] = UInt8(bitPattern: x)
    bytes[4] = UInt8(bitPattern: y)
    putLE(Int32((accelX * 65536.0).rounded()), &bytes, 5)
    putLE(Int32((accelY * 65536.0).rounded()), &bytes, 9)
    putLE(reportTimestamp(), &bytes, 13)
    return reportFromBytes(bytes, bitCount: scrollReportBitCount, reportID: bytes[0])
}

func makeNavigationSwipeReportData(
    phase: UInt8,
    swipeMask: UInt8,
    gestureMotion: UInt8,
    flavor: UInt8,
    progress: Double,
    x: Double,
    y: Double
) -> Data {
    let hidReport = uhidHIDReportInit(uhidNavigationSwipeReportInitialBitCount(), uhidNavigationSwipeReportID())
    var report = uhidNavigationSwipeReportInitUnderscore(hidReport)
    let metadata = uhidNavigationSwipeReportMetadata(0)
    let witness = navigationSwipeFluidWitness

    withUnsafeMutablePointer(to: &report) { reportPointer in
        let rawReport = UnsafeMutableRawPointer(reportPointer)
        uhidFluidSetPhaseABI(rawReport, metadata, witness, phase)
        uhidFluidSetSwipeMaskABI(rawReport, metadata, witness, UInt32(swipeMask))
        uhidFluidSetGestureMotionABI(rawReport, metadata, witness, UInt16(gestureMotion))
        uhidFluidSetFlavorABI(rawReport, metadata, witness, UInt16(flavor))
        uhidFluidSetProgressABI(rawReport, metadata, witness, progress)
        uhidFluidSetXABI(rawReport, metadata, witness, x)
        uhidFluidSetYABI(rawReport, metadata, witness, y)
    }

    return uhidHIDReportData(uhidNavigationSwipeReportGetReport(report))
}

func makeDockSwipeReportData(
    phase: UInt8,
    swipeMask: UInt8,
    gestureMotion: UInt8,
    flavor: UInt8,
    progress: Double,
    x: Double,
    y: Double
) -> Data {
    let hidReport = uhidHIDReportInit(uhidDockSwipeReportInitialBitCount(), uhidDockSwipeReportID())
    var report = uhidDockSwipeReportInitUnderscore(hidReport)
    let metadata = uhidDockSwipeReportMetadata(0)
    let witness = dockSwipeFluidWitness

    withUnsafeMutablePointer(to: &report) { reportPointer in
        let rawReport = UnsafeMutableRawPointer(reportPointer)
        uhidFluidSetPhaseABI(rawReport, metadata, witness, phase)
        uhidFluidSetSwipeMaskABI(rawReport, metadata, witness, UInt32(swipeMask))
        uhidFluidSetGestureMotionABI(rawReport, metadata, witness, UInt16(gestureMotion))
        uhidFluidSetFlavorABI(rawReport, metadata, witness, UInt16(flavor))
        uhidFluidSetProgressABI(rawReport, metadata, witness, progress)
        uhidFluidSetXABI(rawReport, metadata, witness, x)
        uhidFluidSetYABI(rawReport, metadata, witness, y)
    }

    return uhidHIDReportData(uhidDockSwipeReportGetReport(report))
}

func makeKeyboardHIDReport(usage: UInt32, pressed: Bool) -> UHIDHIDReport? {
    guard usage <= 0xe7 else {
        return nil
    }

    // 312 bits (39 bytes), not the 248 this used to allocate. Decoded from
    // KeyboardReport's own USB-HID report descriptor (Experiments/hid-descriptors,
    // docs/protocol.md "Report descriptors"):
    //
    //     85 01                 report ID 1                            8 bits
    //     05 07 19 01 29 e7     keyboard usages 1..0xE7
    //     96 e8 00 75 01 81 02  count 232, size 1                    232 bits
    //     a1 02 06 1a ff ...    vendor 0xFF1A/0xE0F1 constant byte      8 bits
    //     06 00 ff 0a 02 01
    //     75 08 95 08 81 02     vendor 0xFF00/0x0102, 8 bytes          64 bits
    //                                                          total = 312 bits
    //
    // 248 stopped immediately before that last field, which is remoteTimestamp
    // -- the same bytes 31-38 seen in Device Hub's captured Cmd-L reports, which
    // are 39 bytes on the wire. The timestamp setter no-ops on a report shorter
    // than 39 bytes, so with 248 any future attempt to set it would have
    // silently done nothing. The keyboard usage offset is unaffected: the
    // descriptor puts usages at bit usage+8, which is what is written below.
    var report = uhidHIDReportInit(0x138, 0x01)
    if usage > 0 && pressed {
        uhidHIDReportSetBitABI(&report, Int(usage) + 8, 1)
    }
    return report
}

func makePointerHIDReport(
    x: Int,
    y: Int,
    buttonMask: UInt32,
    accelX: Double,
    accelY: Double,
    flags: UInt32
) -> UHIDHIDReport? {
    let hidReport = uhidHIDReportInit(uhidPointerReportInitialBitCount(), uhidPointerReportID())
    var report = uhidPointerReportInitUnderscore(hidReport)

    uhidPointerReportSetXABI(&report, x)
    uhidPointerReportSetYABI(&report, y)
    uhidPointerReportSetButtonMaskABI(&report, UInt8(truncatingIfNeeded: buttonMask))
    uhidPointerReportSetAccelXABI(&report, accelX)
    uhidPointerReportSetAccelYABI(&report, accelY)
    uhidPointerReportSetFlagsABI(&report, flags)

    return uhidPointerReportGetReport(report)
}

func makeScrollHIDReport(
    x: Int,
    y: Int,
    phase: UInt32,
    momentum: UInt32,
    flags: UInt32,
    accelX: Double,
    accelY: Double
) -> UHIDHIDReport? {
    guard phase <= UInt8.max, momentum <= UInt8.max, flags <= UInt8.max else {
        return nil
    }

    let hidReport = uhidHIDReportInit(scrollReportBitCount, uhidScrollReportID())
    var report = uhidScrollReportInitUnderscore(hidReport)
    var collection = uhidScrollCollectionInit()

    uhidScrollCollectionSetFlagsABI(&collection, UInt8(flags))
    uhidScrollCollectionSetPhaseABI(&collection, UInt8(phase))
    uhidScrollCollectionSetMomentumABI(&collection, UInt8(momentum))
    uhidScrollCollectionSetXABI(&collection, x)
    uhidScrollCollectionSetYABI(&collection, y)
    uhidScrollCollectionSetAccelXABI(&collection, accelX)
    uhidScrollCollectionSetAccelYABI(&collection, accelY)
    uhidScrollReportSetCollectionABI(&report, &collection)

    return uhidScrollReportGetReport(report)
}

@_cdecl("uhid_make_digitizer_report")
public func uhidMakeDigitizerReport(
    _ x: Double,
    _ y: Double,
    _ touching: Int32,
    _ inRange: Int32,
    _ output: UnsafeMutablePointer<UInt8>?,
    _ outputCapacity: Int
) -> Int32 {
    let data = makeDigitizerReportData(x: x, y: y, touching: touching != 0, inRange: inRange != 0)
    guard let output else {
        return Int32(data.count)
    }
    guard outputCapacity >= data.count else {
        return -Int32(data.count)
    }
    data.withUnsafeBytes { bytes in
        if let base = bytes.baseAddress {
            output.initialize(from: base.assumingMemoryBound(to: UInt8.self), count: data.count)
        }
    }
    return Int32(data.count)
}

@_cdecl("uhid_make_digitizer_hid_report")
public func uhidMakeDigitizerHIDReport(
    _ x: Double,
    _ y: Double,
    _ touching: Int32,
    _ inRange: Int32,
    _ output: UnsafeMutableRawPointer?
) -> Int32 {
    let hidReport = uhidHIDReportInit(digitizerReportBitCount, 0x09)
    var report = uhidDigitizerReportInitUnderscore(hidReport)
    var contact = uhidDigitizerContactInit()

    uhidDigitizerContactSetIndexABI(&contact, 0)
    uhidDigitizerContactSetTouchABI(&contact, touching != 0 ? 1 : 0)
    uhidDigitizerContactSetRangeABI(&contact, inRange != 0 ? 1 : 0)
    uhidDigitizerContactSetRestingABI(&contact, 0)
    uhidDigitizerContactSetXABI(&contact, x)
    uhidDigitizerContactSetYABI(&contact, y)

    uhidDigitizerReportSetContactABI(&report, &contact, 0)
    uhidDigitizerReportSetContactCountABI(&report, touching != 0 ? 1 : 0)
    uhidDigitizerReportSetContactCountMaximumABI(&report, 1)

    var finalReport = uhidDigitizerReportGetReport(report)
    retainedHIDReports.append(finalReport)
    if let output {
        withUnsafeBytes(of: &finalReport) { bytes in
            output.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }
    return Int32(MemoryLayout<UHIDHIDReport>.size)
}

@_cdecl("uhid_make_absolute_pointer_hid_report")
public func uhidMakeAbsolutePointerHIDReport(
    _ x: Double,
    _ y: Double,
    _ buttons: UInt32,
    _ output: UnsafeMutableRawPointer?
) -> Int32 {
    var report = makeAbsolutePointerHIDReport(
        x: x,
        y: y,
        buttons: UInt8(truncatingIfNeeded: buttons)
    )
    retainedHIDReports.append(report)
    if let output {
        withUnsafeBytes(of: &report) { bytes in
            output.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }
    return Int32(MemoryLayout<UHIDHIDReport>.size)
}

@_cdecl("uhid_make_scroll_wire_hid_report")
public func uhidMakeScrollWireHIDReport(
    _ x: Int32,
    _ y: Int32,
    _ flags: UInt32,
    _ momentum: UInt32,
    _ accelX: Double,
    _ accelY: Double,
    _ output: UnsafeMutableRawPointer?
) -> Int32 {
    var report = makeScrollWireHIDReport(
        x: Int8(truncatingIfNeeded: x),
        y: Int8(truncatingIfNeeded: y),
        flags: UInt8(truncatingIfNeeded: flags),
        momentum: UInt8(truncatingIfNeeded: momentum),
        accelX: accelX,
        accelY: accelY
    )
    retainedHIDReports.append(report)
    if let output {
        withUnsafeBytes(of: &report) { bytes in
            output.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }
    return Int32(MemoryLayout<UHIDHIDReport>.size)
}

@_cdecl("uhid_make_scroll_hid_report")
public func uhidMakeScrollHIDReport(
    _ x: Int64,
    _ y: Int64,
    _ phase: UInt32,
    _ momentum: UInt32,
    _ flags: UInt32,
    _ accelX: Double,
    _ accelY: Double,
    _ output: UnsafeMutableRawPointer?
) -> Int32 {
    guard var report = makeScrollHIDReport(
        x: Int(x),
        y: Int(y),
        phase: phase,
        momentum: momentum,
        flags: flags,
        accelX: accelX,
        accelY: accelY
    ) else {
        return -1
    }
    retainedHIDReports.append(report)
    if let output {
        withUnsafeBytes(of: &report) { bytes in
            output.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }
    return Int32(MemoryLayout<UHIDHIDReport>.size)
}

@_cdecl("uhid_make_pointer_hid_report")
public func uhidMakePointerHIDReport(
    _ x: Int64,
    _ y: Int64,
    _ buttonMask: UInt32,
    _ accelX: Double,
    _ accelY: Double,
    _ flags: UInt32,
    _ output: UnsafeMutableRawPointer?
) -> Int32 {
    guard var report = makePointerHIDReport(
        x: Int(x),
        y: Int(y),
        buttonMask: buttonMask,
        accelX: accelX,
        accelY: accelY,
        flags: flags
    ) else {
        return -2
    }
    retainedHIDReports.append(report)
    if let output {
        withUnsafeBytes(of: &report) { bytes in
            output.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }
    return Int32(MemoryLayout<UHIDHIDReport>.size)
}

@_cdecl("uhid_make_keyboard_hid_report")
public func uhidMakeKeyboardHIDReport(
    _ usage: UInt32,
    _ pressed: Int32,
    _ output: UnsafeMutableRawPointer?
) -> Int32 {
    guard var report = makeKeyboardHIDReport(usage: usage, pressed: pressed != 0) else {
        return -1
    }
    retainedHIDReports.append(report)
    if let output {
        withUnsafeBytes(of: &report) { bytes in
            output.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }
    return Int32(MemoryLayout<UHIDHIDReport>.size)
}

/// Added for fastinput (not upstream): a keyboard report with `modifier` (a usage 0xE0...0xE7,
/// or 0 for none) held next to `usage`. The report is the whole keyboard state, a bitmap of
/// usages 1...0xE7 (modifiers included), so Shift + a key needs both bits in one report.
@_cdecl("uhid_make_keyboard_chord_hid_report")
public func uhidMakeKeyboardChordHIDReport(
    _ modifier: UInt32,
    _ usage: UInt32,
    _ pressed: Int32,
    _ output: UnsafeMutableRawPointer?
) -> Int32 {
    guard modifier <= 0xe7, var report = makeKeyboardHIDReport(usage: usage, pressed: pressed != 0) else {
        return -1
    }
    if modifier > 0 && pressed != 0 {
        uhidHIDReportSetBitABI(&report, Int(modifier) + 8, 1)
    }
    retainedHIDReports.append(report)
    if let output {
        withUnsafeBytes(of: &report) { bytes in
            output.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }
    return Int32(MemoryLayout<UHIDHIDReport>.size)
}

/// Added for fastinput (not upstream): a keyboard report holding exactly the `count` usages
/// (1...0xE7, modifiers included) in `usages`; none held when `count` is 0.
@_cdecl("uhid_make_keyboard_set_hid_report")
public func uhidMakeKeyboardSetHIDReport(
    _ usages: UnsafePointer<UInt32>?,
    _ count: Int32,
    _ output: UnsafeMutableRawPointer?
) -> Int32 {
    guard var report = makeKeyboardHIDReport(usage: 0, pressed: false) else { return -1 }
    for index in 0..<max(0, Int(count)) {
        guard let usage = usages?[index], usage >= 1, usage <= 0xe7 else { return -1 }
        uhidHIDReportSetBitABI(&report, Int(usage) + 8, 1)
    }
    retainedHIDReports.append(report)
    if let output {
        withUnsafeBytes(of: &report) { bytes in
            output.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }
    return Int32(MemoryLayout<UHIDHIDReport>.size)
}

@_cdecl("uhid_make_digitizer_swipe_hid_report")
public func uhidMakeDigitizerSwipeHIDReport(
    _ x: Double,
    _ y: Double,
    _ touching: Int32,
    _ inRange: Int32,
    _ swipePending: Int32,
    _ swipeLocked: Int32,
    _ swipeUp: Int32,
    _ output: UnsafeMutableRawPointer?
) -> Int32 {
    let hidReport = uhidHIDReportInit(digitizerReportBitCount, 0x09)
    var report = uhidDigitizerReportInitUnderscore(hidReport)
    var contact = uhidDigitizerContactInit()

    uhidDigitizerContactSetIndexABI(&contact, 0)
    uhidDigitizerContactSetTouchABI(&contact, touching != 0 ? 1 : 0)
    uhidDigitizerContactSetRangeABI(&contact, inRange != 0 ? 1 : 0)
    uhidDigitizerContactSetRestingABI(&contact, 0)
    uhidDigitizerContactSetXABI(&contact, x)
    uhidDigitizerContactSetYABI(&contact, y)

    uhidDigitizerReportSetContactABI(&report, &contact, 0)
    uhidDigitizerReportSetContactSwipePendingABI(&report, swipePending != 0 ? 1 : 0, 0)
    uhidDigitizerReportSetContactSwipeLockedABI(&report, swipeLocked != 0 ? 1 : 0, 0)
    uhidDigitizerReportSetContactSwipeUpABI(&report, swipeUp != 0 ? 1 : 0, 0)
    uhidDigitizerReportSetContactCountABI(&report, touching != 0 ? 1 : 0)
    uhidDigitizerReportSetContactCountMaximumABI(&report, 1)

    var finalReport = uhidDigitizerReportGetReport(report)
    retainedHIDReports.append(finalReport)
    if let output {
        withUnsafeBytes(of: &finalReport) { bytes in
            output.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }
    return Int32(MemoryLayout<UHIDHIDReport>.size)
}

@_cdecl("uhid_make_navigation_swipe_hid_report")
public func uhidMakeNavigationSwipeHIDReport(
    _ phase: UInt32,
    _ swipeMask: UInt32,
    _ gestureMotion: UInt32,
    _ flavor: UInt32,
    _ progress: Double,
    _ x: Double,
    _ y: Double,
    _ output: UnsafeMutableRawPointer?
) -> Int32 {
    let data = makeNavigationSwipeReportData(
        phase: UInt8(truncatingIfNeeded: phase),
        swipeMask: UInt8(truncatingIfNeeded: swipeMask),
        gestureMotion: UInt8(truncatingIfNeeded: gestureMotion),
        flavor: UInt8(truncatingIfNeeded: flavor),
        progress: progress,
        x: x,
        y: y
    )
    var report = uhidHIDReportInitData(data)
    retainedHIDReports.append(report)
    if let output {
        withUnsafeBytes(of: &report) { bytes in
            output.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }
    return Int32(MemoryLayout<UHIDHIDReport>.size)
}

@_cdecl("uhid_make_dock_swipe_hid_report")
public func uhidMakeDockSwipeHIDReport(
    _ phase: UInt32,
    _ swipeMask: UInt32,
    _ gestureMotion: UInt32,
    _ flavor: UInt32,
    _ progress: Double,
    _ x: Double,
    _ y: Double,
    _ output: UnsafeMutableRawPointer?
) -> Int32 {
    let data = makeDockSwipeReportData(
        phase: UInt8(truncatingIfNeeded: phase),
        swipeMask: UInt8(truncatingIfNeeded: swipeMask),
        gestureMotion: UInt8(truncatingIfNeeded: gestureMotion),
        flavor: UInt8(truncatingIfNeeded: flavor),
        progress: progress,
        x: x,
        y: y
    )
    var report = uhidHIDReportInitData(data)
    retainedHIDReports.append(report)
    if let output {
        withUnsafeBytes(of: &report) { bytes in
            output.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }
    return Int32(MemoryLayout<UHIDHIDReport>.size)
}
