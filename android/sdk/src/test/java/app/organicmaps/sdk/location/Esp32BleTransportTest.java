package app.organicmaps.sdk.location;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import android.bluetooth.BluetoothDevice;
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
    assertTrue(Esp32BleTransport.isBoxOf("NonGPS-C47D", "C47D"));
    assertFalse(Esp32BleTransport.isBoxOf("NoGPS-C47D", "C47D"));
    assertFalse(Esp32BleTransport.isBoxOf("NonGPS-A1B2", "C47D"));
    assertFalse(Esp32BleTransport.isBoxOf("ELM327", "C47D"));
    assertFalse(Esp32BleTransport.isBoxOf(null, "C47D"));
  }

  // A box of the firmware the application drives is NonGPS-XXXX.
  @Test
  public void boxId_isTakenFromTheName()
  {
    assertEquals("C47D", Esp32BleTransport.boxIdOfName("NonGPS-C47D"));
    assertNull(Esp32BleTransport.boxIdOfName("NoGPS-C47D"));
    assertNull(Esp32BleTransport.boxIdOfName("ELM327"));
    assertNull(Esp32BleTransport.boxIdOfName(null));
  }

  // BLE-13, version 2: the version, the flags and the four characters of the id; a box seen without its name has them.
  @Test
  public void boxId_isTakenFromTheManufacturerData()
  {
    assertEquals("C47D", Esp32BleTransport.boxIdOfManufacturerData(new byte[] {2, 1, 'C', '4', '7', 'D'}));
    assertEquals("42FD", Esp32BleTransport.boxIdOfManufacturerData(new byte[] {2, 5, '4', '2', 'F', 'D', 9}));
    // Version 1 had no id, a short or a broken record has none.
    assertNull(Esp32BleTransport.boxIdOfManufacturerData(new byte[] {1, 1}));
    assertNull(Esp32BleTransport.boxIdOfManufacturerData(new byte[] {1, 1, 'C', '4', '7', 'D'}));
    assertNull(Esp32BleTransport.boxIdOfManufacturerData(new byte[] {2, 1, 'C', '4', '7'}));
    assertNull(Esp32BleTransport.boxIdOfManufacturerData(new byte[] {2, 1, 'C', '4', 0, 'D'}));
    assertNull(Esp32BleTransport.boxIdOfManufacturerData(new byte[] {2, 1, 'C', '4', '-', 'D'}));
    assertNull(Esp32BleTransport.boxIdOfManufacturerData(null));
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

  private static Esp32BleTransport.ConnectionEnd end(boolean heard, boolean bonded, long linkedMs, int silent,
                                                     long sinceMs, boolean lost, long delayMs)
  {
    return Esp32BleTransport.afterConnection(heard, bonded, false /* worked */, linkedMs, silent, sinceMs, lost,
                                             delayMs);
  }

  @Test
  public void sixthSilentConnection_givesTheHintAndSearchesOnceAMinute()
  {
    final Esp32BleTransport.ConnectionEnd fifth = end(false, true, 4000, 4, 10_000, false, 2000);
    assertEquals(5, fifth.silentConnections);
    assertFalse(fifth.bondLost);
    assertEquals(4000, fifth.retryDelayMs);
    final Esp32BleTransport.ConnectionEnd sixth = end(false, true, 4000, 5, 10_000, false, 2000);
    assertEquals(6, sixth.silentConnections);
    assertTrue(sixth.bondLost);
    assertEquals(60_000, sixth.retryDelayMs);
    // Still silent: the hint stays, the search goes on.
    final Esp32BleTransport.ConnectionEnd seventh = end(false, true, 4000, 6, 10_000, true, 60_000);
    assertTrue(seventh.bondLost);
    assertEquals(60_000, seventh.retryDelayMs);
  }

  @Test
  public void heardConnection_isNotSilent()
  {
    final Esp32BleTransport.ConnectionEnd result =
        Esp32BleTransport.afterConnection(true, true, true /* worked */, 4000, 3, 10_000, true, 60_000);
    assertFalse(result.silent);
    assertEquals(2000, result.retryDelayMs);
  }

  @Test
  public void shortOrUnpairedConnection_isNotCounted()
  {
    assertFalse(end(false, true, 2999, 2, 10_000, false, 2000).silent);
    assertFalse(end(false, true, -1, 2, 10_000, false, 2000).silent);
    assertFalse(end(false, false, 4000, 2, 10_000, false, 2000).silent);
    assertEquals(2, end(false, true, 2999, 2, 10_000, false, 2000).silentConnections);
  }

  @Test
  public void silentConnectionsFarApart_startAgain()
  {
    final Esp32BleTransport.ConnectionEnd result = end(false, true, 4000, 5, 180_001, false, 2000);
    assertEquals(1, result.silentConnections);
    assertFalse(result.bondLost);
  }

  // The box slept for more than 3 min and is still silent: the count starts again, the hint stays.
  @Test
  public void theHintStaysThroughAGapWithoutData()
  {
    final Esp32BleTransport.ConnectionEnd result = end(false, true, 4000, 6, 180_001, true, 60_000);
    assertEquals(1, result.silentConnections);
    assertTrue(result.bondLost);
    assertEquals(60_000, result.retryDelayMs);
  }

  @Test
  public void bondingSeenLate_switchesToPairing()
  {
    assertTrue(Esp32BleTransport.missedBonding(Esp32BleTransport.STATE_CONNECTING, BluetoothDevice.BOND_BONDING));
    assertTrue(Esp32BleTransport.missedBonding(Esp32BleTransport.STATE_CONNECTED, BluetoothDevice.BOND_BONDING));
    assertFalse(Esp32BleTransport.missedBonding(Esp32BleTransport.STATE_PAIRING, BluetoothDevice.BOND_BONDING));
    assertFalse(Esp32BleTransport.missedBonding(Esp32BleTransport.STATE_CONNECTING, BluetoothDevice.BOND_NONE));
    assertFalse(Esp32BleTransport.missedBonding(Esp32BleTransport.STATE_CONNECTING, BluetoothDevice.BOND_BONDED));
  }

  @Test
  public void bytesOfADeviceThatIsNotPaired_areDropped()
  {
    assertTrue(Esp32BleTransport.takesLines(BluetoothDevice.BOND_BONDED, false));
    assertFalse(Esp32BleTransport.takesLines(BluetoothDevice.BOND_BONDING, false));
    assertFalse(Esp32BleTransport.takesLines(BluetoothDevice.BOND_NONE, false));
  }

  // A debug build talks to the box simulator, which asks for no pairing: a computer is never bonded.
  @Test
  public void linesOfTheBoxSimulator_areTaken()
  {
    assertTrue(Esp32BleTransport.takesLines(BluetoothDevice.BOND_NONE, true));
  }

  // The simulator advertises the manufacturer data on Linux and none on macOS: the pairing tells it apart, not them.
  @Test
  public void anUnpairedDeviceOfADebugBuild_isTheSimulator()
  {
    assertTrue(Esp32BleTransport.isSimulator(true, false));
    assertFalse(Esp32BleTransport.isSimulator(true, true));
    assertFalse(Esp32BleTransport.isSimulator(false, false));
  }

  // The hint is shown and a search connection of the box is subscribed, so the state is Connected: the pairing
  // removed in the settings still starts the search at once.
  @Test
  public void theRemovedPairingOfTheLostBox_searchesAtOnce()
  {
    assertTrue(Esp32BleTransport.removedLostBond(true, BluetoothDevice.BOND_NONE, true));
    assertFalse(Esp32BleTransport.removedLostBond(false, BluetoothDevice.BOND_NONE, true));
    assertFalse(Esp32BleTransport.removedLostBond(true, BluetoothDevice.BOND_NONE, false));
    assertFalse(Esp32BleTransport.removedLostBond(true, BluetoothDevice.BOND_BONDED, true));
  }

  @Test
  public void foundBox_isTakenAsBefore()
  {
    assertEquals(Esp32BleTransport.FoundBox.CONNECT, Esp32BleTransport.foundBox(true, false, false, false, false, 0));
    assertEquals(Esp32BleTransport.FoundBox.SKIP, Esp32BleTransport.foundBox(false, false, false, false, false, 0));
    assertEquals(Esp32BleTransport.FoundBox.WAIT, Esp32BleTransport.foundBox(false, false, false, true, true, 2999));
    assertEquals(Esp32BleTransport.FoundBox.CONNECT, Esp32BleTransport.foundBox(false, false, false, true, true, 3000));
    assertEquals(Esp32BleTransport.FoundBox.CONNECT, Esp32BleTransport.foundBox(false, false, true, true, true, 0));
  }

  @Test
  public void waitsForBox_onlyForPairedBoxThatKnowsThePhone()
  {
    final long longAgo = 10 * 60_000;
    assertTrue(Esp32BleTransport.waitsForBox(true /* hasBox */, false /* bondLost */, false /* waiting */, longAgo));
    assertFalse(Esp32BleTransport.waitsForBox(false /* hasBox */, false /* bondLost */, false /* waiting */, longAgo));
    assertFalse(Esp32BleTransport.waitsForBox(true /* hasBox */, true /* bondLost */, false /* waiting */, longAgo));
    assertFalse(Esp32BleTransport.waitsForBox(true /* hasBox */, false /* bondLost */, true /* waiting */, longAgo));
  }

  @Test
  public void waitsForBox_notRightAfterAWake()
  {
    assertFalse(Esp32BleTransport.waitsForBox(true /* hasBox */, false /* bondLost */, false /* waiting */, 20_000));
  }
}
