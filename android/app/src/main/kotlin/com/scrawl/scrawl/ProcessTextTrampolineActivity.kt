package com.dtonon.manent

import android.app.Activity
import android.content.Intent
import android.os.Bundle

class ProcessTextTrampolineActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
        if (text != null) {
            startActivity(
                Intent(this, MainActivity::class.java).apply {
                    action = "manent.ACTION_PROCESS_TEXT"
                    putExtra(Intent.EXTRA_PROCESS_TEXT, text)
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
            )
        }
        finish()
    }
}
