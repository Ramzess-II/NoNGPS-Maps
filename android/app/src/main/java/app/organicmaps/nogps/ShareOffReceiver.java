package app.organicmaps.nogps;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import app.organicmaps.sdk.location.MockLocationShare;

/**
 * The "Turn off sharing" button of the notification. The share ends at its next tick and the notification follows it.
 */
public class ShareOffReceiver extends BroadcastReceiver
{
  @Override
  public void onReceive(Context context, Intent intent)
  {
    MockLocationShare.setEnabled(false);
  }
}
