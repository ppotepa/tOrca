# SQLCipher accesses mNativeHandle from native code through JNI. R8 cannot
# infer that field usage, so keeping the complete package is required for
# release builds.
-keep class net.sqlcipher.database.** { *; }
-keep class net.sqlcipher.** { *; }
