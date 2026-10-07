package com.devicehubpro.verifier

import android.app.Application

/**
 * Records every onTrimMemory this process receives, for the Trim memory row. The Application's
 * callback sees each level the activity manager delivers (`am send-trim-memory` included).
 */
class VerifierApplication : Application() {
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        TrimLog.record(level, System.currentTimeMillis())
    }
}
