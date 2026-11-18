package app.organicmaps.sdk.location;

import androidx.annotation.NonNull;
import java.util.HashMap;
import java.util.Map;

/**
 * The sensor boxes seen in the Bluetooth scan: a box is near while its advertisement was seen in the last minute.
 */
class NearbyBoxes
{
  static final long TIMEOUT_MS = 60_000;

  private final Map<String, Long> mSeenMs = new HashMap<>();

  void onSeen(@NonNull String id, long nowMs)
  {
    mSeenMs.put(id, nowMs);
  }

  boolean isNearby(@NonNull String id, long nowMs)
  {
    final Long seenMs = mSeenMs.get(id);
    return seenMs != null && nowMs - seenMs <= TIMEOUT_MS;
  }

  void clear()
  {
    mSeenMs.clear();
  }
}
