import Foundation
import XPC
import Darwin
import ObjectiveC

struct MercuryXPCDictionary {
    var word0: UInt = 0
    var word1: UInt = 0
    var word2: UInt = 0
    var word3: UInt = 0
    var word4: UInt = 0
    var word5: UInt = 0
    var word6: UInt = 0
    var word7: UInt = 0
}

struct UHIDRequestWords {
    var word0: UInt64 = 0
    var word1: UInt64 = 0
    var word2: UInt64 = 0
    var word3: UInt64 = 0
}

struct CoreDeviceHIDServiceIDWords {
    var id: UInt64 = 0
}

final class AsyncProbeState: @unchecked Sendable {
    var result: Int32 = 2
}

var retainedCoreDeviceStrings: [String] = []
var retainedCoreDeviceData: [Data] = []

@_silgen_name("$s7Mercury19RemoteXPCConnectionC10unsafePeer4fromAA17XPCPeerConnection_pSo24OS_xpc_remote_connectionC_tFZ")
func mercuryUnsafePeer(_ connection: UnsafeMutableRawPointer?) -> AnyObject

@_silgen_name("$s7Mercury19RemoteXPCConnectionC10unsafePeer4from15forServiceNamedAA17XPCPeerConnection_pSo24OS_xpc_remote_connectionC_SStFZ")
func mercuryUnsafePeerForService(_ connection: UnsafeMutableRawPointer?, _ serviceName: String) -> AnyObject

@_silgen_name("$s7Mercury13XPCDictionaryVyACSo13OS_xpc_object_pcfC")
func mercuryXPCDictionary(_ object: xpc_object_t) -> MercuryXPCDictionary

@_silgen_name("$s7Mercury13XPCDictionaryV16debugDescriptionSSvg")
func mercuryXPCDictionaryDebugDescription(_ dictionary: MercuryXPCDictionary) -> String

@_silgen_name("mercury_xpc_connection_send_abi")
func mercuryXPCConnectionSendABI(_ connection: UnsafeMutableRawPointer, _ message: UnsafeRawPointer)

@_silgen_name("mercury_xpc_connection_send_sync_abi")
func mercuryXPCConnectionSendSyncABI(_ connection: UnsafeMutableRawPointer, _ message: UnsafeRawPointer, _ reply: UnsafeMutableRawPointer)

@_silgen_name("mercury_xpc_connection_send_value_abi")
func mercuryXPCConnectionSendValueABI(
    _ connection: UnsafeMutableRawPointer,
    _ value: UnsafeRawPointer,
    _ metadata: UnsafeRawPointer,
    _ decodableWitness: UnsafeRawPointer,
    _ encodableWitness: UnsafeRawPointer
) -> UnsafeRawPointer?

@_silgen_name("mercury_xpc_connection_send_sync_value_abi")
func mercuryXPCConnectionSendSyncValueABI(
    _ connection: UnsafeMutableRawPointer,
    _ value: UnsafeRawPointer,
    _ requestMetadata: UnsafeRawPointer,
    _ requestDecodableWitness: UnsafeRawPointer,
    _ requestEncodableWitness: UnsafeRawPointer,
    _ replyMetadata: UnsafeRawPointer,
    _ replyDecodableWitness: UnsafeRawPointer,
    _ replyEncodableWitness: UnsafeRawPointer,
    _ reply: UnsafeMutableRawPointer
) -> Int32

@_silgen_name("$s7Mercury13XPCDictionaryV14toNSDictionarySo0D0CSgyF")
func mercuryXPCDictionaryToNSDictionary(_ dictionary: MercuryXPCDictionary) -> NSDictionary?

@_silgen_name("uhid_request_description_abi")
func uhidRequestDescriptionABI(_ request: UnsafeRawPointer) -> String

@_silgen_name("uhid_connected_services_description_abi")
func uhidConnectedServicesDescriptionABI(_ connectedServices: UnsafeRawPointer) -> String

@_silgen_name("hid_service_id_main_touchscreen_abi")
func hidServiceIDMainTouchscreenABI(_ output: UnsafeMutablePointer<CoreDeviceHIDServiceIDWords>)

@_silgen_name("hid_service_id_touchscreen_abi")
func hidServiceIDTouchscreenABI(_ output: UnsafeMutablePointer<CoreDeviceHIDServiceIDWords>, _ displayID: UInt32)

@_silgen_name("hid_service_id_main_keyboard_abi")
func hidServiceIDMainKeyboardABI(_ output: UnsafeMutablePointer<CoreDeviceHIDServiceIDWords>)

@_silgen_name("hid_service_id_keyboard_abi")
func hidServiceIDKeyboardABI(_ output: UnsafeMutablePointer<CoreDeviceHIDServiceIDWords>, _ identifier: UInt64)

@_silgen_name("hid_service_id_main_pointer_abi")
func hidServiceIDMainPointerABI(_ output: UnsafeMutablePointer<CoreDeviceHIDServiceIDWords>)

@_silgen_name("hid_service_id_pointer_abi")
func hidServiceIDPointerABI(_ output: UnsafeMutablePointer<CoreDeviceHIDServiceIDWords>, _ identifier: UInt64)

@_silgen_name("hid_service_id_main_screen_buttons_abi")
func hidServiceIDMainScreenButtonsABI(_ output: UnsafeMutablePointer<CoreDeviceHIDServiceIDWords>)

@_silgen_name("hid_service_id_touchscreen_gesture_abi")
func hidServiceIDTouchscreenGestureABI(_ output: UnsafeMutablePointer<CoreDeviceHIDServiceIDWords>)

@_silgen_name("hid_service_id_digital_crown_abi")
func hidServiceIDDigitalCrownABI(_ output: UnsafeMutablePointer<CoreDeviceHIDServiceIDWords>)

@_silgen_name("hid_service_id_dial_abi")
func hidServiceIDDialABI(_ output: UnsafeMutablePointer<CoreDeviceHIDServiceIDWords>)

@_silgen_name("hid_service_id_avp_custom_abi")
func hidServiceIDAVPCustomABI(_ output: UnsafeMutablePointer<CoreDeviceHIDServiceIDWords>)

@_silgen_name("hid_service_id_user_defined_base_abi")
func hidServiceIDUserDefinedBaseABI() -> UInt64

@_silgen_name("coredevice_connected_descriptors_async_abi")
func coredeviceConnectedServiceDescriptorsAsyncABI(
    _ resultBuffer: UnsafeMutableRawPointer,
    _ service: UnsafeMutableRawPointer,
    _ witness: UnsafeRawPointer
) async throws -> UnsafeRawPointer

@_silgen_name("coredevice_universalhid_send_dispatch_abi")
func coredeviceUniversalHIDSendDispatchABI(
    _ service: UnsafeMutableRawPointer,
    _ witness: UnsafeRawPointer,
    _ report: UnsafeRawPointer,
    _ serviceID: UInt64
) -> Int32

@_silgen_name("coredevice_universalhid_reset_dispatch_abi")
func coredeviceUniversalHIDResetDispatchABI(
    _ service: UnsafeMutableRawPointer,
    _ witness: UnsafeRawPointer,
    _ serviceID: UInt64
) -> Int32

@_silgen_name("coredevice_universalhid_barrier_dispatch_abi")
func coredeviceUniversalHIDBarrierDispatchABI(
    _ service: UnsafeMutableRawPointer,
    _ witness: UnsafeRawPointer
) -> Int32

@_silgen_name("coredevice_hidbutton_custom_dispatch_abi")
func coredeviceHIDButtonCustomDispatchABI(
    _ button: UnsafeMutableRawPointer,
    _ witness: UnsafeRawPointer,
    _ usagePage: UInt64,
    _ usageCode: UInt64,
    _ state: UInt8
) -> Int32

@_silgen_name("coredevice_hidbutton_barrier_dispatch_abi")
func coredeviceHIDButtonBarrierDispatchABI(
    _ button: UnsafeMutableRawPointer,
    _ witness: UnsafeRawPointer
) -> Int32

