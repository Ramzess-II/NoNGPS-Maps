package app.organicmaps.nogps;

import static android.Manifest.permission.POST_NOTIFICATIONS;
import static android.content.pm.PackageManager.PERMISSION_GRANTED;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import androidx.annotation.DrawableRes;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.ActivityCompat;
import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;
import androidx.core.content.ContextCompat;
import app.organicmaps.MwmActivity;
import app.organicmaps.R;
import app.organicmaps.location.NoGpsBoxService;
import app.organicmaps.maplayer.StatusBar;
import app.organicmaps.routing.NavigationService;
import app.organicmaps.sdk.location.MockLocationShare;
import app.organicmaps.sdk.location.NoGps;
import app.organicmaps.sdk.routing.RoutingInfo;
import app.organicmaps.util.Utils;

/**
 * The one notification of the app: the navigation, else the car followed by the sensor box in the background, else the
 * notice that the position is given to other apps. The navigation service, the box service and the notice use the same
 * notification ID, so the system shows one item. While the position is shared, any of them gets a line about it and a
 * button to turn the share off.
 */
public final class StatusNotification
{
  public enum Content
  {
    NAVIGATION,
    FOLLOWING,
    SHARE_ONLY,
    NONE
  }

  private static final String SEPARATOR = " · ";
  // Android 16 turns an ongoing notification that asks for it into a chip of the status bar.
  private static final String EXTRA_REQUEST_PROMOTED_ONGOING = "android.requestPromotedOngoing";
  private static final String EXTRA_SHORT_CRITICAL_TEXT = "android.shortCriticalText";
  private static final int ANDROID_16 = 36;

  private StatusNotification() {}

  @NonNull
  public static Content choose(boolean navigating, boolean following, boolean shareOn)
  {
    if (navigating)
      return Content.NAVIGATION;
    if (following)
      return Content.FOLLOWING;
    return shareOn ? Content.SHARE_ONLY : Content.NONE;
  }

  /**
   * Posts the notification of what runs now: call it when the navigation or the share starts or ends.
   */
  public static void refresh(@NonNull Context context)
  {
    final Context app = context.getApplicationContext();
    switch (choose(NavigationService.isRunning(), NoGpsBoxService.isRunning(), MockLocationShare.isActive()))
    {
    case NAVIGATION -> NavigationService.refreshNotification(app);
    case FOLLOWING -> NoGpsBoxService.refreshNotification(app);
    case SHARE_ONLY -> postShareOnly(app);
    // The notice of a share that ended, or left by a killed run.
    case NONE -> NotificationManagerCompat.from(app).cancel(NavigationService.NOTIFICATION_ID);
    }
  }

  /**
   * Adds to the notification of the navigation: the look of the position source, the texts, the share notice.
   */
  public static void decorate(@NonNull Context context, @NonNull NotificationCompat.Builder builder,
                              @NonNull RoutingInfo info)
  {
    final NoGps.Status status = NoGps.getStatus();
    builder.setSmallIcon(getSmallIcon(context, status))
        .setContentTitle(getTitle(info.distToTurn.toString(context), info.nextStreet))
        .setContentText(getText(info.distToTarget.toString(context), info.totalTimeInSeconds,
                                context.getString(R.string.hour), context.getString(R.string.minute),
                                Utils.formatArrivalTime(context, info.totalTimeInSeconds)));
    final Bundle extras = new Bundle();
    extras.putBoolean(EXTRA_REQUEST_PROMOTED_ONGOING, true);
    extras.putCharSequence(EXTRA_SHORT_CRITICAL_TEXT, info.distToTurn.toString(context));
    builder.addExtras(extras);
    // A Live Update is not colorized.
    if (Build.VERSION.SDK_INT >= ANDROID_16)
      builder.setColorized(false);
    addShareNotice(context, builder);
  }

  /**
   * The small icon is the source of the position as in the bottom sheet. The system draws it in one color.
   */
  @DrawableRes
  static int getSmallIcon(@NonNull Context context, @NonNull NoGps.Status status)
  {
    return StatusBar.getBarLook(context, status).icon;
  }

  @NonNull
  static String getTitle(@NonNull String distToTurn, @Nullable String nextStreet)
  {
    return nextStreet == null || nextStreet.isEmpty() ? distToTurn : distToTurn + SEPARATOR + nextStreet;
  }

  /**
   * The distance and the time left, and the arrival time: {@code 12.4 km · 18 min · 14:32}.
   */
  @NonNull
  static String getText(@NonNull String distToTarget, int secondsLeft, @NonNull String hourUnit,
                        @NonNull String minuteUnit, @NonNull String arrival)
  {
    final long minutes = Utils.getRoutingMinutes(secondsLeft);
    final String left = minutes < 60 ? minutes + " " + minuteUnit
                                     : minutes / 60 + " " + hourUnit + " " + minutes % 60 + " " + minuteUnit;
    return distToTarget + SEPARATOR + left + SEPARATOR + arrival;
  }

  /**
   * While the position is given to other apps: a line about it and a button that turns the share off.
   */
  public static void addShareNotice(@NonNull Context context, @NonNull NotificationCompat.Builder builder)
  {
    // The builder of the navigation lives on: the line of an earlier update goes away with the share.
    final boolean shared = MockLocationShare.isActive();
    builder.setSubText(shared ? context.getString(R.string.nogps_share_notice) : null);
    if (shared)
      addTurnOffButton(context, builder);
  }

  private static void addTurnOffButton(@NonNull Context context, @NonNull NotificationCompat.Builder builder)
  {
    final int FLAG_IMMUTABLE = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ? 0 : PendingIntent.FLAG_IMMUTABLE;
    final PendingIntent turnOff = PendingIntent.getBroadcast(context, 0, new Intent(context, ShareOffReceiver.class),
                                                             PendingIntent.FLAG_UPDATE_CURRENT | FLAG_IMMUTABLE);
    builder.addAction(0, context.getString(R.string.nogps_share_turn_off), turnOff);
  }

  private static void postShareOnly(@NonNull Context context)
  {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
        && ActivityCompat.checkSelfPermission(context, POST_NOTIFICATIONS) != PERMISSION_GRANTED)
      return;
    final int FLAG_IMMUTABLE = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ? 0 : PendingIntent.FLAG_IMMUTABLE;
    final PendingIntent contentIntent = PendingIntent.getActivity(context, 0, new Intent(context, MwmActivity.class),
                                                                  PendingIntent.FLAG_UPDATE_CURRENT | FLAG_IMMUTABLE);
    final NotificationCompat.Builder builder = new NotificationCompat.Builder(context, NoGpsBoxService.CHANNEL_ID)
                                                   .setCategory(NotificationCompat.CATEGORY_SERVICE)
                                                   .setPriority(NotificationCompat.PRIORITY_LOW)
                                                   .setVisibility(NotificationCompat.VISIBILITY_SECRET)
                                                   .setOngoing(true)
                                                   .setShowWhen(false)
                                                   .setOnlyAlertOnce(true)
                                                   .setSmallIcon(app.organicmaps.branding.R.drawable.ic_splash)
                                                   .setContentTitle(context.getString(R.string.nogps_share_notice))
                                                   .setContentIntent(contentIntent)
                                                   .setColor(ContextCompat.getColor(context, R.color.notification));
    addTurnOffButton(context, builder);
    NotificationManagerCompat.from(context).notify(NavigationService.NOTIFICATION_ID, builder.build());
  }
}
