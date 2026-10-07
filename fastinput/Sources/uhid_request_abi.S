.text

.globl _uhid_request_connected_abi
.p2align 2
_uhid_request_connected_abi:
    stp x20, x30, [sp, #-16]!
    mov x8, x0
    bl _$s19CoreDeviceUtilities29DDIUniversalHIDServicePayloadO7RequestO17connectedServicesyA2EmFWC
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_request_send_abi
.p2align 2
_uhid_request_send_abi:
    stp x20, x30, [sp, #-16]!
    mov x8, x3
    bl _$s19CoreDeviceUtilities29DDIUniversalHIDServicePayloadO7RequestO4sendyAE10Foundation4DataV_0aB00E2IDVtcAEmFWC
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_request_description_abi
.p2align 2
_uhid_request_description_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    bl _$s19CoreDeviceUtilities29DDIUniversalHIDServicePayloadO7RequestO11descriptionSSvg
    ldp x20, x30, [sp], #16
    ret