@_silgen_name("coredevice_hidscroll_dispatch_abi")
func coredeviceHIDScrollDispatchABI(
    _ scroll: UnsafeMutableRawPointer,
    _ witness: UnsafeRawPointer,
    _ x: Double,
    _ y: Double,
    _ z: Double,
    _ phase: UInt16,
    _ momentum: UInt8,
    _ target: UInt8
) -> Int32

@_silgen_name("coredevice_hidscroll_barrier_dispatch_abi")
func coredeviceHIDScrollBarrierDispatchABI(
    _ scroll: UnsafeMutableRawPointer,
    _ witness: UnsafeRawPointer
) -> Int32

@_silgen_name("coredevice_hidvendor_dispatch_abi")
func coredeviceHIDVendorDefinedDispatchABI(
    _ vendorDefined: UnsafeMutableRawPointer,
    _ witness: UnsafeRawPointer,
    _ usagePage: UInt16,
    _ usage: UInt16,
    _ version: UInt32,
    _ data: UnsafeRawPointer
) -> Int32

@_silgen_name("coredevice_hidvendor_barrier_dispatch_abi")
func coredeviceHIDVendorDefinedBarrierDispatchABI(
    _ vendorDefined: UnsafeMutableRawPointer,
    _ witness: UnsafeRawPointer
) -> Int32

@_silgen_name("coredevice_hiddigitizer_cgpoint_dispatch_abi")
func coredeviceHIDDigitizerCGPointDispatchABI(
    _ digitizer: UnsafeMutableRawPointer,
    _ witness: UnsafeRawPointer,
    _ pointOneX: Double,
    _ pointOneY: Double,
    _ pointTwoX: Double,
    _ pointTwoY: Double,
    _ pointTwoOptionalTag: UInt64,
    _ eventType: UInt64,
    _ edge: UInt64,
    _ targetLow: UInt64,
    _ targetHigh: UInt64
) -> Int32

typealias SwiftMetadataAccessor = @convention(c) () -> UnsafeRawPointer
typealias SwiftConformsToProtocol = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeRawPointer?

struct ValueWitnessLayout {
    let table: UnsafeRawPointer
    let size: UInt
    let stride: UInt
    let flags: UInt32
    let extraInhabitantCount: UInt32
}

func dlsymRequired<T>(_ symbol: String, as type: T.Type) -> T {
    guard let pointer = dlsym(dlopen(nil, RTLD_NOW), symbol) else {
        fatalError("missing symbol \(symbol)")
    }
    return unsafeBitCast(pointer, to: type)
}

func metadataAndCodableWitnesses(_ metadataSymbol: String, label: String) -> (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer) {
    let metadataAccessor = dlsymRequired(
        metadataSymbol,
        as: SwiftMetadataAccessor.self
    )
    let conforms = dlsymRequired("swift_conformsToProtocol", as: SwiftConformsToProtocol.self)
    guard let decodableProtocol = dlsym(dlopen(nil, RTLD_NOW), "$sSeMp") else {
        fatalError("missing Swift.Decodable protocol descriptor")
    }
    guard let encodableProtocol = dlsym(dlopen(nil, RTLD_NOW), "$sSEMp") else {
        fatalError("missing Swift.Encodable protocol descriptor")
    }
    let metadata = metadataAccessor()
    guard let decodableWitness = conforms(metadata, decodableProtocol) else {
        fatalError("\(label) does not conform to Decodable")
    }
    guard let witness = conforms(metadata, encodableProtocol) else {
        fatalError("\(label) does not conform to Encodable")
    }
    return (metadata, decodableWitness, witness)
}

func uhidRequestMetadataAndCodableWitnesses() -> (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer) {
    metadataAndCodableWitnesses(
        "$s19CoreDeviceUtilities29DDIUniversalHIDServicePayloadO7RequestOMa",
        label: "DDIUniversalHIDServicePayload.Request"
    )
}

func uhidConnectedServicesMetadataAndCodableWitnesses() -> (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer) {
    metadataAndCodableWitnesses(
        "$s19CoreDeviceUtilities29DDIUniversalHIDServicePayloadO17ConnectedServicesVMa",
        label: "DDIUniversalHIDServicePayload.ConnectedServices"
    )
}

func hidServiceDescriptorMetadata() -> UnsafeRawPointer {
    let metadataAccessor = dlsymRequired(
        "$s10CoreDevice20HIDServiceDescriptorVMa",
        as: SwiftMetadataAccessor.self
    )
    return metadataAccessor()
}

func optionalMetadata(_ metadataSymbol: String) -> UnsafeRawPointer? {
    guard let symbol = dlsym(dlopen(nil, RTLD_NOW), metadataSymbol) else {
        return nil
    }
    let metadataAccessor = unsafeBitCast(symbol, to: SwiftMetadataAccessor.self)
    return metadataAccessor()
}

func valueWitnessLayout(for metadata: UnsafeRawPointer) -> ValueWitnessLayout {
    let table = metadata.load(fromByteOffset: -MemoryLayout<UInt>.stride, as: UnsafeRawPointer.self)
    return ValueWitnessLayout(
        table: table,
        size: table.load(fromByteOffset: 64, as: UInt.self),
        stride: table.load(fromByteOffset: 72, as: UInt.self),
        flags: table.load(fromByteOffset: 80, as: UInt32.self),
        extraInhabitantCount: table.load(fromByteOffset: 84, as: UInt32.self)
    )
}

func decodeSmallSwiftString(_ pointer: UnsafeRawPointer) -> String? {
    let word0 = pointer.load(as: UInt64.self)
    let word1 = pointer.load(fromByteOffset: MemoryLayout<UInt64>.stride, as: UInt64.self)
    let marker = UInt8(truncatingIfNeeded: word1 >> 56)
    guard marker >= 0xe0 && marker <= 0xef else {
        return nil
    }
    let length = Int(marker - 0xe0)
    guard length <= 15 else {
        return nil
    }

    var bytes: [UInt8] = []
    for index in 0..<8 {
        bytes.append(UInt8(truncatingIfNeeded: word0 >> UInt64(index * 8)))
    }
    for index in 0..<7 {
        bytes.append(UInt8(truncatingIfNeeded: word1 >> UInt64(index * 8)))
    }
    let payload = Array(bytes.prefix(length))
    guard payload.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else {
        return nil
    }
    return String(bytes: payload, encoding: .utf8)
}

func decodeSwiftString(_ pointer: UnsafeRawPointer) -> String? {
    if let small = decodeSmallSwiftString(pointer) {
        return small
    }

    let word0 = pointer.load(as: UInt64.self)
    let word1 = pointer.load(fromByteOffset: MemoryLayout<UInt64>.stride, as: UInt64.self)
    guard (word0 >> 60) == 0xf else {
        return nil
    }
    let length = Int(word0 & 0x0fff_ffff_ffff_ffff)
    guard length > 0 && length <= 4096 else {
        return nil
    }

    let storageAddress = word1 & 0x0fff_ffff_ffff_ffff
    guard let storage = UnsafeRawPointer(bitPattern: UInt(storageAddress)), storageAddress != 0 else {
        return nil
    }

    let bytes = UnsafeRawBufferPointer(start: storage.advanced(by: 32), count: length)
    guard bytes.allSatisfy({ $0 == 0x09 || $0 == 0x0a || ($0 >= 0x20 && $0 < 0x7f) }) else {
        return nil
    }
    return String(decoding: bytes, as: UTF8.self)
}

func swiftStringBitsSummary(_ pointer: UnsafeRawPointer) -> String {
    let word0 = pointer.load(as: UInt64.self)
    let word1 = pointer.load(fromByteOffset: MemoryLayout<UInt64>.stride, as: UInt64.self)
    if let string = decodeSwiftString(pointer) {
        return "\"\(string)\""
    }

    var parts = [String(format: "stringWords=%016llx,%016llx", word0, word1)]
    let storageAddress = word1 & 0x0fff_ffff_ffff_ffff
    if let storage = UnsafeRawPointer(bitPattern: UInt(storageAddress)), storageAddress != 0 {
        var words: [String] = []
        for wordIndex in 0..<6 {
            let word = storage.load(fromByteOffset: wordIndex * MemoryLayout<UInt64>.stride, as: UInt64.self)
            words.append(String(format: "%016llx", word))
        }
        parts.append("stringStorage=\(words.joined(separator: ","))")
    }
    return parts.joined(separator: " ")
}

