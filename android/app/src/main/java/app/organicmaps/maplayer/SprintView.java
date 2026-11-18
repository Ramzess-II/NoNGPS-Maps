package app.organicmaps.maplayer;

import android.content.Context;
import android.content.res.ColorStateList;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.HapticFeedbackConstants;
import android.view.View;
import android.view.animation.OvershootInterpolator;
import android.widget.TextView;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import app.organicmaps.R;
import app.organicmaps.nogps.Sprints;
import app.organicmaps.sdk.location.NoGps;

/**
 * The card in the bottom third of the map that tells the time of a run from a standing start (0-100 km/h, quarter
 * mile). A record is celebrated with confetti. The texts are in Sprints.
 */
class SprintView
{
  private static final long IN_MS = 380;
  private static final long OUT_MS = 180;
  private static final float IN_SCALE = 0.85f;
  private static final float IN_SHIFT_DP = 16;

  @NonNull
  private final View mFrame;
  @NonNull
  private final View mCard;
  @NonNull
  private final TextView mSmall;
  @NonNull
  private final TextView mBig;
  @NonNull
  private final TextView mWas;
  @Nullable
  private final SpeedHintConfettiView mConfetti;
  private final int mAccent;
  private final int mDone;
  private final float mDensity;
  private final Handler mHandler = new Handler(Looper.getMainLooper());
  private final Runnable mHide = this::hide;

  /**
   * @param frame    the frame of map_sprint.xml.
   * @param confetti over the map, null if the layout has none.
   */
  SprintView(@NonNull View frame, @Nullable SpeedHintConfettiView confetti)
  {
    mFrame = frame;
    mCard = frame.findViewById(R.id.sprint);
    mSmall = frame.findViewById(R.id.sprint_small);
    mBig = frame.findViewById(R.id.sprint_big);
    mWas = frame.findViewById(R.id.sprint_was);
    mConfetti = confetti;
    final Context context = frame.getContext();
    mAccent = ContextCompat.getColor(context, R.color.speed_hint_accent);
    mDone = ContextCompat.getColor(context, R.color.speed_hint_done);
    mDensity = context.getResources().getDisplayMetrics().density;
    mCard.setOnClickListener(v -> hide());
  }

  /**
   * The status of Event.SPRINT_MEASURED. A result replaces the one still shown.
   */
  void show(@NonNull NoGps.Status status)
  {
    final Sprints.Card card = Sprints.card(mCard.getContext()::getString, status);
    mSmall.setText(card.small());
    mSmall.setVisibility(card.small().isEmpty() ? View.GONE : View.VISIBLE);
    mBig.setText(card.big());
    mWas.setText(card.was());
    mWas.setVisibility(card.was().isEmpty() ? View.GONE : View.VISIBLE);
    mCard.setBackgroundTintList(ColorStateList.valueOf(card.record() ? mDone : mAccent));
    mCard.setContentDescription((card.small().isEmpty() ? "" : card.small() + ". ") + card.big()
                                + (card.was().isEmpty() ? "" : ". " + card.was()));

    mHandler.removeCallbacks(mHide);
    mCard.animate().cancel();
    mCard.setVisibility(View.VISIBLE);
    mCard.setAlpha(0);
    mCard.setScaleX(IN_SCALE);
    mCard.setScaleY(IN_SCALE);
    mCard.setTranslationY(IN_SHIFT_DP * mDensity);
    mCard.animate()
        .alpha(1)
        .scaleX(1)
        .scaleY(1)
        .translationY(0)
        .setDuration(IN_MS)
        .setInterpolator(new OvershootInterpolator(2))
        .start();
    if (card.record())
    {
      mCard.performHapticFeedback(Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ? HapticFeedbackConstants.CONFIRM
                                                                                 : HapticFeedbackConstants.VIRTUAL_KEY);
      throwConfetti();
    }
    mHandler.postDelayed(mHide, Sprints.alertMs(card.record()));
  }

  /**
   * The map is not seen: the card is hidden at once.
   */
  void stop()
  {
    mHandler.removeCallbacks(mHide);
    mCard.animate().cancel();
    mCard.setVisibility(View.GONE);
    if (mConfetti != null)
      mConfetti.stop();
  }

  /**
   * Moves with the bottom panel, e.g. above the place page.
   */
  void setTranslationY(float translationY)
  {
    mFrame.setTranslationY(translationY);
  }

  private void hide()
  {
    mHandler.removeCallbacks(mHide);
    if (mCard.getVisibility() != View.VISIBLE)
      return;
    mCard.animate().cancel();
    mCard.animate().alpha(0).setDuration(OUT_MS).withEndAction(() -> mCard.setVisibility(View.GONE)).start();
  }

  private void throwConfetti()
  {
    if (mConfetti == null || mConfetti.getWidth() == 0 || mCard.getWidth() == 0)
      return;
    final int[] origin = new int[2];
    mConfetti.getLocationInWindow(origin);
    final int[] card = new int[2];
    mCard.getLocationInWindow(card);
    final float left = card[0] - origin[0];
    mConfetti.burst(left, left + mCard.getWidth(), card[1] - origin[1]);
  }
}
