# WorkManager (which ML Kit brings in) starts at launch and builds its Room
# database by class name. R8 can't see that, deleted WorkDatabase_Impl's
# constructor, and the app closed before opening ("Failed to create an
# instance of androidx.work.impl.WorkDatabase", Android 16, 0.4.1 / 0.5.0).
-keep class * extends androidx.room.RoomDatabase { <init>(); }

# WorkManager also creates its workers by class name.
-keep class * extends androidx.work.ListenableWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
}

# TensorFlow Lite (the People filter's face model) is reached from its native
# code by name, which R8 can't see.
-keep class org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.**