func codableValueSummary(_ raw: UInt64) -> String {
    let tag = raw >> 60
    let payloadAddress = raw & 0x0fff_ffff_ffff_ffff
    guard let payload = UnsafeRawPointer(bitPattern: UInt(payloadAddress)), payloadAddress != 0 else {
        return String(format: "tag=%llx payload=<null>", tag)
    }

    switch tag {
    case 0x0:
        let arrayAddress = payload.load(fromByteOffset: 16, as: UInt64.self)
        guard let arrayStorage = UnsafeRawPointer(bitPattern: UInt(arrayAddress)), arrayAddress != 0 else {
            return "array:<null>"
        }
        let count = arrayStorage.load(fromByteOffset: 16, as: UInt64.self)
        var elementWords: [String] = []
        if count <= 32 {
            for elementIndex in 0..<Int(count) {
                let element = arrayStorage.load(fromByteOffset: 32 + elementIndex * MemoryLayout<UInt64>.stride, as: UInt64.self)
                elementWords.append(codableValueSummary(element))
            }
        }
        return "array:[\(elementWords.joined(separator: ", "))]"
    case 0x5:
        let pairAddress = payload.load(fromByteOffset: 16, as: UInt64.self)
        guard let pair = UnsafeRawPointer(bitPattern: UInt(pairAddress)), pairAddress != 0 else {
            return "dictionary:<null>"
        }
        return "dictionary:\(codableDictionarySummary(pair))"
    case 0x1:
        let value = payload.load(fromByteOffset: 16, as: UInt64.self)
        return "bool:\(value != 0)"
    case 0x8:
        // CodableValue.int (signed)
        let value = payload.load(fromByteOffset: 16, as: Int64.self)
        return "int:\(value)"
    case 0x9:
        // CodableValue.uint; HIDServiceID raw values arrive here under the _ServiceID key
        let value = payload.load(fromByteOffset: 16, as: UInt64.self)
        return "uint:\(value)"
    case 0xa:
        return "string:\(swiftStringBitsSummary(payload.advanced(by: 16)))"
    default:
        var words: [String] = []
        for wordIndex in 0..<4 {
            let word = payload.load(fromByteOffset: wordIndex * MemoryLayout<UInt64>.stride, as: UInt64.self)
            words.append(String(format: "%016llx", word))
        }
        return String(format: "tag=%llx payload=%016llx payloadWords=%@", tag, payloadAddress, words.joined(separator: ","))
    }
}

func codableDictionarySummary(_ storage: UnsafeRawPointer) -> String {
    let fields = codableDictionaryFields(storage)
    if fields.isEmpty {
        let storageHeader = storage.bindMemory(to: UInt.self, capacity: 8)
        let fieldCount = storageHeader[2]
        let scale = Int(storageHeader[4] & 0xff)
        let bucketCount = scale < 20 ? 1 << scale : 0
        return String(format: "{count:%llu buckets:%d}", UInt64(fieldCount), bucketCount)
    }
    return "{\(fields.map { "\($0.0):\($0.1)" }.joined(separator: ", "))}"
}

func codableDictionaryFields(_ storage: UnsafeRawPointer) -> [(String, String)] {
    let storageHeader = storage.bindMemory(to: UInt.self, capacity: 8)
    let fieldCount = storageHeader[2]
    let scale = Int(storageHeader[4] & 0xff)
    let bucketCount = scale < 20 ? 1 << scale : 0
    let keysAddress = storageHeader[6]
    let valuesAddress = storageHeader[7]

    guard fieldCount <= 128,
          bucketCount > 0,
          bucketCount <= 256,
          let keys = UnsafeRawPointer(bitPattern: keysAddress),
          let values = UnsafeRawPointer(bitPattern: valuesAddress) else {
        return []
    }

    var pairs: [(String, String)] = []
    for bucket in 0..<bucketCount {
        let keyPointer = keys.advanced(by: bucket * 16)
        guard let key = decodeSwiftString(keyPointer) else {
            continue
        }
        let rawValue = values.advanced(by: bucket * MemoryLayout<UInt64>.stride).load(as: UInt64.self)
        pairs.append((key, codableValueSummary(rawValue)))
    }
    return pairs
}

func orderedDescriptorFields(_ fields: [(String, String)]) -> [(String, String)] {
    let priority = [
        "_ServiceID",
        "Product",
        "Transport",
        "PrimaryUsagePage",
        "PrimaryUsage",
        "DeviceUsagePairs",
        "DeviceTypeHint",
        "Built-In",
        "Authenticated",
        "DisplayIntegrated",
        "UniversalControlVirtualService",
        "_CoreDevice_originalUsages",
        "_CoreDevice_suppressMousePointer",
        "RouteEventsIgnoringSystemShellPolicy",
    ]
    var result: [(String, String)] = []
    var seen = Set<String>()
    for key in priority {
        for field in fields where field.0 == key {
            result.append(field)
            seen.insert(field.0)
        }
    }
    let remaining = fields
        .filter { !seen.contains($0.0) }
        .sorted { $0.0 < $1.0 }
    result.append(contentsOf: remaining)
    return result
}

func printHIDServiceID(_ name: String, _ serviceID: CoreDeviceHIDServiceIDWords) {
    let paddedName = name.padding(toLength: 28, withPad: " ", startingAt: 0)
    print("\(paddedName) 0x\(String(serviceID.id, radix: 16)) (\(serviceID.id))")
}

func hidServiceID(_ fill: (UnsafeMutablePointer<CoreDeviceHIDServiceIDWords>) -> Void) -> CoreDeviceHIDServiceIDWords {
    var serviceID = CoreDeviceHIDServiceIDWords()
    fill(&serviceID)
    return serviceID
}

func hidServiceID(_ value: UInt64, _ fill: (UnsafeMutablePointer<CoreDeviceHIDServiceIDWords>, UInt64) -> Void) -> CoreDeviceHIDServiceIDWords {
    var serviceID = CoreDeviceHIDServiceIDWords()
    fill(&serviceID, value)
    return serviceID
}

func hidServiceID(_ value: UInt32, _ fill: (UnsafeMutablePointer<CoreDeviceHIDServiceIDWords>, UInt32) -> Void) -> CoreDeviceHIDServiceIDWords {
    var serviceID = CoreDeviceHIDServiceIDWords()
    fill(&serviceID, value)
    return serviceID
}

@_cdecl("coredevice_print_hid_service_ids")
public func coredevicePrintHIDServiceIDs() -> Int32 {
    printHIDServiceID("mainTouchscreen", hidServiceID(hidServiceIDMainTouchscreenABI))
    printHIDServiceID("touchscreen(displayID:1)", hidServiceID(1, hidServiceIDTouchscreenABI))
    printHIDServiceID("touchscreen(displayID:2)", hidServiceID(2, hidServiceIDTouchscreenABI))
    printHIDServiceID("touchscreenGesture", hidServiceID(hidServiceIDTouchscreenGestureABI))
    printHIDServiceID("mainKeyboard", hidServiceID(hidServiceIDMainKeyboardABI))
    printHIDServiceID("keyboard(identifier:1)", hidServiceID(1, hidServiceIDKeyboardABI))
    printHIDServiceID("mainPointer", hidServiceID(hidServiceIDMainPointerABI))
    printHIDServiceID("pointer(identifier:1)", hidServiceID(1, hidServiceIDPointerABI))
    printHIDServiceID("mainScreenButtons", hidServiceID(hidServiceIDMainScreenButtonsABI))
    printHIDServiceID("digitalCrown", hidServiceID(hidServiceIDDigitalCrownABI))
    printHIDServiceID("dial", hidServiceID(hidServiceIDDialABI))
    printHIDServiceID("avpCustom", hidServiceID(hidServiceIDAVPCustomABI))
    let userDefinedBase = hidServiceIDUserDefinedBaseABI()
    let paddedName = "userDefinedBase".padding(toLength: 28, withPad: " ", startingAt: 0)
    print("\(paddedName) 0x\(String(userDefinedBase, radix: 16)) (\(userDefinedBase))")
    return 0
}

