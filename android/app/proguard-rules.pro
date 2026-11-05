# Release-build (R8) rules for FetchNet. Flutter adds this file automatically.

# ───── youtubedl-android (yt-dlp + Python + FFmpeg + QuickJS) ─────
# The library ships no consumer rules of its own.
-keep class com.yausername.** { *; }

# It unpacks its bundled Python / FFmpeg runtimes with Apache commons-compress,
# whose ExtraFieldUtils registers zip "extra field" classes by reflection
# (Class.newInstance). Without this rule R8 sees no direct construction, makes
# those classes abstract / drops their constructors, ExtraFieldUtils fails to
# initialize, and the engine never starts ("download engine failed to start").
-keep class org.apache.commons.compress.archivers.zip.** { *; }
-dontwarn org.apache.commons.compress.**

# Jackson: youtubedl-android creates an ObjectMapper; databind is reflective.
-keep class com.fasterxml.jackson.** { *; }
-keepattributes Signature,*Annotation*,InnerClasses,EnclosingMethod
-dontwarn com.fasterxml.jackson.databind.ext.**
-dontwarn java.beans.**
-dontwarn org.w3c.dom.bootstrap.**

# ───── FetchNet's own native side ─────
# Activities, services and receivers are referenced from the manifest; keep the
# whole package so method-channel handlers and notifier helpers stay intact.
-keep class com.fetchnet.** { *; }
