package app.organicmaps.sdk.location;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class Esp32BleTransportTest
{
  // The user forgot the last car and opens the Box sheet: its box, still paired, doesn't come back by itself.
  @Test
  public void forgottenBox_waitsForItsPairingWindow()
  {
    assertTrue(Esp32BleTransport.needsPairingWindow(true /* bonded */, true /* forgotten */, false /* newBoxOnly */));
  }

  @Test
  public void forgottenBox_isTakenWhenTheUserAddsACar()
  {
    assertFalse(Esp32BleTransport.needsPairingWindow(true /* bonded */, true /* forgotten */, true /* newBoxOnly */));
  }

  @Test
  public void pairedBox_isTakenAtOnce_newOneInItsPairingWindow()
  {
    assertFalse(Esp32BleTransport.needsPairingWindow(true /* bonded */, false /* forgotten */, false /* newBoxOnly */));
    assertTrue(Esp32BleTransport.needsPairingWindow(false /* bonded */, false /* forgotten */, false /* newBoxOnly */));
    assertTrue(Esp32BleTransport.needsPairingWindow(false /* bonded */, false /* forgotten */, true /* newBoxOnly */));
  }
}