func makeUHIDSendRequest(data: Data, serviceID: UInt64) -> UHIDRequestWords {
    var request = UHIDRequestWords()
    withUnsafeMutableBytes(of: &request) { requestBytes in
        for index in requestBytes.indices {
            requestBytes[index] = 0
        }
        withUnsafeBytes(of: data) { dataBytes in
            requestBytes.copyBytes(from: dataBytes.prefix(16))
        }
        requestBytes.storeBytes(of: serviceID, toByteOffset: 16, as: UInt64.self)
        let dataWord1 = requestBytes.load(fromByteOffset: 8, as: UInt64.self)
        requestBytes.storeBytes(of: dataWord1 | 0x2000_0000_0000_0000, toByteOffset: 8, as: UInt64.self)
        requestBytes[24] = 0
    }
    return request
}

func makeUHIDConnectedServicesRequest() -> UHIDRequestWords {
    var request = UHIDRequestWords()
    withUnsafeMutableBytes(of: &request) { requestBytes in
        for index in requestBytes.indices {
            requestBytes[index] = 0
        }
        requestBytes[24] = 4
    }
    return request
}

func swiftProtocolWitness(for classObject: AnyClass, protocolSymbol: String) -> UnsafeRawPointer {
    let conforms = dlsymRequired("swift_conformsToProtocol", as: SwiftConformsToProtocol.self)
    guard let proto = dlsym(dlopen(nil, RTLD_NOW), protocolSymbol) else {
        fatalError("missing protocol descriptor \(protocolSymbol)")
    }
    let metadata = unsafeBitCast(classObject, to: UnsafeRawPointer.self)
    guard let witness = conforms(metadata, proto) else {
        fatalError("\(classObject) does not conform to \(protocolSymbol)")
    }
    return witness
}

func dumpWitnessTable(_ label: String, _ witness: UnsafeRawPointer, slots: Int = 12) {
    fputs("\(label) witness=\(witness)\n", stderr)
    for index in 0..<slots {
        let value = witness.load(fromByteOffset: index * MemoryLayout<UInt>.stride, as: UInt.self)
        fputs(String(format: "  [%02d] 0x%016llx\n", index, UInt64(value)), stderr)
    }
}

func dumpRawDescriptorArray(_ raw: UnsafeRawPointer) {
    let verbose = ProcessInfo.processInfo.environment["HIDCTL_VERBOSE_DESCRIPTORS"] != nil
    let storageAddress = UInt(bitPattern: raw)
    guard storageAddress != 0 else {
        print("connected descriptors async raw array=<null>")
        return
    }

    let header = raw.bindMemory(to: UInt.self, capacity: 4)
    let metadata = header[0]
    let refcount = header[1]
    let count = header[2]
    let capacityAndFlags = header[3]
    print("connected descriptors count=\(count)")
    if verbose {
        print(String(format: "connected descriptors async raw array=%016llx metadata=%016llx refcount=%016llx count=%llu capacityAndFlags=%016llx",
                     UInt64(storageAddress),
                     UInt64(metadata),
                     UInt64(refcount),
                     UInt64(count),
                     UInt64(capacityAndFlags)))
    }

    guard count > 0 else {
        print("connected descriptors: <empty>")
        return
    }
    guard count <= 1024 else {
        print("connected descriptors: refusing to decode suspicious count \(count)")
        return
    }

    let descriptorMetadata = hidServiceDescriptorMetadata()
    let valueWitness = valueWitnessLayout(for: descriptorMetadata)
    if verbose {
        print(String(format: "HIDServiceDescriptor metadata=%016llx valueWitness=%016llx size=%llu stride=%llu flags=%08x extraInhabitantCount=%u",
                     UInt64(UInt(bitPattern: descriptorMetadata)),
                     UInt64(UInt(bitPattern: valueWitness.table)),
                     UInt64(valueWitness.size),
                     UInt64(valueWitness.stride),
                     valueWitness.flags,
                     valueWitness.extraInhabitantCount))
    }

    let stride = Int(valueWitness.stride)
    guard stride > 0 && stride <= 4096 else {
        print("connected descriptors: refusing to decode suspicious descriptor stride \(stride)")
        return
    }

    let elements = raw.advanced(by: 32)
    for index in 0..<Int(count) {
        let element = elements.advanced(by: index * stride)
        let wordCount = min(stride / MemoryLayout<UInt64>.stride, 12)
        var words: [String] = []
        for wordIndex in 0..<wordCount {
            let word = element.load(fromByteOffset: wordIndex * MemoryLayout<UInt64>.stride, as: UInt64.self)
            words.append(String(format: "%016llx", word))
        }
        if verbose {
            print("connectedDescriptor[\(index)] rawWords=\(words.joined(separator: " "))")
        }

        let storageWord = element.load(as: UInt.self)
        if let storage = UnsafeRawPointer(bitPattern: storageWord) {
            let storageHeader = storage.bindMemory(to: UInt.self, capacity: 8)
            let fieldCount = storageHeader[2]
            let capacity = storageHeader[3]
            let scaleWord = storageHeader[4]
            let scale = Int(scaleWord & 0xff)
            let bucketCount = scale < 20 ? 1 << scale : 0
            let keysAddress = storageHeader[6]
            let valuesAddress = storageHeader[7]
            if verbose {
                print(String(format: "connectedDescriptor[%d] storage count=%llu capacity=%llu scale=%d buckets=%d keys=%016llx values=%016llx",
                             index,
                             UInt64(fieldCount),
                             UInt64(capacity),
                             scale,
                             bucketCount,
                             UInt64(keysAddress),
                             UInt64(valuesAddress)))
            }

            guard bucketCount > 0,
                  bucketCount <= 256,
                  UnsafeRawPointer(bitPattern: keysAddress) != nil,
                  UnsafeRawPointer(bitPattern: valuesAddress) != nil else {
                continue
            }

            if verbose, let codableValueMetadata = optionalMetadata("$s10CoreDevice12CodableValueOMa") {
                let codableValueWitness = valueWitnessLayout(for: codableValueMetadata)
                print(String(format: "CodableValue metadata=%016llx valueWitness=%016llx size=%llu stride=%llu flags=%08x",
                             UInt64(UInt(bitPattern: codableValueMetadata)),
                             UInt64(UInt(bitPattern: codableValueWitness.table)),
                             UInt64(codableValueWitness.size),
                             UInt64(codableValueWitness.stride),
                             codableValueWitness.flags))
            }

            let fields = orderedDescriptorFields(codableDictionaryFields(storage))
            var fieldMap: [String: String] = [:]
            for field in fields {
                fieldMap[field.0] = field.1
            }
            let serviceID = fieldMap["_ServiceID"].flatMap(serviceIDLabel) ?? "serviceID:<unknown>"
            let product = fieldMap["Product"] ?? "string:\"<unknown>\""
            print("connectedDescriptor[\(index)] \(serviceID) \(product)")
            for (key, value) in fields {
                print("  \(key)=\(value)")
            }
        }
    }
}

/// Turn a decoded `_ServiceID` field ("uint:257" or "int:257") into the `serviceID:0x101` form the wrapper parses.
func serviceIDLabel(_ summary: String) -> String? {
    let parts = summary.split(separator: ":", maxSplits: 1)
    guard parts.count == 2, parts[0] == "uint" || parts[0] == "int", let value = UInt64(parts[1]) else {
        return nil
    }
    return String(format: "serviceID:0x%llx", value)
}

func storePointer(_ base: UnsafeMutableRawPointer, offset: Int, _ value: UnsafeRawPointer?) {
    base.advanced(by: offset).storeBytes(of: UInt(bitPattern: value), as: UInt.self)
}

