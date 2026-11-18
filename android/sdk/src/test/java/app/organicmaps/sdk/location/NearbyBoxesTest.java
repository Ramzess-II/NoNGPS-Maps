package app.organicmaps.sdk.location;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class NearbyBoxesTest
{
  @Test
  public void unseenBox_isNotNearby()
  {
    assertFalse(new NearbyBoxes().isNearby("C47D", 1000));
  }

  @Test
  public void boxSeenInTheLastMinute_isNearby()
  {
    final NearbyBoxes boxes = new NearbyBoxes();
    boxes.onSeen("C47D", 1000);
    assertTrue(boxes.isNearby("C47D", 1000 + NearbyBoxes.TIMEOUT_MS));
    assertFalse(boxes.isNearby("C47D", 1000 + NearbyBoxes.TIMEOUT_MS + 1));
    assertFalse(boxes.isNearby("AAAA", 1000));
  }

  @Test
  public void seenAgain_extendsTheTime()
  {
    final NearbyBoxes boxes = new NearbyBoxes();
    boxes.onSeen("C47D", 0);
    boxes.onSeen("C47D", 50_000);
    assertTrue(boxes.isNearby("C47D", 100_000));
  }

  @Test
  public void clear_forgetsBoxes()
  {
    final NearbyBoxes boxes = new NearbyBoxes();
    boxes.onSeen("C47D", 0);
    boxes.clear();
    assertFalse(boxes.isNearby("C47D", 1));
  }
}
