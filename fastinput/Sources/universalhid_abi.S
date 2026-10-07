.text

.globl _uhid_hid_report_set_bit_abi
.p2align 2
_uhid_hid_report_set_bit_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x2
    bl _$s12UniversalHID9HIDReportVySuSicis
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_digitizer_contact_set_index_abi
.p2align 2
_uhid_digitizer_contact_set_index_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    bl _$s12UniversalHID16DigitizerContactV5indexSivs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_pointer_report_set_x_abi
.p2align 2
_uhid_pointer_report_set_x_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    bl _$s12UniversalHID13PointerReportV1xSivs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_pointer_report_set_y_abi
.p2align 2
_uhid_pointer_report_set_y_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    bl _$s12UniversalHID13PointerReportV1ySivs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_pointer_report_set_button_mask_abi
.p2align 2
_uhid_pointer_report_set_button_mask_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    bl _$s12UniversalHID13PointerReportV10buttonMasks5UInt8Vvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_pointer_report_set_flags_abi
.p2align 2
_uhid_pointer_report_set_flags_abi:
    stp x20, x30, [sp, #-16]!
    sub sp, sp, #16
    mov x20, x0
    str w1, [sp, #12]
    add x0, sp, #12
    bl _$s12UniversalHID13PointerReportV5flagsAC5FlagsVvs
    add sp, sp, #16
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_pointer_report_set_accel_x_abi
.p2align 2
_uhid_pointer_report_set_accel_x_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    bl _$s12UniversalHID13PointerReportV6accelXSdvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_pointer_report_set_accel_y_abi
.p2align 2
_uhid_pointer_report_set_accel_y_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    bl _$s12UniversalHID13PointerReportV6accelYSdvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_scroll_collection_set_flags_abi
.p2align 2
_uhid_scroll_collection_set_flags_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    bl _$s12UniversalHID16ScrollCollectionV5flagss5UInt8Vvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_scroll_collection_set_phase_abi
.p2align 2
_uhid_scroll_collection_set_phase_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    bl _$s12UniversalHID16ScrollCollectionV5phaseAA13HIDEventPhaseVvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_scroll_collection_set_momentum_abi
.p2align 2
_uhid_scroll_collection_set_momentum_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    bl _$s12UniversalHID16ScrollCollectionV8momentumAA17HIDScrollMomentumVvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_scroll_collection_set_x_abi
.p2align 2
_uhid_scroll_collection_set_x_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    bl _$s12UniversalHID16ScrollCollectionV1xSivs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_scroll_collection_set_y_abi
.p2align 2
_uhid_scroll_collection_set_y_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    bl _$s12UniversalHID16ScrollCollectionV1ySivs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_scroll_collection_set_accel_x_abi
.p2align 2
_uhid_scroll_collection_set_accel_x_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    bl _$s12UniversalHID16ScrollCollectionV6accelXSdvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_scroll_collection_set_accel_y_abi
.p2align 2
_uhid_scroll_collection_set_accel_y_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    bl _$s12UniversalHID16ScrollCollectionV6accelYSdvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_scroll_report_set_collection_abi
.p2align 2
_uhid_scroll_report_set_collection_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    ldr x0, [x1]
    ldr x1, [x1, #8]
    bl _$s12UniversalHID12ScrollReportV16scrollCollectionAA0cF0Vvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_digitizer_contact_set_touch_abi
.p2align 2
_uhid_digitizer_contact_set_touch_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    bl _$s12UniversalHID16DigitizerContactV5touchSbvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_digitizer_contact_set_range_abi
.p2align 2
_uhid_digitizer_contact_set_range_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    bl _$s12UniversalHID16DigitizerContactV5rangeSbvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_digitizer_contact_set_resting_abi
.p2align 2
_uhid_digitizer_contact_set_resting_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    bl _$s12UniversalHID16DigitizerContactV7restingSbvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_digitizer_contact_set_x_abi
.p2align 2
_uhid_digitizer_contact_set_x_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    bl _$s12UniversalHID16DigitizerContactV1xSdvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_digitizer_contact_set_y_abi
.p2align 2
_uhid_digitizer_contact_set_y_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    bl _$s12UniversalHID16DigitizerContactV1ySdvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_digitizer_report_set_contact_count_abi
.p2align 2
_uhid_digitizer_report_set_contact_count_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    bl _$s12UniversalHID15DigitizerReportV12contactCounts5UInt8Vvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_digitizer_report_set_contact_count_maximum_abi
.p2align 2
_uhid_digitizer_report_set_contact_count_maximum_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    bl _$s12UniversalHID15DigitizerReportV19contactCountMaximums5UInt8Vvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_digitizer_report_set_contact_abi
.p2align 2
_uhid_digitizer_report_set_contact_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    ldr x0, [x1]
    ldr x1, [x1, #8]
    bl _$s12UniversalHID15DigitizerReportV10setContact_7atIndexyAA0cF0V_SitF
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_digitizer_report_set_contact_swipe_pending_abi
.p2align 2
_uhid_digitizer_report_set_contact_swipe_pending_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    mov x1, x2
    bl _$s12UniversalHID15DigitizerReportV22setContactSwipePending_7atIndexySb_SitF
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_digitizer_report_set_contact_swipe_locked_abi
.p2align 2
_uhid_digitizer_report_set_contact_swipe_locked_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    mov x1, x2
    bl _$s12UniversalHID15DigitizerReportV21setContactSwipeLocked_7atIndexySb_SitF
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_digitizer_report_set_contact_swipe_up_abi
.p2align 2
_uhid_digitizer_report_set_contact_swipe_up_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    mov x1, x2
    bl _$s12UniversalHID15DigitizerReportV17setContactSwipeUp_7atIndexySb_SitF
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_fluid_set_phase_abi
.p2align 2
_uhid_fluid_set_phase_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x3
    bl _$s12UniversalHID31FluidTouchGestureReportProtocolPAAE5phaseAA13HIDEventPhaseVvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_fluid_set_swipe_mask_abi
.p2align 2
_uhid_fluid_set_swipe_mask_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x3
    bl _$s12UniversalHID31FluidTouchGestureReportProtocolPAAE9swipeMasks6UInt32Vvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_fluid_set_gesture_motion_abi
.p2align 2
_uhid_fluid_set_gesture_motion_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x3
    bl _$s12UniversalHID31FluidTouchGestureReportProtocolPAAE13gestureMotions6UInt16Vvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_fluid_set_flavor_abi
.p2align 2
_uhid_fluid_set_flavor_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x3
    bl _$s12UniversalHID31FluidTouchGestureReportProtocolPAAE6flavors6UInt16Vvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_fluid_set_progress_abi
.p2align 2
_uhid_fluid_set_progress_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    mov x1, x2
    bl _$s12UniversalHID31FluidTouchGestureReportProtocolPAAE8progressSdvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_fluid_set_x_abi
.p2align 2
_uhid_fluid_set_x_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    mov x1, x2
    bl _$s12UniversalHID31FluidTouchGestureReportProtocolPAAE1xSdvs
    ldp x20, x30, [sp], #16
    ret

.globl _uhid_fluid_set_y_abi
.p2align 2
_uhid_fluid_set_y_abi:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    mov x0, x1
    mov x1, x2
    bl _$s12UniversalHID31FluidTouchGestureReportProtocolPAAE1ySdvs
    ldp x20, x30, [sp], #16
    ret