func storeString(_ base: UnsafeMutableRawPointer, offset: Int, _ value: inout String) {
    withUnsafeBytes(of: &value) { bytes in
        base.advanced(by: offset).copyMemory(from: bytes.baseAddress!, byteCount: min(bytes.count, 16))
    }
}

func makeDDIUniversalHIDService(_ connection: UnsafeMutableRawPointer?) -> (UnsafeMutableRawPointer, UnsafeRawPointer) {
    let serviceName = ProcessInfo.processInfo.environment["HIDCTL_MERCURY_SERVICE"] ?? "com.apple.coredevice.hid.universalhidservice"
    let featureIdentifier = ProcessInfo.processInfo.environment["HIDCTL_FEATURE_ID"] ?? "com.apple.coredevice.feature.remote.universalhidservice"

    let peer = mercuryUnsafePeerForService(connection, serviceName)
    guard let peerClass = object_getClass(peer) else {
        fatalError("unable to get Mercury peer class")
    }
    let peerWitness = swiftProtocolWitness(
        for: peerClass,
        protocolSymbol: "$s7Mercury17XPCPeerConnectionMp"
    )

    guard let hidxpcClass = objc_getClass("_TtC10CoreDevice13HIDXPCService") as? AnyClass else {
        fatalError("missing CoreDevice.HIDXPCService class")
    }
    guard let ddiClass = objc_getClass("_TtC10CoreDevice22DDIUniversalHIDService") as? AnyClass else {
        fatalError("missing CoreDevice.DDIUniversalHIDService class")
    }

    guard let hidxpcObject = class_createInstance(hidxpcClass, 0) else {
        fatalError("unable to create HIDXPCService")
    }
    guard let ddiObject = class_createInstance(ddiClass, 0) else {
        fatalError("unable to create DDIUniversalHIDService")
    }

    let peerPointer = Unmanaged.passRetained(peer).toOpaque()
    let hidxpcPointer = Unmanaged.passRetained(hidxpcObject as AnyObject).toOpaque()
    let ddiPointer = Unmanaged.passRetained(ddiObject as AnyObject).toOpaque()

    storePointer(hidxpcPointer, offset: 16, UnsafeRawPointer(peerPointer))
    storePointer(hidxpcPointer, offset: 24, peerWitness)
    var retainedFeatureIdentifier = featureIdentifier
    storeString(hidxpcPointer, offset: 32, &retainedFeatureIdentifier)
    retainedCoreDeviceStrings.append(retainedFeatureIdentifier)

    storePointer(ddiPointer, offset: 16, UnsafeRawPointer(hidxpcPointer))
    ddiPointer.advanced(by: 24).storeBytes(of: UInt(0), as: UInt.self)
    ddiPointer.advanced(by: 32).storeBytes(of: UInt(0), as: UInt.self)

    let ddiWitness = swiftProtocolWitness(
        for: ddiClass,
        protocolSymbol: "$s10CoreDevice19UniversalHIDServiceMp"
    )

    if ProcessInfo.processInfo.environment["HIDCTL_QUIET"] == nil {
        fputs("coredevice hid: peer=\(type(of: peer)) serviceName=\(serviceName) feature=\(featureIdentifier)\n", stderr)
        fputs("coredevice hid: peerWitness=\(peerWitness) ddiWitness=\(ddiWitness)\n", stderr)
        if ProcessInfo.processInfo.environment["HIDCTL_DUMP_WITNESS"] != nil {
            dumpWitnessTable("coredevice hid peer", peerWitness)
            dumpWitnessTable("coredevice hid ddi", ddiWitness)
        }
    }
    return (ddiPointer, ddiWitness)
}

func makeIndigoHIDButton(_ connection: UnsafeMutableRawPointer?) -> (UnsafeMutableRawPointer, UnsafeRawPointer) {
    let serviceName = ProcessInfo.processInfo.environment["HIDCTL_BUTTON_MERCURY_SERVICE"]
    let featureIdentifier = ProcessInfo.processInfo.environment["HIDCTL_BUTTON_FEATURE_ID"] ?? "com.apple.coredevice.feature.remote.hid.button"

    let peer: AnyObject
    if let serviceName, !serviceName.isEmpty {
        peer = mercuryUnsafePeerForService(connection, serviceName)
    } else {
        peer = mercuryUnsafePeer(connection)
    }

    guard let peerClass = object_getClass(peer) else {
        fatalError("unable to get Mercury peer class")
    }
    let peerWitness = swiftProtocolWitness(
        for: peerClass,
        protocolSymbol: "$s7Mercury17XPCPeerConnectionMp"
    )

    guard let buttonClass = objc_getClass("_TtC10CoreDevice15IndigoHIDButton") as? AnyClass else {
        fatalError("missing CoreDevice.IndigoHIDButton class")
    }
    guard let buttonObject = class_createInstance(buttonClass, 0) else {
        fatalError("unable to create IndigoHIDButton")
    }

    let peerPointer = Unmanaged.passRetained(peer).toOpaque()
    let buttonPointer = Unmanaged.passRetained(buttonObject as AnyObject).toOpaque()

    storePointer(buttonPointer, offset: 16, UnsafeRawPointer(peerPointer))
    storePointer(buttonPointer, offset: 24, peerWitness)
    var retainedFeatureIdentifier = featureIdentifier
    storeString(buttonPointer, offset: 32, &retainedFeatureIdentifier)
    retainedCoreDeviceStrings.append(retainedFeatureIdentifier)

    let buttonWitness = swiftProtocolWitness(
        for: buttonClass,
        protocolSymbol: "$s10CoreDevice9HIDButtonMp"
    )

    if ProcessInfo.processInfo.environment["HIDCTL_QUIET"] == nil {
        fputs("coredevice button: peer=\(type(of: peer)) serviceName=\(serviceName ?? "<base>") feature=\(featureIdentifier)\n", stderr)
        fputs("coredevice button: peerWitness=\(peerWitness) buttonWitness=\(buttonWitness)\n", stderr)
    }
    return (buttonPointer, buttonWitness)
}

func makeIndigoHIDScroll(_ connection: UnsafeMutableRawPointer?) -> (UnsafeMutableRawPointer, UnsafeRawPointer) {
    let serviceName = ProcessInfo.processInfo.environment["HIDCTL_SCROLL_MERCURY_SERVICE"]
    let featureIdentifier = ProcessInfo.processInfo.environment["HIDCTL_SCROLL_FEATURE_ID"] ?? "com.apple.coredevice.feature.remote.hid.scroll"

    let peer: AnyObject
    if let serviceName, !serviceName.isEmpty {
        peer = mercuryUnsafePeerForService(connection, serviceName)
    } else {
        peer = mercuryUnsafePeer(connection)
    }

    guard let peerClass = object_getClass(peer) else {
        fatalError("unable to get Mercury peer class")
    }
    let peerWitness = swiftProtocolWitness(
        for: peerClass,
        protocolSymbol: "$s7Mercury17XPCPeerConnectionMp"
    )

    guard let scrollClass = objc_getClass("_TtC10CoreDevice15IndigoHIDScroll") as? AnyClass else {
        fatalError("missing CoreDevice.IndigoHIDScroll")
    }
    guard let scrollObject = class_createInstance(scrollClass, 0) else {
        fatalError("unable to create IndigoHIDScroll")
    }

    let peerPointer = Unmanaged.passRetained(peer).toOpaque()
    let scrollPointer = Unmanaged.passRetained(scrollObject as AnyObject).toOpaque()

    storePointer(scrollPointer, offset: 16, UnsafeRawPointer(peerPointer))
    storePointer(scrollPointer, offset: 24, peerWitness)
    var retainedFeatureIdentifier = featureIdentifier
    storeString(scrollPointer, offset: 32, &retainedFeatureIdentifier)
    retainedCoreDeviceStrings.append(retainedFeatureIdentifier)

    let scrollWitness = swiftProtocolWitness(
        for: scrollClass,
        protocolSymbol: "$s10CoreDevice9HIDScrollMp"
    )

    if ProcessInfo.processInfo.environment["HIDCTL_QUIET"] == nil {
        fputs("coredevice scroll: peer=\(type(of: peer)) serviceName=\(serviceName ?? "<base>") feature=\(featureIdentifier)\n", stderr)
        fputs("coredevice scroll: peerWitness=\(peerWitness) scrollWitness=\(scrollWitness)\n", stderr)
    }
    return (scrollPointer, scrollWitness)
}

