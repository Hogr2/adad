# ---- flutter_local_notifications + Gson ----
# The plugin persists scheduled notifications with Gson, which resolves generics
# reflectively at runtime (TypeToken). Flutter's Gradle plugin enables R8 for
# release builds by default, and the plugin ships no consumer ProGuard rules,
# so without these keeps R8 strips the generic signature metadata and renames
# the model classes. Result: "RuntimeException: Missing type parameter." in
# loadScheduledNotifications() and scheduled notifications silently never fire
# (immediate .show() still works, which makes it look like a scheduling bug).

-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# Plugin classes (including the models Gson serializes)
-keep class com.dexterous.** { *; }
-dontwarn com.dexterous.**

# Gson itself
-keep class com.google.gson.** { *; }
-keep class * extends com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer
-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}
# Prevent R8 from stripping the generic type argument out of TypeToken subclasses
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken