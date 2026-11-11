package app.organicmaps.sdk.api;

import androidx.annotation.Keep;
import androidx.annotation.NonNull;

public interface SharedTextListener
{
  // Called from JNI on the main thread. The URL is for nativeParseAndSetApiUrl(), empty if the text has no place.
  @Keep
  @SuppressWarnings("unused")
  void onSharedTextResolved(@NonNull String url);
}