func makeIndigoHIDVendorDefined(_ connection: UnsafeMutableRawPointer?, deviceIdentifier: String) -> (UnsafeMutableRawPointer, UnsafeRawPointer) {
    let serviceName = ProcessInfo.processInfo.environment["HIDCTL_VENDOR_MERCURY_SERVICE"]
    let featureIdentifier = ProcessInfo.processInfo.environment["HIDCTL_VENDOR_FEATURE_ID"] ?? "com.apple.coredevice.feature.remote.hid.vendordefined"

    let peer: AnyObject
    if let serviceName, !serviceName.isEmpty {
        peer = mercuryUnsafePeerForService(connection, serviceName)
    } else {
        peer = mercuryUnsafePeer(connection)
    }

    guard let peerClass = object_getClass(peer) else {
        fatalError("unable to get Mercury peer class")
    }
    let peerWitness = swiftProtocolWitness(
        for: peerClass,
        protocolSymbol: "$s7Mercury17XPCPeerConnectionMp"
    )

    guard let vendorClass = objc_getClass("_TtC10CoreDevice22IndigoHIDVendorDefined") as? AnyClass else {
        fatalError("missing CoreDevice.IndigoHIDVendorDefined")
    }
    guard let vendorObject = class_createInstance(vendorClass, 0) else {
        fatalError("unable to create IndigoHIDVendorDefined")
    }

    let peerPointer = Unmanaged.passRetained(peer).toOpaque()
    let vendorPointer = Unmanaged.passRetained(vendorObject as AnyObject).toOpaque()

    storePointer(vendorPointer, offset: 16, UnsafeRawPointer(peerPointer))
    storePointer(vendorPointer, offset: 24, peerWitness)
    var retainedFeatureIdentifier = featureIdentifier
    storeString(vendorPointer, offset: 32, &retainedFeatureIdentifier)
    retainedCoreDeviceStrings.append(retainedFeatureIdentifier)

    var retainedDeviceIdentifier = deviceIdentifier
    storeString(vendorPointer, offset: 48, &retainedDeviceIdentifier)
    retainedCoreDeviceStrings.append(retainedDeviceIdentifier)

    let vendorWitness = swiftProtocolWitness(
        for: vendorClass,
        protocolSymbol: "$s10CoreDevice16HIDVendorDefinedMp"
    )

    if ProcessInfo.processInfo.environment["HIDCTL_QUIET"] == nil {
        fputs("coredevice vendor-defined: peer=\(type(of: peer)) serviceName=\(serviceName ?? "<base>") feature=\(featureIdentifier) device=\(deviceIdentifier)\n", stderr)
        fputs("coredevice vendor-defined: peerWitness=\(peerWitness) vendorWitness=\(vendorWitness)\n", stderr)
    }
    return (vendorPointer, vendorWitness)
}

func makeIndigoHIDDigitizer(_ connection: UnsafeMutableRawPointer?) -> (UnsafeMutableRawPointer, UnsafeRawPointer) {
    let serviceName = ProcessInfo.processInfo.environment["HIDCTL_DIGITIZER_MERCURY_SERVICE"]
    let featureIdentifier = ProcessInfo.processInfo.environment["HIDCTL_DIGITIZER_FEATURE_ID"] ?? "com.apple.coredevice.feature.remote.hid.digitizer"

    let peer: AnyObject
    if let serviceName, !serviceName.isEmpty {
        peer = mercuryUnsafePeerForService(connection, serviceName)
    } else {
        peer = mercuryUnsafePeer(connection)
    }

    guard let peerClass = object_getClass(peer) else {
        fatalError("unable to get Mercury peer class")
    }
    let peerWitness = swiftProtocolWitness(
        for: peerClass,
        protocolSymbol: "$s7Mercury17XPCPeerConnectionMp"
    )

    guard let digitizerClass = objc_getClass("_TtC10CoreDevice18IndigoHIDDigitizer") as? AnyClass else {
        fatalError("missing CoreDevice.IndigoHIDDigitizer class")
    }
    guard let digitizerObject = class_createInstance(digitizerClass, 0) else {
        fatalError("unable to create IndigoHIDDigitizer")
    }

    let peerPointer = Unmanaged.passRetained(peer).toOpaque()
    let digitizerPointer = Unmanaged.passRetained(digitizerObject as AnyObject).toOpaque()

    storePointer(digitizerPointer, offset: 16, UnsafeRawPointer(peerPointer))
    storePointer(digitizerPointer, offset: 24, peerWitness)
    var retainedFeatureIdentifier = featureIdentifier
    storeString(digitizerPointer, offset: 32, &retainedFeatureIdentifier)
    retainedCoreDeviceStrings.append(retainedFeatureIdentifier)

    let digitizerWitness = swiftProtocolWitness(
        for: digitizerClass,
        protocolSymbol: "$s10CoreDevice12HIDDigitizerMp"
    )

    if ProcessInfo.processInfo.environment["HIDCTL_QUIET"] == nil {
        fputs("coredevice digitizer: peer=\(type(of: peer)) serviceName=\(serviceName ?? "<base>") feature=\(featureIdentifier)\n", stderr)
        fputs("coredevice digitizer: peerWitness=\(peerWitness) digitizerWitness=\(digitizerWitness)\n", stderr)
    }
    return (digitizerPointer, digitizerWitness)
}

@_cdecl("coredevice_send_hid_scroll")
public func coredeviceSendHIDScroll(
    _ connection: UnsafeMutableRawPointer?,
    _ x: Double,
    _ y: Double,
    _ z: Double,
    _ phase: UInt16,
    _ momentum: UInt8,
    _ target: UInt8
) -> Int32 {
    guard connection != nil else {
        fputs("coredevice scroll: remote connection is null\n", stderr)
        return 2
    }
    let (scroll, witness) = makeIndigoHIDScroll(connection)
    return coredeviceHIDScrollDispatchABI(scroll, witness, x, y, z, phase, momentum, target)
}

@_cdecl("coredevice_send_hid_scroll_barrier")
public func coredeviceSendHIDScrollBarrier(_ connection: UnsafeMutableRawPointer?) -> Int32 {
    guard connection != nil else {
        fputs("coredevice scroll: remote connection is null\n", stderr)
        return 2
    }
    let (scroll, witness) = makeIndigoHIDScroll(connection)
    return coredeviceHIDScrollBarrierDispatchABI(scroll, witness)
}

func parseHexPayload(_ cString: UnsafePointer<CChar>?) -> Data? {
    guard let cString else {
        return Data()
    }
    var text = String(cString: cString)
    if text.hasPrefix("0x") || text.hasPrefix("0X") {
        text.removeFirst(2)
    }
    let filtered = text.filter { character in
        character != " " && character != ":" && character != "_" && character != "-"
    }
    guard filtered.count % 2 == 0 else {
        return nil
    }

    var data = Data()
    var index = filtered.startIndex
    while index < filtered.endIndex {
        let next = filtered.index(index, offsetBy: 2)
        guard let byte = UInt8(filtered[index..<next], radix: 16) else {
            return nil
        }
        data.append(byte)
        index = next
    }
    return data
}

