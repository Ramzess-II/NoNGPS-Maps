package app.organicmaps.sdk.location;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;
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

  // This phone is removed from the box: only the pairing of the box of that car is removed.
  @Test
  public void unpair_takesOnlyTheBoxOfTheCar()
  {
    assertTrue(Esp32BleTransport.isBoxOf("NoGPS-C47D", "C47D"));
    assertFalse(Esp32BleTransport.isBoxOf("NoGPS-A1B2", "C47D"));
    assertFalse(Esp32BleTransport.isBoxOf("ELM327", "C47D"));
    assertFalse(Esp32BleTransport.isBoxOf(null, "C47D"));
  }

  @Test
  public void boxOfNoCar_isSkippedAtTheLimitOfCars()
  {
    final Set<String> cars = new HashSet<>(Arrays.asList("A", "B", "C", "D"));
    assertTrue(Esp32BleTransport.isOverCarLimit(cars, 4, "E"));
    assertTrue(Esp32BleTransport.isOverCarLimit(cars, 4, null));
    assertFalse(Esp32BleTransport.isOverCarLimit(cars, 4, "C"));
    cars.remove("D");
    assertFalse(Esp32BleTransport.isOverCarLimit(cars, 4, "E"));
  }
}
