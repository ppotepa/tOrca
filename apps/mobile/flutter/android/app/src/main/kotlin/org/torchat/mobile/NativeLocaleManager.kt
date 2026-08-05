package org.torchat.mobile

import android.app.LocaleManager
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.LocaleList
import java.util.Locale

/** Keeps Android resources aligned with the locale selected by Flutter. */
object NativeLocaleManager {
    private const val PREFERENCES_NAME = "FlutterSharedPreferences"
    private const val LOCALE_PREFERENCE_KEY = "flutter.torchat.locale.preference"
    private const val SYSTEM_VALUE = "system"

    fun applyStoredPreference(context: Context) {
        val value = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            .getString(LOCALE_PREFERENCE_KEY, SYSTEM_VALUE)
        apply(context, value?.takeUnless { it == SYSTEM_VALUE })
    }

    fun setApplicationLocale(context: Context, languageTag: String?) {
        apply(context, languageTag)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.getSystemService(LocaleManager::class.java).applicationLocales =
                if (languageTag.isNullOrBlank()) {
                    LocaleList.getEmptyLocaleList()
                } else {
                    LocaleList.forLanguageTags(languageTag)
                }
        }
    }

    @Suppress("DEPRECATION")
    private fun apply(context: Context, languageTag: String?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
        val locale = if (languageTag.isNullOrBlank()) {
            android.content.res.Resources.getSystem().configuration.locales[0]
        } else {
            Locale.forLanguageTag(languageTag)
        }
        Locale.setDefault(locale)
        val configuration = Configuration(context.resources.configuration)
        configuration.setLocale(locale)
        configuration.setLayoutDirection(locale)
        context.resources.updateConfiguration(
            configuration,
            context.resources.displayMetrics,
        )
        context.applicationContext.resources.updateConfiguration(
            configuration,
            context.applicationContext.resources.displayMetrics,
        )
    }
}