@_cdecl("coredevice_send_hid_vendor_defined_hex")
public func coredeviceSendHIDVendorDefinedHex(
    _ connection: UnsafeMutableRawPointer?,
    _ usagePage: UInt32,
    _ usage: UInt32,
    _ version: UInt32,
    _ hexPayload: UnsafePointer<CChar>?,
    _ deviceIdentifier: UnsafePointer<CChar>?
) -> Int32 {
    guard connection != nil else {
        fputs("coredevice vendor-defined: remote connection is null\n", stderr)
        return 2
    }
    guard usagePage <= UInt16.max, usage <= UInt16.max else {
        fputs(String(format: "coredevice vendor-defined: usage values out of range page=0x%x usage=0x%x\n", usagePage, usage), stderr)
        return 2
    }
    guard var data = parseHexPayload(hexPayload) else {
        fputs("coredevice vendor-defined: invalid hex payload\n", stderr)
        return 2
    }

    retainedCoreDeviceData.append(data)
    let device = deviceIdentifier.map { String(cString: $0) } ?? ""
    let (vendor, witness) = makeIndigoHIDVendorDefined(connection, deviceIdentifier: device)
    return withUnsafeBytes(of: &data) { dataBytes in
        coredeviceHIDVendorDefinedDispatchABI(
            vendor,
            witness,
            UInt16(usagePage),
            UInt16(usage),
            version,
            dataBytes.baseAddress!
        )
    }
}

@_cdecl("coredevice_send_hid_vendor_defined_barrier")
public func coredeviceSendHIDVendorDefinedBarrier(
    _ connection: UnsafeMutableRawPointer?,
    _ deviceIdentifier: UnsafePointer<CChar>?
) -> Int32 {
    guard connection != nil else {
        fputs("coredevice vendor-defined: remote connection is null\n", stderr)
        return 2
    }
    let device = deviceIdentifier.map { String(cString: $0) } ?? ""
    let (vendor, witness) = makeIndigoHIDVendorDefined(connection, deviceIdentifier: device)
    return coredeviceHIDVendorDefinedBarrierDispatchABI(vendor, witness)
}

@_cdecl("mercury_send_xpc_message")
public func mercurySendXPCMessage(_ connection: UnsafeMutableRawPointer?, _ message: xpc_object_t?) -> Int32 {
    guard let connection else {
        fputs("mercury: remote connection is null\n", stderr)
        return 2
    }
    guard let message else {
        fputs("mercury: message is null\n", stderr)
        return 2
    }

    fputs("mercury: entering unsafePeer\n", stderr)
    let serviceName = ProcessInfo.processInfo.environment["HIDCTL_MERCURY_SERVICE"] ?? "com.apple.coredevice.hid.universal"
    fputs("mercury typed: unsafePeer for service \(serviceName)\n", stderr)
    let peer = mercuryUnsafePeerForService(connection, serviceName)
    fputs("mercury: unsafePeer returned \(type(of: peer))\n", stderr)
    fputs("mercury: wrapping xpc dictionary\n", stderr)
    let dictionary = mercuryXPCDictionary(message)
    fputs(String(format: "mercury: wrapped dictionary words=%016llx %016llx\n", dictionary.word0, dictionary.word1), stderr)
    fputs("mercury: sending message\n", stderr)
    let peerPointer = Unmanaged.passUnretained(peer).toOpaque()
    withUnsafePointer(to: dictionary) { dictionaryPointer in
        mercuryXPCConnectionSendABI(peerPointer, UnsafeRawPointer(dictionaryPointer))
    }
    fputs("mercury: send returned\n", stderr)
    return 0
}

@_cdecl("mercury_send_xpc_message_sync")
public func mercurySendXPCMessageSync(_ connection: UnsafeMutableRawPointer?, _ message: xpc_object_t?) -> Int32 {
    guard let connection else {
        fputs("mercury sync: remote connection is null\n", stderr)
        return 2
    }
    guard let message else {
        fputs("mercury sync: message is null\n", stderr)
        return 2
    }

    fputs("mercury sync: entering unsafePeer\n", stderr)
    let serviceName = ProcessInfo.processInfo.environment["HIDCTL_MERCURY_SERVICE"] ?? "com.apple.coredevice.hid.universal"
    fputs("mercury typed: unsafePeer for service \(serviceName)\n", stderr)
    let peer = mercuryUnsafePeerForService(connection, serviceName)
    fputs("mercury sync: unsafePeer returned \(type(of: peer))\n", stderr)
    let dictionary = mercuryXPCDictionary(message)
    var reply = MercuryXPCDictionary()
    let peerPointer = Unmanaged.passUnretained(peer).toOpaque()
    fputs("mercury sync: sending message\n", stderr)
    withUnsafePointer(to: dictionary) { dictionaryPointer in
        withUnsafeMutablePointer(to: &reply) { replyPointer in
            mercuryXPCConnectionSendSyncABI(peerPointer, UnsafeRawPointer(dictionaryPointer), UnsafeMutableRawPointer(replyPointer))
        }
    }
    fputs(String(format: "mercury sync: reply words=%016llx %016llx\n", reply.word0, reply.word1), stderr)
    if reply.word0 == 0 && reply.word1 == 0 {
        fputs("mercury sync reply NSDictionary: <empty>\n", stderr)
        return 1
    }
    if let nsDictionary = mercuryXPCDictionaryToNSDictionary(reply) {
        fputs("mercury sync reply NSDictionary: \(nsDictionary)\n", stderr)
    } else {
        fputs("mercury sync reply NSDictionary: <nil>\n", stderr)
    }
    return 0
}

@_cdecl("mercury_send_uhid_request_value")
public func mercurySendUHIDRequestValue(
    _ connection: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int,
    _ serviceID: UInt64
) -> Int32 {
    guard let connection else {
        fputs("mercury typed: remote connection is null\n", stderr)
        return 2
    }
    guard let bytes, length >= 0 else {
        fputs("mercury typed: report bytes are null\n", stderr)
        return 2
    }

    let data = Data(bytes: bytes, count: length)
    var request = makeUHIDSendRequest(data: data, serviceID: serviceID)
    _ = withUnsafePointer(to: &request) { requestPointer in
        fputs("mercury typed request: \(uhidRequestDescriptionABI(UnsafeRawPointer(requestPointer)))\n", stderr)
    }

    let serviceName = ProcessInfo.processInfo.environment["HIDCTL_MERCURY_SERVICE"] ?? "com.apple.coredevice.hid.universal"
    fputs("mercury typed: unsafePeer for service \(serviceName)\n", stderr)
    let peer = mercuryUnsafePeerForService(connection, serviceName)
    let peerPointer = Unmanaged.passUnretained(peer).toOpaque()
    let (metadata, decodableWitness, encodableWitness) = uhidRequestMetadataAndCodableWitnesses()
    let errorPointer = withUnsafePointer(to: &request) { requestPointer in
        mercuryXPCConnectionSendValueABI(
            peerPointer,
            UnsafeRawPointer(requestPointer),
            metadata,
            decodableWitness,
            encodableWitness
        )
    }
    if let errorPointer {
        fputs("mercury typed: send(value:) returned pointer \(errorPointer)\n", stderr)
        return 1
    }
    fputs("mercury typed: send(value:) returned\n", stderr)
    return 0
}

@_cdecl("coredevice_print_connected_services")
public func coredevicePrintConnectedServices(_ connection: UnsafeMutableRawPointer?) -> Int32 {
    guard let connection else {
        fputs("connected services: remote connection is null\n", stderr)
        return 2
    }

    var request = makeUHIDConnectedServicesRequest()
    if ProcessInfo.processInfo.environment["HIDCTL_QUIET"] == nil {
        _ = withUnsafePointer(to: &request) { requestPointer in
            fputs("connected services request: \(uhidRequestDescriptionABI(UnsafeRawPointer(requestPointer)))\n", stderr)
        }
    }

    let serviceName = ProcessInfo.processInfo.environment["HIDCTL_MERCURY_SERVICE"] ?? "com.apple.coredevice.hid.universalhidservice"
    let peer = mercuryUnsafePeerForService(connection, serviceName)
    let peerPointer = Unmanaged.passUnretained(peer).toOpaque()
    let (requestMetadata, requestDecodableWitness, requestEncodableWitness) = uhidRequestMetadataAndCodableWitnesses()
    let (replyMetadata, replyDecodableWitness, replyEncodableWitness) = uhidConnectedServicesMetadataAndCodableWitnesses()

    var reply: UInt64 = 0
    let result = withUnsafePointer(to: &request) { requestPointer in
        withUnsafeMutablePointer(to: &reply) { replyPointer in
            mercuryXPCConnectionSendSyncValueABI(
                peerPointer,
                UnsafeRawPointer(requestPointer),
                requestMetadata,
                requestDecodableWitness,
                requestEncodableWitness,
                replyMetadata,
                replyDecodableWitness,
                replyEncodableWitness,
                UnsafeMutableRawPointer(replyPointer)
            )
        }
    }

    fputs(String(format: "connected services result=%d raw=%016llx\n", result, reply), stderr)
    if result == 0 {
        _ = withUnsafePointer(to: &reply) { replyPointer in
            fputs("connected services: \(uhidConnectedServicesDescriptionABI(UnsafeRawPointer(replyPointer)))\n", stderr)
        }
    }
    return result
}

