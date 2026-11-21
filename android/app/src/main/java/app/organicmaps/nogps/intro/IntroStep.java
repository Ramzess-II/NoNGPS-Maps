package app.organicmaps.nogps.intro;

import androidx.annotation.IdRes;
import androidx.annotation.NonNull;
import androidx.annotation.StringRes;
import app.organicmaps.R;

/**
 * The steps of the intro of the first start, in their order: the modal telling what the app is, then a balloon at
 * every panel of the map. See IntroSequence.
 */
public enum IntroStep
{
  MODAL(0, R.string.nogps_intro_text),
  BOTTOM(R.id.map_buttons_bottom, R.string.nogps_intro_bottom),
  RIGHT(R.id.right_panel, R.string.nogps_intro_right),
  LEFT(R.id.car_controls, R.string.nogps_intro_left);

  @IdRes
  private final int mAnchorId;
  @StringRes
  private final int mTextId;

  IntroStep(@IdRes int anchorId, @StringRes int textId)
  {
    mAnchorId = anchorId;
    mTextId = textId;
  }

  /**
   * The view the balloon points at, 0 for the modal: it is centred and points at nothing.
   */
  @IdRes
  public int getAnchorId()
  {
    return mAnchorId;
  }

  @StringRes
  public int getTextId()
  {
    return mTextId;
  }

  /**
   * The text of a balloon is typed out to draw the eye; the text of the modal is too long for that.
   */
  public boolean isTyped()
  {
    return this != MODAL;
  }

  @NonNull
  public static IntroStep first()
  {
    return MODAL;
  }
}
