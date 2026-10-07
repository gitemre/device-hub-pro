.text
.globl _mercury_xpc_connection_send_abi
.p2align 2
_mercury_xpc_connection_send_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    bl _$s7Mercury13XPCConnectionC4send7messageyAA13XPCDictionaryV_tFTj
    ldp x20, x30, [sp], #16
    ret

.globl _mercury_xpc_connection_send_sync_abi
.p2align 2
_mercury_xpc_connection_send_sync_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    mov x8, x2
    bl _$s7Mercury13XPCConnectionC8sendSync7messageAA13XPCDictionaryVAG_tKFTj
    ldp x20, x30, [sp], #16
    ret

.globl _mercury_xpc_connection_send_value_abi
.p2align 2
_mercury_xpc_connection_send_value_abi:
    stp x20, x21, [sp, #-32]!
    stp x22, x30, [sp, #16]
    mov x20, x0
    mov x0, x1
    mov x1, x2
    mov x2, x3
    mov x3, x4
    bl _$s7Mercury13XPCConnectionC4send5valueyx_tKSeRzSERzlF
    mov x0, #0
    ldp x22, x30, [sp, #16]
    ldp x20, x21, [sp], #32
    ret

.globl _mercury_xpc_connection_send_sync_value_abi
.p2align 2
_mercury_xpc_connection_send_sync_value_abi:
    stp x20, x21, [sp, #-32]!
    stp x22, x30, [sp, #16]
    ldr x9, [sp, #32]
    mov x20, x0
    mov x0, x1
    mov x1, x2
    mov x2, x5
    // sendSync(value:) orders generic metadata before the Codable witnesses:
    // request metadata, reply metadata, request Decodable, request Encodable,
    // reply Decodable, reply Encodable.
    mov x5, x6
    mov x6, x7
    mov x8, x9
    mov x21, #0
    bl _$s7Mercury13XPCConnectionC8sendSync5valueq_x_tKSeRzSERzSeR_SER_r0_lF
    cmp x21, #0
    cset w0, ne
    ldp x22, x30, [sp, #16]
    ldp x20, x21, [sp], #32
    ret

.globl _uhid_connected_services_description_abi
.p2align 2
_uhid_connected_services_description_abi:
    stp x20, x30, [sp, #-16]!
    ldr x0, [x0]
    bl _$s19CoreDeviceUtilities29DDIUniversalHIDServicePayloadO17ConnectedServicesV11descriptionSSvg
    ldp x20, x30, [sp], #16
    ret

.globl _coredevice_connected_descriptors_async_abi
.p2align 2
_coredevice_connected_descriptors_async_abi:
    mov x20, x1
    b _$s10CoreDevice19UniversalHIDServiceP27connectedServiceDescriptorsSayAA0D10DescriptorVGyYaAA0aB5ErrorVYKFTj

.section __TEXT,__const
.globl _coredevice_connected_descriptors_async_abiTu
.p2align 2
_coredevice_connected_descriptors_async_abiTu:
    .long _coredevice_connected_descriptors_async_abi - _coredevice_connected_descriptors_async_abiTu
    .long 0x20

.text

.macro hid_static_getter_shim cname, swift_symbol
.globl \cname
.p2align 2
\cname:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x8, x0
    bl \swift_symbol
    ldp x29, x30, [sp], #16
    ret
.endmacro

.macro hid_value_getter_shim cname, swift_symbol
.globl \cname
.p2align 2
\cname:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x8, x0
    mov x0, x1
    bl \swift_symbol
    ldp x29, x30, [sp], #16
    ret
.endmacro

hid_static_getter_shim _hid_service_id_main_touchscreen_abi, _$s10CoreDevice12HIDServiceIDV0aB9UtilitiesE15mainTouchscreenACvgZ
hid_value_getter_shim _hid_service_id_touchscreen_abi, _$s10CoreDevice12HIDServiceIDV0aB9UtilitiesE11touchscreen07displayD0ACs6UInt32V_tFZ
hid_static_getter_shim _hid_service_id_main_keyboard_abi, _$s10CoreDevice12HIDServiceIDV0aB9UtilitiesE12mainKeyboardACvgZ
hid_value_getter_shim _hid_service_id_keyboard_abi, _$s10CoreDevice12HIDServiceIDV0aB9UtilitiesE8keyboard10identifierACs6UInt64V_tFZ
hid_static_getter_shim _hid_service_id_main_pointer_abi, _$s10CoreDevice12HIDServiceIDV0aB9UtilitiesE11mainPointerACvgZ
hid_value_getter_shim _hid_service_id_pointer_abi, _$s10CoreDevice12HIDServiceIDV0aB9UtilitiesE7pointer10identifierACs6UInt64V_tFZ
hid_static_getter_shim _hid_service_id_main_screen_buttons_abi, _$s10CoreDevice12HIDServiceIDV0aB9UtilitiesE17mainScreenButtonsACvgZ
hid_static_getter_shim _hid_service_id_touchscreen_gesture_abi, _$s10CoreDevice12HIDServiceIDV0aB9UtilitiesE18touchscreenGestureACvgZ
hid_static_getter_shim _hid_service_id_digital_crown_abi, _$s10CoreDevice12HIDServiceIDV0aB9UtilitiesE12digitalCrownACvgZ
hid_static_getter_shim _hid_service_id_dial_abi, _$s10CoreDevice12HIDServiceIDV0aB9UtilitiesE4dialACvgZ
hid_static_getter_shim _hid_service_id_avp_custom_abi, _$s10CoreDevice12HIDServiceIDV0aB9UtilitiesE9avpCustomACvgZ

.globl _hid_service_id_user_defined_base_abi
.p2align 2
_hid_service_id_user_defined_base_abi:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _$s10CoreDevice12HIDServiceIDV0aB9UtilitiesE15userDefinedBases6UInt64VvgZ
    ldp x29, x30, [sp], #16
    ret

.globl _coredevice_universalhid_send_dispatch_abi
.p2align 2
_coredevice_universalhid_send_dispatch_abi:
    stp x20, x21, [sp, #-32]!
    stp x22, x30, [sp, #16]
    sub sp, sp, #160
    str x0, [sp]
    mov x5, x1
    ldr x0, [x2]
    ldr x1, [x2, #8]
    str x3, [sp, #8]
    add x2, sp, #8
    add x3, sp, #32
    add x20, sp, #0
    mov x21, #0
    bl _$s10CoreDevice19UniversalHIDServiceP4send6report2toy0C3HID9HIDReportV_AA0D2IDVtAA0aB5ErrorVYKFTj
    cmp x21, #0
    cset w0, ne
    add sp, sp, #160
    ldp x22, x30, [sp, #16]
    ldp x20, x21, [sp], #32
    ret

.globl _coredevice_universalhid_reset_dispatch_abi
.p2align 2
_coredevice_universalhid_reset_dispatch_abi:
    stp x20, x21, [sp, #-32]!
    stp x22, x30, [sp, #16]
    sub sp, sp, #160
    str x0, [sp]
    mov x3, x1
    str x2, [sp, #8]
    add x0, sp, #8
    add x1, sp, #32
    add x20, sp, #0
    mov x21, #0
    bl _$s10CoreDevice19UniversalHIDServiceP17resetGestureState7serviceyAA0D2IDV_tAA0aB5ErrorVYKFTj
    cmp x21, #0
    cset w0, ne
    add sp, sp, #160
    ldp x22, x30, [sp, #16]
    ldp x20, x21, [sp], #32
    ret

.globl _coredevice_universalhid_barrier_dispatch_abi
.p2align 2
_coredevice_universalhid_barrier_dispatch_abi:
    stp x20, x30, [sp, #-32]!
    str x21, [sp, #16]
    sub sp, sp, #16
    str x0, [sp]
    mov x1, x1
    add x20, sp, #0
    bl _$s10CoreDevice19UniversalHIDServiceP11sendBarrieryyFTj
    mov w0, #0
    add sp, sp, #16
    ldr x21, [sp, #16]
    ldp x20, x30, [sp], #32
    ret

.globl _coredevice_hidbutton_custom_dispatch_abi
.p2align 2
_coredevice_hidbutton_custom_dispatch_abi:
    stp x20, x21, [sp, #-32]!
    stp x22, x30, [sp, #16]
    sub sp, sp, #32
    str x0, [sp]
    mov x9, x1
    mov x0, x2
    mov x1, x3
    and w10, w4, #0xff
    strb w10, [sp, #8]
    add x2, sp, #8
    mov x4, x9
    add x20, sp, #0
    mov x21, #0
    bl _$s10CoreDevice9HIDButtonP16sendCustomButton9usagePage0G4Code5stateySi_SiAA0C5StateOtKFTj
    cmp x21, #0
    cset w0, ne
    add sp, sp, #32
    ldp x22, x30, [sp, #16]
    ldp x20, x21, [sp], #32
    ret

.globl _coredevice_hidbutton_barrier_dispatch_abi
.p2align 2
_coredevice_hidbutton_barrier_dispatch_abi:
    stp x20, x30, [sp, #-32]!
    str x21, [sp, #16]
    sub sp, sp, #16
    str x0, [sp]
    add x20, sp, #0
    bl _$s10CoreDevice9HIDButtonP11sendBarrieryyFTj
    mov w0, #0
    add sp, sp, #16
    ldr x21, [sp, #16]
    ldp x20, x30, [sp], #32
    ret

.globl _coredevice_hidscroll_dispatch_abi
.p2align 2
_coredevice_hidscroll_dispatch_abi:
    stp x20, x21, [sp, #-32]!
    stp x22, x30, [sp, #16]
    sub sp, sp, #64
    str x0, [sp]
    mov x9, x1
    str d0, [sp, #16]
    str d1, [sp, #24]
    str d2, [sp, #32]
    strh w2, [sp, #40]
    strb w3, [sp, #42]
    strb w4, [sp, #43]
    add x0, sp, #16
    add x1, sp, #40
    add x2, sp, #42
    add x3, sp, #43
    mov x5, x9
    add x20, sp, #0
    mov x21, #0
    bl _$s10CoreDevice9HIDScrollP4send5point5phase8momentum6targetyAA11ScrollPointV_AA0I5PhaseVAA0I8MomentumVAA0I6TargetOtKFTj
    cmp x21, #0
    cset w0, ne
    add sp, sp, #64
    ldp x22, x30, [sp, #16]
    ldp x20, x21, [sp], #32
    ret

.globl _coredevice_hidscroll_barrier_dispatch_abi
.p2align 2
_coredevice_hidscroll_barrier_dispatch_abi:
    stp x20, x30, [sp, #-32]!
    str x21, [sp, #16]
    sub sp, sp, #16
    str x0, [sp]
    add x20, sp, #0
    bl _$s10CoreDevice9HIDScrollP11sendBarrieryyFTj
    mov w0, #0
    add sp, sp, #16
    ldr x21, [sp, #16]
    ldp x20, x30, [sp], #32
    ret

.globl _coredevice_hidvendor_dispatch_abi
.p2align 2
_coredevice_hidvendor_dispatch_abi:
    stp x20, x21, [sp, #-32]!
    stp x22, x30, [sp, #16]
    sub sp, sp, #32
    str x0, [sp]
    mov x7, x1
    and w0, w2, #0xffff
    and w1, w3, #0xffff
    mov w2, w4
    ldr x3, [x5]
    ldr x4, [x5, #8]
    add x20, sp, #0
    mov x21, #0
    bl _$s10CoreDevice16HIDVendorDefinedP4send9usagePage0F07version4datays6UInt16V_AJs6UInt32V10Foundation4DataVtAA0aB5ErrorVYKFTj
    cmp x21, #0
    cset w0, ne
    add sp, sp, #32
    ldp x22, x30, [sp, #16]
    ldp x20, x21, [sp], #32
    ret

.globl _coredevice_hidvendor_barrier_dispatch_abi
.p2align 2
_coredevice_hidvendor_barrier_dispatch_abi:
    stp x20, x30, [sp, #-32]!
    str x21, [sp, #16]
    sub sp, sp, #16
    str x0, [sp]
    add x20, sp, #0
    bl _$s10CoreDevice16HIDVendorDefinedP11sendBarrieryyFTj
    mov w0, #0
    add sp, sp, #16
    ldr x21, [sp, #16]
    ldp x20, x30, [sp], #32
    ret

.globl _coredevice_hiddigitizer_cgpoint_dispatch_abi
.p2align 2
_coredevice_hiddigitizer_cgpoint_dispatch_abi:
    stp x20, x21, [sp, #-32]!
    stp x22, x30, [sp, #16]
    sub sp, sp, #64
    str x0, [sp]
    mov x9, x1
    mov x10, x2
    mov x11, x3
    mov x12, x4
    mov x13, x5
    mov x14, x6
    str x11, [sp, #8]
    str x12, [sp, #16]
    str x13, [sp, #24]
    fmov x0, d2
    fmov x1, d3
    mov x2, x10
    add x3, sp, #8
    add x4, sp, #16
    add x5, sp, #24
    mov x6, x14
    mov x7, x9
    add x20, sp, #0
    mov x21, #0
    bl _$s10CoreDevice12HIDDigitizerPAAE4send8pointOne0E3Two9eventType4edge6targetySo7CGPointV_AKSgAA014DigitizerEventI0OAA0M4EdgeOAA0M6TargetOtKF
    cmp x21, #0
    cset w0, ne
    add sp, sp, #64
    ldp x22, x30, [sp, #16]
    ldp x20, x21, [sp], #32
    ret