@_cdecl("coredevice_print_connected_descriptors_async_raw")
public func coredevicePrintConnectedDescriptorsAsyncRaw(_ connection: UnsafeMutableRawPointer?) -> Int32 {
    guard let connection else {
        fputs("connected descriptors async raw: remote connection is null\n", stderr)
        return 2
    }

    let (service, witness) = makeDDIUniversalHIDService(connection)
    let serviceAddress = UInt(bitPattern: service)
    let witnessAddress = UInt(bitPattern: witness)
    let state = AsyncProbeState()
    let semaphore = DispatchSemaphore(value: 0)

    Task {
        let resultBuffer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        resultBuffer.initializeMemory(as: UInt64.self, repeating: 0, count: 8)
        defer {
            resultBuffer.deallocate()
        }

        do {
            guard let asyncService = UnsafeRawPointer(bitPattern: serviceAddress),
                  let asyncWitness = UnsafeRawPointer(bitPattern: witnessAddress) else {
                fputs("connected descriptors async raw: failed to rebuild service pointers\n", stderr)
                state.result = 2
                semaphore.signal()
                return
            }
            let serviceBox = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
            serviceBox.storeBytes(of: UInt(bitPattern: asyncService), as: UInt.self)
            defer {
                serviceBox.deallocate()
            }
            let raw = try await coredeviceConnectedServiceDescriptorsAsyncABI(resultBuffer, serviceBox, asyncWitness)
            let words = resultBuffer.bindMemory(to: UInt64.self, capacity: 8)
            if ProcessInfo.processInfo.environment["HIDCTL_VERBOSE_DESCRIPTORS"] != nil {
                print(String(format: "connected descriptors async raw return=%016llx", UInt64(UInt(bitPattern: raw))))
                print(String(format: "connected descriptors async raw buffer=%016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx",
                             words[0], words[1], words[2], words[3], words[4], words[5], words[6], words[7]))
            }
            dumpRawDescriptorArray(raw)
            state.result = 0
        } catch {
            fputs("connected descriptors async raw error: \(error)\n", stderr)
            state.result = 1
        }
        semaphore.signal()
    }

    semaphore.wait()
    return state.result
}

@_cdecl("coredevice_send_universalhid_hid_report")
public func coredeviceSendUniversalHIDReport(
    _ connection: UnsafeMutableRawPointer?,
    _ reportWords: UnsafeRawPointer?,
    _ serviceID: UInt64
) -> Int32 {
    guard let connection else {
        fputs("coredevice hid: remote connection is null\n", stderr)
        return 2
    }
    guard let reportWords else {
        fputs("coredevice hid: report is null\n", stderr)
        return 2
    }

    let (service, witness) = makeDDIUniversalHIDService(connection)
    let result = coredeviceUniversalHIDSendDispatchABI(service, witness, reportWords, serviceID)
    if ProcessInfo.processInfo.environment["HIDCTL_QUIET"] == nil {
        fputs("coredevice hid: send dispatch result=\(result)\n", stderr)
    }
    return result
}

@_cdecl("coredevice_reset_universalhid_gesture")
public func coredeviceResetUniversalHIDGesture(
    _ connection: UnsafeMutableRawPointer?,
    _ serviceID: UInt64
) -> Int32 {
    guard let connection else {
        fputs("coredevice hid reset: remote connection is null\n", stderr)
        return 2
    }

    let (service, witness) = makeDDIUniversalHIDService(connection)
    let result = coredeviceUniversalHIDResetDispatchABI(service, witness, serviceID)
    if ProcessInfo.processInfo.environment["HIDCTL_QUIET"] == nil {
        fputs("coredevice hid: reset dispatch result=\(result)\n", stderr)
    }
    return result
}

@_cdecl("coredevice_send_universalhid_barrier")
public func coredeviceSendUniversalHIDBarrier(_ connection: UnsafeMutableRawPointer?) -> Int32 {
    guard let connection else {
        fputs("coredevice hid barrier: remote connection is null\n", stderr)
        return 2
    }

    let (service, witness) = makeDDIUniversalHIDService(connection)
    let result = coredeviceUniversalHIDBarrierDispatchABI(service, witness)
    if ProcessInfo.processInfo.environment["HIDCTL_QUIET"] == nil {
        fputs("coredevice hid: barrier dispatch result=\(result)\n", stderr)
    }
    return result
}

@_cdecl("coredevice_send_hid_button_custom")
public func coredeviceSendHIDButtonCustom(
    _ connection: UnsafeMutableRawPointer?,
    _ usagePage: UInt64,
    _ usageCode: UInt64,
    _ state: UInt8
) -> Int32 {
    guard let connection else {
        fputs("coredevice button: remote connection is null\n", stderr)
        return 2
    }

    let (button, witness) = makeIndigoHIDButton(connection)
    let result = coredeviceHIDButtonCustomDispatchABI(button, witness, usagePage, usageCode, state)
    if ProcessInfo.processInfo.environment["HIDCTL_QUIET"] == nil {
        fputs("coredevice button: custom dispatch result=\(result) page=\(usagePage) code=\(usageCode) state=\(state)\n", stderr)
    }
    return result
}

@_cdecl("coredevice_send_hid_button_barrier")
public func coredeviceSendHIDButtonBarrier(_ connection: UnsafeMutableRawPointer?) -> Int32 {
    guard let connection else {
        fputs("coredevice button barrier: remote connection is null\n", stderr)
        return 2
    }

    let (button, witness) = makeIndigoHIDButton(connection)
    let result = coredeviceHIDButtonBarrierDispatchABI(button, witness)
    if ProcessInfo.processInfo.environment["HIDCTL_QUIET"] == nil {
        fputs("coredevice button: barrier dispatch result=\(result)\n", stderr)
    }
    return result
}

@_cdecl("coredevice_send_hid_digitizer_cgpoint")
public func coredeviceSendHIDDigitizerCGPoint(
    _ connection: UnsafeMutableRawPointer?,
    _ pointOneX: Double,
    _ pointOneY: Double,
    _ pointTwoX: Double,
    _ pointTwoY: Double,
    _ pointTwoOptionalTag: UInt64,
    _ eventType: UInt64,
    _ edge: UInt64,
    _ targetLow: UInt64,
    _ targetHigh: UInt64
) -> Int32 {
    guard let connection else {
        fputs("coredevice digitizer: remote connection is null\n", stderr)
        return 2
    }

    let (digitizer, witness) = makeIndigoHIDDigitizer(connection)
    let result = coredeviceHIDDigitizerCGPointDispatchABI(
        digitizer,
        witness,
        pointOneX,
        pointOneY,
        pointTwoX,
        pointTwoY,
        pointTwoOptionalTag,
        eventType,
        edge,
        targetLow,
        targetHigh
    )
    if ProcessInfo.processInfo.environment["HIDCTL_QUIET"] == nil {
        fputs("coredevice digitizer: cgpoint dispatch result=\(result) p1=(\(pointOneX),\(pointOneY)) tag=\(pointTwoOptionalTag) event=\(eventType) edge=\(edge) target=(\(targetLow),\(targetHigh))\n", stderr)
    }
    return result
}
