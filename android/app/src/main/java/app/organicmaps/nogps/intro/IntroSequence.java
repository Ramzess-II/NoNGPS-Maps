package app.organicmaps.nogps.intro;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

/**
 * The intro of the first start: which step is shown, how much of its text is typed out and what a tap does. It holds
 * no view, so a test drives it like the real app does.
 */
public final class IntroSequence
{
  /**
   * The text of a balloon appears at this speed, characters per second: about as fast as it is read, so the eye goes
   * to the panel without waiting for the text. The longest balloon takes a little over three seconds.
   */
  public static final float TYPE_CHARS_PER_S = 20;

  private static final IntroStep[] STEPS = IntroStep.values();

  private int mIndex;
  /**
   * A tap while the text was typing showed the rest of it at once.
   */
  private boolean mTyped;

  /**
   * The intro is shown once, on the map: not again after it was shown, and not over the navigation.
   */
  public static boolean isNeeded(boolean shown, boolean navigating)
  {
    return !shown && !navigating;
  }

  /**
   * Back to the first step: the How NonGPS works page plays the intro again on the same overlay.
   */
  public void restart()
  {
    mIndex = 0;
    mTyped = false;
  }

  /**
   * The step shown now, null when the intro is over.
   */
  @Nullable
  public IntroStep step()
  {
    return mIndex < STEPS.length ? STEPS[mIndex] : null;
  }

  public boolean isOver()
  {
    return step() == null;
  }

  /**
   * How many characters of a text of this length are shown after elapsedS on the step.
   */
  public int revealed(int length, double elapsedS)
  {
    final IntroStep step = step();
    if (step == null)
      return 0;
    if (mTyped || !step.isTyped())
      return length;
    return Math.min(length, (int) (elapsedS * TYPE_CHARS_PER_S));
  }

  public boolean isTyping(int length, double elapsedS)
  {
    return revealed(length, elapsedS) < length;
  }

  /**
   * A tap while the text types shows the rest of it, the next tap opens the next step.
   */
  public void tap(int length, double elapsedS)
  {
    if (isOver())
      return;
    if (isTyping(length, elapsedS))
    {
      mTyped = true;
      return;
    }
    ++mIndex;
    mTyped = false;
  }

  /**
   * The navigation starts: the intro is over and does not come back.
   */
  public void finish()
  {
    mIndex = STEPS.length;
    mTyped = false;
  }

  @NonNull
  @Override
  public String toString()
  {
    final IntroStep step = step();
    return "IntroSequence{" + (step == null ? "over" : step.name() + (mTyped ? ",typed" : "")) + '}';
  }
}
