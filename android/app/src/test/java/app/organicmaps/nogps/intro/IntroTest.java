package app.organicmaps.nogps.intro;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import android.content.Context;
import app.organicmaps.R;
import org.junit.Test;

/**
 * The step machine and the typewriter of the intro of the first start, see IntroSequence.
 */
public class IntroTest
{
  // Longer than any balloon: it takes more than one tick of the typewriter to appear.
  private static final int TEXT = 40;

  @Test
  public void stepsFollowTheModal()
  {
    final IntroSequence sequence = new IntroSequence();
    assertEquals(IntroStep.MODAL, sequence.step());
    // The modal is not typed: the accent button opens the first balloon at once.
    assertFalse(sequence.isTyping(TEXT, 0));
    sequence.tap(TEXT, 0);
    assertEquals(IntroStep.BOTTOM, sequence.step());
    sequence.tap(TEXT, TEXT);
    assertEquals(IntroStep.RIGHT, sequence.step());
    sequence.tap(TEXT, TEXT);
    assertEquals(IntroStep.LEFT, sequence.step());
    assertFalse(sequence.isOver());
  }

  @Test
  public void anchorsAndTextsOfTheSteps()
  {
    assertEquals(0, IntroStep.MODAL.getAnchorId());
    assertEquals(R.id.map_buttons_bottom, IntroStep.BOTTOM.getAnchorId());
    assertEquals(R.id.right_panel, IntroStep.RIGHT.getAnchorId());
    assertEquals(R.id.car_controls, IntroStep.LEFT.getAnchorId());
    final Context context = mock(Context.class);
    when(context.getString(R.string.nogps_intro_text)).thenReturn("modal");
    when(context.getString(R.string.nogps_intro_bottom)).thenReturn("bottom");
    when(context.getString(R.string.nogps_intro_right)).thenReturn("right");
    when(context.getString(R.string.nogps_intro_right_swipe)).thenReturn("slide");
    when(context.getString(R.string.nogps_intro_left)).thenReturn("left");
    assertEquals("modal", IntroStep.MODAL.getText(context));
    assertEquals("bottom", IntroStep.BOTTOM.getText(context));
    // The slide of the zoom buttons is told in the balloon of the right panel only, as on iOS.
    assertEquals("right slide", IntroStep.RIGHT.getText(context));
    assertEquals("left", IntroStep.LEFT.getText(context));
    assertFalse(IntroStep.MODAL.isTyped());
    for (IntroStep step : new IntroStep[] {IntroStep.BOTTOM, IntroStep.RIGHT, IntroStep.LEFT})
      assertTrue(step.isTyped());
  }

  @Test
  public void typesAboutTwentyCharactersASecond()
  {
    final IntroSequence sequence = new IntroSequence();
    sequence.tap(TEXT, 0);
    assertEquals(IntroStep.BOTTOM, sequence.step());
    assertEquals(0, sequence.revealed(TEXT, 0));
    assertEquals(10, sequence.revealed(TEXT, 0.5));
    assertEquals(20, sequence.revealed(TEXT, 1));
    // Never past the end of the text.
    assertEquals(TEXT, sequence.revealed(TEXT, 100));
    assertFalse(sequence.isTyping(TEXT, 100));
    assertEquals(20, IntroSequence.TYPE_CHARS_PER_S, 0.001);
  }

  @Test
  public void restartPlaysTheIntroFromTheModal()
  {
    final IntroSequence sequence = new IntroSequence();
    sequence.tap(TEXT, 0);
    sequence.tap(TEXT, TEXT);
    assertEquals(IntroStep.RIGHT, sequence.step());
    sequence.finish();
    assertTrue(sequence.isOver());
    // The How NonGPS works page asks for the intro again: the modal first, and nothing of the last run is left.
    sequence.restart();
    assertEquals(IntroStep.MODAL, sequence.step());
    sequence.tap(TEXT, 0);
    assertEquals(IntroStep.BOTTOM, sequence.step());
    assertTrue(sequence.isTyping(TEXT, 0));
  }

  @Test
  public void tapWhileTypingShowsTheRestAndTheNextTapAdvances()
  {
    final IntroSequence sequence = new IntroSequence();
    sequence.tap(TEXT, 0);
    assertTrue(sequence.isTyping(TEXT, 1));
    sequence.tap(TEXT, 1);
    // The same step, with the whole text: the typewriter is over.
    assertEquals(IntroStep.BOTTOM, sequence.step());
    assertEquals(TEXT, sequence.revealed(TEXT, 1));
    assertFalse(sequence.isTyping(TEXT, 1));
    sequence.tap(TEXT, 1);
    assertEquals(IntroStep.RIGHT, sequence.step());
    // The next step types from the start again.
    assertTrue(sequence.isTyping(TEXT, 1));
  }

  @Test
  public void theLastTapEndsTheIntro()
  {
    final IntroSequence sequence = new IntroSequence();
    for (int i = 0; i < IntroStep.values().length; ++i)
    {
      assertFalse(sequence.isOver());
      sequence.tap(TEXT, TEXT);
    }
    assertTrue(sequence.isOver());
    assertNull(sequence.step());
    // Nothing is shown after it, and a tap changes nothing.
    sequence.tap(TEXT, TEXT);
    assertTrue(sequence.isOver());
    assertEquals(0, sequence.revealed(TEXT, TEXT));
  }

  @Test
  public void navigationFinishesTheIntro()
  {
    final IntroSequence sequence = new IntroSequence();
    sequence.tap(TEXT, 0);
    assertEquals(IntroStep.BOTTOM, sequence.step());
    sequence.finish();
    assertTrue(sequence.isOver());
  }

  @Test
  public void theFlagShowsItOnlyOnce()
  {
    assertTrue(IntroSequence.isNeeded(false, false));
    // The second start of the app.
    assertFalse(IntroSequence.isNeeded(true, false));
    // Not over the navigation, even on the first start.
    assertFalse(IntroSequence.isNeeded(false, true));
    assertFalse(IntroSequence.isNeeded(true, true));
  }

  @Test
  public void firstStepIsTheModal()
  {
    assertEquals(IntroStep.MODAL, IntroStep.first());
    assertEquals(IntroStep.MODAL, new IntroSequence().step());
  }
}
