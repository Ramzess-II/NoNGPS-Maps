package app.organicmaps.sdk.location;

import android.Manifest;
import android.annotation.SuppressLint;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.BluetoothStatusCodes;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanFilter;
import android.bluetooth.le.ScanRecord;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.location.LocationManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelUuid;
import android.os.SystemClock;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.UiThread;
import androidx.annotation.VisibleForTesting;
import androidx.core.content.ContextCompat;
import app.organicmaps.sdk.util.log.Logger;
import java.util.ArrayDeque;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;

/**
 * The Bluetooth LE connection to the NoGPS ESP32 sensor box for the navigation without GPS in the core: the core
 * talks to the box, this class searches the box by its service, connects, subscribes to its lines and passes the
 * received bytes back on the UI thread. It keeps doing it until closed: the box switches its radio off while the
 * car is parked. The service and the pairing are described in docs/nogps/esp32-firmware-spec.md, section 17.
 */
class Esp32BleTransport
{
  // nogps::BleState.
  static final int STATE_OFF = 0;
  static final int STATE_NO_PERMISSION = 1;
  static final int STATE_DISABLED = 2;
  static final int STATE_SEARCHING = 3;
  static final int STATE_PAIRING_CLOSED = 4;
  static final int STATE_CONNECTING = 5;
  static final int STATE_PAIRING = 6;
  static final int STATE_CONNECTED = 7;
  static final int STATE_PAIRING_FAILED = 8;
  static final int STATE_BOND_LOST = 9;
  static final int STATE_PAIRING_BY_PHONE = 10;
  static final int STATE_PAIRING_FULL = 11;
  static final int STATE_CAR_LIMIT = 12;

  private static final String TAG = Esp32BleTransport.class.getSimpleName();
  private static final UUID SERVICE = UUID.fromString("02CB0001-C0C3-40D0-819C-5A85998DCD99");
  // The lines of the box, notified.
  private static final UUID TX = UUID.fromString("02CB0002-C0C3-40D0-819C-5A85998DCD99");
  // The commands to the box.
  private static final UUID RX = UUID.fromString("02CB0003-C0C3-40D0-819C-5A85998DCD99");
  // The pieces of a new firmware of the box, section 18 of the same document.
  private static final UUID OTA = UUID.fromString("02CB0004-C0C3-40D0-819C-5A85998DCD99");
  private static final UUID CLIENT_CONFIG = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB");
  private static final String NAME_PREFIX = "NoGPS-";
  // The box tells in its advertisement if it accepts a new phone now: company, format version 1, flags.
  private static final int MANUFACTURER_ID = 0xFFFF;
  private static final int FLAG_PAIRING_OPEN = 1;
  private static final int FLAG_FULL = 1 << 1;
  private static final int FLAG_HAS_PHONES = 1 << 2;
  // A line of the box fits a notification with it, the default of 23 has no room even for a command.
  private static final int MTU = 247;
  private static final long RETRY_DELAY_MS = 2000;
  // A box that is found but drops the connection again and again is tried less and less often.
  private static final long MAX_RETRY_DELAY_MS = 60_000;
  // Android turns a scan lasting half an hour into one that finds nothing, so it is started anew.
  private static final long RESCAN_INTERVAL_MS = 5 * 60 * 1000;
  // A new box waits this long for a paired one to be found: both may be near.
  private static final long NEW_BOX_DELAY_MS = 3000;
  // The box of another car waits this long for the box of the current car: both may be near, e.g. two cars in the
  // yard with their engines just stopped.
  private static final long OTHER_CAR_DELAY_MS = 3000;
  // The boxes of the cars the user has forgotten: still paired, they are not connected until the user adds the car.
  private static final String PREFS = "nogps_box";
  private static final String FORGOTTEN_BOXES = "forgotten_boxes";
  // From the connection to the first data: a step may wait for a callback that never comes.
  private static final long CONNECT_WATCHDOG_MS = 20_000;
  // The user enters the code meanwhile.
  private static final long PAIRING_WATCHDOG_MS = 60_000;
  // The box tells in every advertisement that it doesn't accept a new phone. Without them it has gone, e.g. it was a
  // box of the neighbours.
  private static final long PAIRING_CLOSED_TIMEOUT_MS = 10_000;
  // A paired box that connects but sends nothing again and again has forgotten the phone (BLE-15). After a parking
  // up to 3 connections in a row stay silent, the next one works (#154).
  private static final int MAX_SILENT_CONNECTIONS = 6;
  // Silent connections further apart are not counted together: the box has slept in between.
  private static final long SILENT_CONNECTIONS_GAP_MS = 3 * 60 * 1000;
  // A shorter connection was lost by the radio, it is not counted: the box asks for the encryption 1.5 s after the
  // connection, a refused one lasts longer.
  private static final long MIN_SILENT_LINK_MS = 3000;
  // The box doesn't answer the commands, a few of them wait for the previous one to leave at most.
  private static final int MAX_OUTGOING = 16;
  // The box takes the pieces of a firmware 4096 bytes ahead of what it has written: 17 pieces.
  private static final int MAX_FIRMWARE_PIECES = 64;
  private static final long WRITE_RETRY_MS = 20;

  @NonNull
  private final Context mContext;
  private final Handler mMainHandler = new Handler(Looper.getMainLooper());
  private boolean mOpen;
  private int mState = STATE_OFF;
  @Nullable
  private BluetoothLeScanner mScanner;
  @Nullable
  private ScanCallback mScanCallback;
  private long mScanStartMs;
  @Nullable
  private BluetoothGatt mGatt;
  @Nullable
  private BluetoothGattCharacteristic mRx;
  // A box with an old firmware has none.
  @Nullable
  private BluetoothGattCharacteristic mOta;
  // Subscribed to the lines of the box.
  private boolean mReady;
  private int mMtu = 23;
  private final ArrayDeque<byte[]> mOutgoing = new ArrayDeque<>();
  // The pieces of a firmware go after the lines: a line a second keeps the connection with the box.
  private final ArrayDeque<byte[]> mFirmware = new ArrayDeque<>();
  private boolean mWriting;
  private final Runnable mWriter = this::writeNext;
  private long mRetryDelayMs = RETRY_DELAY_MS;
  private final Runnable mStarter = this::start;
  private final Runnable mWatchdog = this::onWatchdog;
  private final Runnable mPairingClosedEnd = () ->
  {
    if (mState == STATE_PAIRING_CLOSED || mState == STATE_PAIRING_BY_PHONE || mState == STATE_PAIRING_FULL
        || mState == STATE_CAR_LIMIT)
      setState(searchState());
  };
  // The box was paired when it was found.
  private boolean mBonded;
  // When the connection was made, -1 before.
  private long mLinkedMs = -1;
  // The box has sent data over the connection.
  private boolean mHeard;
  // Silent connections to a paired box in a row, the last one ended at mLastSilentMs.
  private int mSilentConnections;
  private long mLastSilentMs;
  // Too many silent connections: the lost-pairing hint is shown, and the search goes on once a minute.
  private boolean mBondLost;
  // The box that has forgotten the phone: the search starts again when its pairing is removed.
  @Nullable
  private BluetoothDevice mBondLostBox;
  // The user adds a car: only a box that is not of a known car is connected.
  private boolean mNewBoxOnly;
  // The cars and the current one, as the search starts.
  private final Set<String> mCarIds = new HashSet<>();
  // The boxes seen in the scan, also while one is connected: the Box sheet offers a car whose box is awake.
  private final NearbyBoxes mNearbyBoxes = new NearbyBoxes();
  @NonNull
  private String mCurrentCar = "";
  // The box connected, null if its name is not known.
  @Nullable
  private String mBoxId;

  private final BroadcastReceiver mReceiver = new BroadcastReceiver() {
    @Override
    public void onReceive(Context context, Intent intent)
    {
      if (BluetoothAdapter.ACTION_STATE_CHANGED.equals(intent.getAction()))
        onAdapterStateChanged(intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR));
      else if (BluetoothDevice.ACTION_BOND_STATE_CHANGED.equals(intent.getAction()))
        onBondStateChanged(intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE),
                           intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR),
                           intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, BluetoothDevice.ERROR));
      else if (LocationManager.MODE_CHANGED_ACTION.equals(intent.getAction()))
        onLocationModeChanged();
    }
  };

  Esp32BleTransport(@NonNull Context context)
  {
    mContext = context;
  }

  @UiThread
  void open()
  {
    close();
    mOpen = true;
    mRetryDelayMs = RETRY_DELAY_MS;
    mSilentConnections = 0;
    mBondLost = false;
    final IntentFilter filter = new IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED);
    filter.addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED);
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S)
      filter.addAction(LocationManager.MODE_CHANGED_ACTION);
    ContextCompat.registerReceiver(mContext, mReceiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED);
    start();
  }

  @UiThread
  void send(@NonNull byte[] line)
  {
    if (!mReady)
      return;
    if (line.length > mMtu - 3)
    {
      Logger.w(TAG, "A line of " + line.length + " bytes doesn't fit MTU " + mMtu);
      return;
    }
    if (mOutgoing.size() >= MAX_OUTGOING)
      mOutgoing.poll();
    mOutgoing.add(line);
    writeNext();
  }

  /**
   * A piece of a new firmware of the box. A piece that doesn't fit is dropped: the box tells where it has
   * stopped, and the core sends from there again.
   */
  @UiThread
  void sendFirmware(@NonNull byte[] piece)
  {
    if (!mReady || mOta == null || piece.length > mMtu - 3 || mFirmware.size() >= MAX_FIRMWARE_PIECES)
      return;
    mFirmware.add(piece);
    writeNext();
  }

  /**
   * The user asks to look for the box again after a failed pairing or a lost bond, which stop the search.
   */
  @UiThread
  void retry()
  {
    if (!mOpen || mGatt != null)
      return;
    mRetryDelayMs = RETRY_DELAY_MS;
    mSilentConnections = 0;
    mBondLost = false;
    start();
  }

  /**
   * The user adds a car: only a box that is not of a known car is connected, the box connected now is dropped. Ends
   * when the new box is heard, or with false.
   */
  @UiThread
  void searchNewBox(boolean newOnly)
  {
    if (mNewBoxOnly == newOnly)
      return;
    Logger.i(TAG, "new box only = " + newOnly);
    mNewBoxOnly = newOnly;
    if (!mOpen)
      return;
    closeGatt();
    mRetryDelayMs = RETRY_DELAY_MS;
    mSilentConnections = 0;
    mBondLost = false;
    start();
  }

  /**
   * The user has forgotten the car: its box, still paired, is not connected until the car is added again.
   */
  @UiThread
  void forgetBox(@NonNull String id)
  {
    final Set<String> forgotten = getForgottenBoxes();
    if (forgotten.add(id))
      getPrefs().edit().putStringSet(FORGOTTEN_BOXES, forgotten).apply();
  }

  /**
   * The box has erased this phone: the old system pairing only blocks the next connection. removeBond() is hidden:
   * it works on many phones, a newer Android may block it.
   * @return false if the pairing of the box is still there.
   */
  @UiThread
  @SuppressLint("MissingPermission")
  boolean unpairBox(@NonNull String id)
  {
    final BluetoothManager manager = (BluetoothManager) mContext.getSystemService(Context.BLUETOOTH_SERVICE);
    final BluetoothAdapter adapter = manager != null ? manager.getAdapter() : null;
    if (adapter == null || !hasPermission())
      return false;
    boolean removed = true;
    try
    {
      for (BluetoothDevice device : adapter.getBondedDevices())
      {
        if (!isBoxOf(device.getName(), id))
          continue;
        removed &= Boolean.TRUE.equals(BluetoothDevice.class.getMethod("removeBond").invoke(device));
      }
    }
    catch (ReflectiveOperationException | RuntimeException e)
    {
      Logger.w(TAG, "Cannot remove the pairing of the box " + id + ": " + e);
      return false;
    }
    return removed;
  }

  static boolean isBoxOf(@Nullable String deviceName, @NonNull String id)
  {
    return (NAME_PREFIX + id).equals(deviceName);
  }

  /**
   * @return true if the box of the car was seen in the scan in the last minute, other than the connected one: it
   * doesn't advertise.
   */
  @UiThread
  boolean isBoxNearby(@NonNull String id)
  {
    return mOpen && !id.equals(mBoxId) && mNearbyBoxes.isNearby(id, SystemClock.elapsedRealtime());
  }

  @UiThread
  void close()
  {
    if (!mOpen)
      return;
    mOpen = false;
    mNearbyBoxes.clear();
    mMainHandler.removeCallbacks(mStarter);
    mMainHandler.removeCallbacks(mPairingClosedEnd);
    mContext.unregisterReceiver(mReceiver);
    stopScan();
    closeGatt();
    mState = STATE_OFF;
  }

  private boolean hasPermission()
  {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
      return isGranted(Manifest.permission.BLUETOOTH_SCAN) && isGranted(Manifest.permission.BLUETOOTH_CONNECT);
    // A scan needs the location permission before Android 12.
    return isGranted(Manifest.permission.ACCESS_FINE_LOCATION);
  }

  private boolean isGranted(@NonNull String permission)
  {
    return ContextCompat.checkSelfPermission(mContext, permission) == PackageManager.PERMISSION_GRANTED;
  }

  private void setState(int state)
  {
    if (state == mState)
      return;
    Logger.i(TAG, "state = " + state);
    mState = state;
    NoGps.nativeOnEsp32BleState(state);
  }

  /**
   * Searches the box, or waits until it can be searched.
   */
  @SuppressLint("MissingPermission") // Checked by hasPermission().
  private void start()
  {
    mMainHandler.removeCallbacks(mStarter);
    if (!mOpen)
      return;
    if (mGatt != null)
    {
      // Android turns a long scan into one that finds nothing, as below.
      startNearbyScan();
      return;
    }
    stopScan();
    final BluetoothManager manager = (BluetoothManager) mContext.getSystemService(Context.BLUETOOTH_SERVICE);
    final BluetoothAdapter adapter = manager != null ? manager.getAdapter() : null;
    if (adapter == null || !mContext.getPackageManager().hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE))
    {
      setState(STATE_OFF);
      return;
    }
    if (!hasPermission())
    {
      // The user is asked for it by the sensors screen, nobody tells when it is given.
      setState(STATE_NO_PERMISSION);
      mMainHandler.postDelayed(mStarter, RETRY_DELAY_MS);
      return;
    }
    // Before Bluetooth, as the Box sheet tells it. MODE_CHANGED_ACTION tells when it is switched on.
    if (NoGps.isLocationOffForBox(mContext))
    {
      setState(STATE_DISABLED);
      return;
    }
    final BluetoothLeScanner scanner = adapter.isEnabled() ? adapter.getBluetoothLeScanner() : null;
    if (scanner == null)
    {
      // ACTION_STATE_CHANGED tells when it is switched on.
      setState(STATE_DISABLED);
      return;
    }

    final ScanCallback callback = new ScanCallback() {
      @Override
      public void onScanResult(int callbackType, ScanResult result)
      {
        if (this != mScanCallback)
          return;
        final String id = getBoxId(result);
        if (id != null)
          mNearbyBoxes.onSeen(id, SystemClock.elapsedRealtime());
        onBoxFound(adapter, result);
      }

      @Override
      public void onScanFailed(int errorCode)
      {
        Logger.w(TAG, "Scan failed: " + errorCode);
        if (this != mScanCallback)
          return;
        mScanCallback = null;
        mMainHandler.postDelayed(mStarter, RETRY_DELAY_MS);
      }
    };
    final ScanFilter filter = new ScanFilter.Builder().setServiceUuid(new ParcelUuid(SERVICE)).build();
    final ScanSettings settings = new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build();
    try
    {
      scanner.startScan(Collections.singletonList(filter), settings, callback);
    }
    catch (SecurityException | IllegalStateException e)
    {
      Logger.w(TAG, "Can't scan: " + e.getMessage());
      mMainHandler.postDelayed(mStarter, RETRY_DELAY_MS);
      return;
    }
    mScanner = scanner;
    mScanCallback = callback;
    mScanStartMs = SystemClock.elapsedRealtime();
    mCarIds.clear();
    for (NoGps.Car car : NoGps.nativeGetCars())
      mCarIds.add(car.id);
    mCurrentCar = NoGps.getStatus().carId;
    setState(searchState());
    mMainHandler.postDelayed(mStarter, RESCAN_INTERVAL_MS);
  }

  /**
   * Keeps looking for the boxes of the other cars while one is connected, slowly: they are not connected, only seen.
   */
  @SuppressLint("MissingPermission")
  private void startNearbyScan()
  {
    stopScan();
    final BluetoothManager manager = (BluetoothManager) mContext.getSystemService(Context.BLUETOOTH_SERVICE);
    final BluetoothAdapter adapter = manager != null ? manager.getAdapter() : null;
    final BluetoothLeScanner scanner =
        adapter != null && adapter.isEnabled() && hasPermission() ? adapter.getBluetoothLeScanner() : null;
    if (scanner == null)
      return;
    final ScanCallback callback = new ScanCallback() {
      @Override
      public void onScanResult(int callbackType, ScanResult result)
      {
        final String id = this == mScanCallback ? getBoxId(result) : null;
        if (id != null)
          mNearbyBoxes.onSeen(id, SystemClock.elapsedRealtime());
      }
    };
    final ScanFilter filter = new ScanFilter.Builder().setServiceUuid(new ParcelUuid(SERVICE)).build();
    final ScanSettings settings = new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_POWER).build();
    try
    {
      scanner.startScan(Collections.singletonList(filter), settings, callback);
    }
    catch (SecurityException | IllegalStateException e)
    {
      Logger.w(TAG, "Can't scan for the nearby boxes: " + e.getMessage());
      return;
    }
    mScanner = scanner;
    mScanCallback = callback;
    mMainHandler.postDelayed(mStarter, RESCAN_INTERVAL_MS);
  }

  @SuppressLint("MissingPermission")
  private void stopScan()
  {
    final BluetoothLeScanner scanner = mScanner;
    final ScanCallback callback = mScanCallback;
    mScanner = null;
    mScanCallback = null;
    if (scanner == null || callback == null)
      return;
    try
    {
      scanner.stopScan(callback);
    }
    catch (SecurityException | IllegalStateException e)
    {
      // Bluetooth has been switched off or the permission is taken back: the scan is over anyway.
      Logger.w(TAG, "Can't stop the scan: " + e.getMessage());
    }
  }

  @SuppressLint("MissingPermission")
  private void onBoxFound(@NonNull BluetoothAdapter adapter, @NonNull ScanResult result)
  {
    if (mGatt != null)
      return;
    final BluetoothDevice device = result.getDevice();
    final boolean bonded = device.getBondState() == BluetoothDevice.BOND_BONDED;
    final String id = getBoxId(result);
    // A paired box without its name may be of a car: not while a new one is added.
    if (id != null ? isOverCarLimit(id) : !bonded && isOverCarLimit(null))
    {
      // Told while its advertisements come, as for a box that takes no new phone.
      setState(STATE_CAR_LIMIT);
      mMainHandler.removeCallbacks(mPairingClosedEnd);
      mMainHandler.postDelayed(mPairingClosedEnd, PAIRING_CLOSED_TIMEOUT_MS);
      return;
    }
    if (id != null ? !isBoxWanted(id, bonded) : mNewBoxOnly && bonded)
      return;
    final boolean forgotten = id != null && getForgottenBoxes().contains(id);
    final ScanRecord record = result.getScanRecord();
    final byte[] data = record != null ? record.getManufacturerSpecificData(MANUFACTURER_ID) : null;
    final int flags = data != null && data.length >= 2 ? data[1] : 0;
    final boolean pairingOpen = (flags & FLAG_PAIRING_OPEN) != 0;
    final FoundBox found = foundBox(bonded, forgotten, mNewBoxOnly, pairingOpen,
                                    needsPairingWindow(bonded, forgotten, mNewBoxOnly) && hasPairedBox(adapter),
                                    SystemClock.elapsedRealtime() - mScanStartMs);
    if (found == FoundBox.WAIT)
      return;
    if (found == FoundBox.SKIP)
    {
      // A box accepts a new phone for two minutes after it is powered, if it has no phones, or after a paired phone
      // has let it. The phone asks for the code. The box of a forgotten car still knows this phone: powered on again,
      // it takes it back.
      setState(forgotten                        ? STATE_PAIRING_CLOSED
               : (flags & FLAG_FULL) != 0       ? STATE_PAIRING_FULL
               : (flags & FLAG_HAS_PHONES) != 0 ? STATE_PAIRING_BY_PHONE
                                                : STATE_PAIRING_CLOSED);
      mMainHandler.removeCallbacks(mPairingClosedEnd);
      mMainHandler.postDelayed(mPairingClosedEnd, PAIRING_CLOSED_TIMEOUT_MS);
      return;
    }
    Logger.i(TAG, "Found " + device.getAddress() + " " + id + " rssi " + result.getRssi() + " bonded " + bonded);
    mBoxId = id;
    mMainHandler.removeCallbacks(mStarter);
    mMainHandler.removeCallbacks(mPairingClosedEnd);
    stopScan();
    // The lost-pairing hint stays while the search goes on.
    if (!mBondLost)
      setState(STATE_CONNECTING);
    mMtu = 23;
    mBonded = bonded;
    mLinkedMs = -1;
    mHeard = false;
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
      mGatt = device.connectGatt(mContext, false, mGattCallback, BluetoothDevice.TRANSPORT_LE);
    else
      mGatt = device.connectGatt(mContext, false, mGattCallback);
    if (mGatt == null)
      restartLater();
    else
      startWatchdog(CONNECT_WATCHDOG_MS);
  }

  /**
   * A box that is not paired is connected only while it accepts a new phone. A forgotten one, still paired, too: the
   * user forgot its car, and only setting the box up again brings the car back, as on iOS. Adding a car takes it at
   * once.
   */
  @VisibleForTesting
  static boolean needsPairingWindow(boolean bonded, boolean forgotten, boolean newBoxOnly)
  {
    return !bonded || (forgotten && !newBoxOnly);
  }

  enum FoundBox
  {
    CONNECT,
    // A paired box is near: the new one waits for it.
    WAIT,
    // Not connected: the hint of its flags.
    SKIP
  }

  /**
   * Whether a box that is found is connected. The lines of a box that is not paired are taken only while it accepts a
   * new phone, and only after the pairing, see takesLines().
   */
  @VisibleForTesting
  static FoundBox foundBox(boolean bonded, boolean forgotten, boolean newBoxOnly, boolean pairingOpen,
                           boolean hasPairedBox, long sinceScanStartMs)
  {
    if (!needsPairingWindow(bonded, forgotten, newBoxOnly))
      return FoundBox.CONNECT;
    if (!pairingOpen)
      return FoundBox.SKIP;
    // A box paired already is taken first if it is near: the new one may be somebody else's. Without it the new box is
    // a second or a replaced one of the user.
    return !newBoxOnly && !forgotten && hasPairedBox && sinceScanStartMs < NEW_BOX_DELAY_MS ? FoundBox.WAIT
                                                                                            : FoundBox.CONNECT;
  }

  /**
   * The subscription needs no encryption: bytes of a device that is not paired in the system may be a fake box's or a
   * neighbour's.
   */
  @VisibleForTesting
  static boolean takesLines(int bondState)
  {
    return bondState == BluetoothDevice.BOND_BONDED;
  }

  /**
   * What follows a connection that ended.
   */
  @VisibleForTesting
  static final class ConnectionEnd
  {
    // The connection to a paired box lasted but gave no data.
    boolean silent;
    int silentConnections;
    // Six silent connections in a row: the hint is shown, the search goes on.
    boolean bondLost;
    long retryDelayMs;
  }

  /**
   * A silent connection is not a proof of a lost bond (#154), so the search goes on once a minute after the hint.
   * @param linkedMs how long the connection lasted, -1 if it was not made.
   */
  @VisibleForTesting
  static ConnectionEnd afterConnection(boolean heard, boolean bonded, boolean worked, long linkedMs,
                                       int silentConnections, long sinceLastSilentMs, boolean bondLost,
                                       long retryDelayMs)
  {
    final ConnectionEnd end = new ConnectionEnd();
    end.silentConnections = silentConnections;
    end.bondLost = bondLost;
    end.retryDelayMs = worked ? RETRY_DELAY_MS : Math.min(MAX_RETRY_DELAY_MS, retryDelayMs * 2);
    if (!bonded || heard || linkedMs < MIN_SILENT_LINK_MS)
      return end;
    final boolean inRow = silentConnections > 0 && sinceLastSilentMs <= SILENT_CONNECTIONS_GAP_MS;
    end.silent = true;
    end.silentConnections = inRow ? silentConnections + 1 : 1;
    end.bondLost = end.silentConnections >= MAX_SILENT_CONNECTIONS;
    if (end.bondLost)
      end.retryDelayMs = MAX_RETRY_DELAY_MS;
    return end;
  }

  /**
   * The state while the box is searched: the lost-pairing hint stays until the box is heard.
   */
  private int searchState()
  {
    return mBondLost ? STATE_BOND_LOST : STATE_SEARCHING;
  }

  /**
   * The user has the most cars: a box that is not of one of them (id is null if its name is not known) would drive
   * the mark under the current car's values.
   */
  private boolean isOverCarLimit(@Nullable String id)
  {
    return isOverCarLimit(mCarIds, NoGps.nativeGetMaxCars(), id);
  }

  @VisibleForTesting
  static boolean isOverCarLimit(@NonNull Set<String> carIds, int maxCars, @Nullable String id)
  {
    return carIds.size() >= maxCars && (id == null || !carIds.contains(id));
  }

  /**
   * @return false if the box is not to be connected now: of a known car while the user adds one, forgotten, or of
   *     another car while the box of the current one may be found too.
   */
  private boolean isBoxWanted(@NonNull String id, boolean bonded)
  {
    if (mNewBoxOnly)
      return !mCarIds.contains(id);
    // Without cars the box is set up anew, as any box.
    if (!mCarIds.isEmpty() && getForgottenBoxes().contains(id))
      return false;
    return !bonded || mCurrentCar.isEmpty() || mCurrentCar.equals(id)
 || SystemClock.elapsedRealtime() - mScanStartMs >= OTHER_CAR_DELAY_MS;
  }

  /**
   * @return the four characters of the name of the box, NoGPS-XXXX, null if the box doesn't tell it.
   */
  @SuppressLint("MissingPermission")
  @Nullable
  private static String getBoxId(@NonNull ScanResult result)
  {
    final ScanRecord record = result.getScanRecord();
    String name = record != null ? record.getDeviceName() : null;
    if (name == null)
      name = result.getDevice().getName();
    return name != null && name.startsWith(NAME_PREFIX) ? name.substring(NAME_PREFIX.length()) : null;
  }

  @NonNull
  private SharedPreferences getPrefs()
  {
    return mContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
  }

  @NonNull
  private Set<String> getForgottenBoxes()
  {
    return new HashSet<>(getPrefs().getStringSet(FORGOTTEN_BOXES, Collections.emptySet()));
  }

  private void startWatchdog(long delayMs)
  {
    mMainHandler.removeCallbacks(mWatchdog);
    mMainHandler.postDelayed(mWatchdog, delayMs);
  }

  private void onWatchdog()
  {
    Logger.w(TAG, "No data from the box in time, state " + mState);
    // The user has left the code window: asked again at once, it would come back again and again.
    if (mState == STATE_PAIRING)
      stopUntilRetry(STATE_PAIRING_FAILED);
    else
      restartLater();
  }

  /**
   * The box is not searched until the user asks for it: see retry().
   */
  private void stopUntilRetry(int state)
  {
    closeGatt();
    mMainHandler.removeCallbacks(mStarter);
    setState(state);
  }

  @SuppressLint("MissingPermission")
  private boolean hasPairedBox(@NonNull BluetoothAdapter adapter)
  {
    for (BluetoothDevice device : adapter.getBondedDevices())
    {
      final String name = device.getName();
      if (name != null && name.startsWith(NAME_PREFIX))
        return true;
    }
    return false;
  }

  @SuppressLint("MissingPermission")
  private void closeGatt()
  {
    final BluetoothGatt gatt = mGatt;
    mGatt = null;
    mBoxId = null;
    mRx = null;
    mOta = null;
    mReady = false;
    mWriting = false;
    mOutgoing.clear();
    mFirmware.clear();
    mMainHandler.removeCallbacks(mWriter);
    mMainHandler.removeCallbacks(mWatchdog);
    if (gatt == null)
      return;
    try
    {
      gatt.disconnect();
      gatt.close();
    }
    catch (SecurityException e)
    {
      Logger.w(TAG, "Can't close: " + e.getMessage());
    }
  }

  private void restartLater()
  {
    final long now = SystemClock.elapsedRealtime();
    final ConnectionEnd end = afterConnection(mHeard, mBonded, mReady, mLinkedMs >= 0 ? now - mLinkedMs : -1,
                                              mSilentConnections, now - mLastSilentMs, mBondLost, mRetryDelayMs);
    final BluetoothDevice box = mGatt != null ? mGatt.getDevice() : null;
    closeGatt();
    if (!mOpen)
      return;
    if (end.silent)
      mLastSilentMs = now;
    if (end.bondLost && !mBondLost)
    {
      Logger.w(TAG, "The box has forgotten the phone: " + end.silentConnections + " silent connections");
      mBondLostBox = box;
    }
    mSilentConnections = end.silentConnections;
    mBondLost = end.bondLost;
    mRetryDelayMs = end.retryDelayMs;
    setState(searchState());
    mMainHandler.removeCallbacks(mStarter);
    mMainHandler.postDelayed(mStarter, mRetryDelayMs);
  }

  /**
   * The location is switched on or off: the search waits for it before Android 12. Other changes of the mode don't
   * stop a search.
   */
  private void onLocationModeChanged()
  {
    if (mGatt == null && (mState == STATE_DISABLED || NoGps.isLocationOffForBox(mContext)))
      start();
  }

  private void onAdapterStateChanged(int state)
  {
    if (state == BluetoothAdapter.STATE_ON)
    {
      start();
    }
    else if (state == BluetoothAdapter.STATE_OFF || state == BluetoothAdapter.STATE_TURNING_OFF)
    {
      mMainHandler.removeCallbacks(mStarter);
      mScanner = null;
      mScanCallback = null;
      closeGatt();
      setState(STATE_DISABLED);
    }
  }

  private void onBondStateChanged(@Nullable BluetoothDevice device, int bondState, int previousBondState)
  {
    final BluetoothGatt gatt = mGatt;
    // The user has removed the pairing of the box in the settings, as the hint about a lost bond asks.
    if (mState == STATE_BOND_LOST && bondState == BluetoothDevice.BOND_NONE && device != null
        && device.equals(mBondLostBox))
    {
      // A search connection may be open: it is dropped, the hint stays until retry() starts the search.
      closeGatt();
      retry();
      return;
    }
    if (gatt == null || device == null || !device.equals(gatt.getDevice()))
      return;
    Logger.i(TAG, "bond = " + bondState + " from " + previousBondState);
    if (bondState == BluetoothDevice.BOND_BONDING)
    {
      setState(STATE_PAIRING);
      startWatchdog(PAIRING_WATCHDOG_MS);
    }
    else if (bondState == BluetoothDevice.BOND_BONDED)
    {
      if (!mHeard)
        startWatchdog(CONNECT_WATCHDOG_MS);
      if (mReady)
        setState(STATE_CONNECTED);
      else if (mRx != null)
        subscribe(gatt);
    }
    else if (bondState == BluetoothDevice.BOND_NONE)
    {
      // A wrong code, the user has refused or the box doesn't accept a new phone any more. Asked again at once, the
      // code window would come back every few seconds, and the box refuses for 60 s after 3 failures (BLE-12).
      if (previousBondState == BluetoothDevice.BOND_BONDING)
        stopUntilRetry(STATE_PAIRING_FAILED);
      else
        restartLater();
    }
  }

  private final BluetoothGattCallback mGattCallback = new BluetoothGattCallback() {
    @Override
    public void onConnectionStateChange(BluetoothGatt gatt, int status, int newState)
    {
      mMainHandler.post(() -> onConnection(gatt, status, newState));
    }

    @Override
    public void onMtuChanged(BluetoothGatt gatt, int mtu, int status)
    {
      mMainHandler.post(() -> onMtu(gatt, mtu, status));
    }

    @Override
    public void onServicesDiscovered(BluetoothGatt gatt, int status)
    {
      mMainHandler.post(() -> onServices(gatt, status));
    }

    @Override
    public void onDescriptorWrite(BluetoothGatt gatt, BluetoothGattDescriptor descriptor, int status)
    {
      mMainHandler.post(() -> onSubscribed(gatt, status));
    }

    @Override
    public void onCharacteristicWrite(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic, int status)
    {
      mMainHandler.post(() -> {
        if (gatt != mGatt)
          return;
        mWriting = false;
        writeNext();
      });
    }

    // Before Android 13: the value is read here, another notification may replace it later.
    @Override
    @SuppressWarnings("deprecation")
    public void onCharacteristicChanged(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic)
    {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
        return;
      final byte[] value = characteristic.getValue();
      if (value != null)
        onBytes(gatt, value.clone());
    }

    @Override
    public void onCharacteristicChanged(@NonNull BluetoothGatt gatt,
                                        @NonNull BluetoothGattCharacteristic characteristic, @NonNull byte[] value)
    {
      onBytes(gatt, value);
    }
  };

  private void onBytes(@NonNull BluetoothGatt gatt, @NonNull byte[] value)
  {
    mMainHandler.post(() -> {
      // The bytes of a closed connection are dropped.
      if (gatt != mGatt || !takesLines(gatt.getDevice().getBondState()))
        return;
      if (!mHeard)
      {
        mHeard = true;
        mSilentConnections = 0;
        mBondLost = false;
        mMainHandler.removeCallbacks(mWatchdog);
        onBoxHeard();
      }
      NoGps.nativeOnEsp32BleBytes(value);
    });
  }

  /**
   * The box sends data: a new one ends the search for it, a forgotten one is added again.
   */
  private void onBoxHeard()
  {
    mNewBoxOnly = false;
    final Set<String> forgotten = getForgottenBoxes();
    if (mBoxId != null && forgotten.remove(mBoxId))
      getPrefs().edit().putStringSet(FORGOTTEN_BOXES, forgotten).apply();
    startNearbyScan();
  }

  @SuppressLint("MissingPermission")
  private void onConnection(@NonNull BluetoothGatt gatt, int status, int newState)
  {
    if (gatt != mGatt)
      return;
    Logger.i(TAG, "connection = " + newState + " status " + status);
    if (newState != BluetoothProfile.STATE_CONNECTED || status != BluetoothGatt.GATT_SUCCESS)
    {
      restartLater();
      return;
    }
    mLinkedMs = SystemClock.elapsedRealtime();
    // The connection interval is not asked for: the box asks for the one it needs by itself.
    try
    {
      if (!gatt.requestMtu(MTU))
        restartLater();
    }
    catch (SecurityException e)
    {
      restartLater();
    }
  }

  @SuppressLint("MissingPermission")
  private void onMtu(@NonNull BluetoothGatt gatt, int mtu, int status)
  {
    if (gatt != mGatt)
      return;
    Logger.i(TAG, "mtu = " + mtu + " status " + status);
    if (status != BluetoothGatt.GATT_SUCCESS)
    {
      // With the default MTU of 23 every HELLO is too long: the link would stay silent.
      restartLater();
      return;
    }
    mMtu = mtu;
    // The box may ask for it too: the services are searched once.
    if (mRx != null)
      return;
    try
    {
      if (!gatt.discoverServices())
        restartLater();
    }
    catch (SecurityException e)
    {
      restartLater();
    }
  }

  private void onServices(@NonNull BluetoothGatt gatt, int status)
  {
    if (gatt != mGatt)
      return;
    final BluetoothGattService service = status == BluetoothGatt.GATT_SUCCESS ? gatt.getService(SERVICE) : null;
    final BluetoothGattCharacteristic rx = service != null ? service.getCharacteristic(RX) : null;
    if (rx == null || service.getCharacteristic(TX) == null)
    {
      Logger.w(TAG, "No service of the box, status " + status);
      restartLater();
      return;
    }
    mRx = rx;
    mOta = service.getCharacteristic(OTA);
    subscribe(gatt);
  }

  @SuppressLint("MissingPermission")
  @SuppressWarnings("deprecation")
  private void subscribe(@NonNull BluetoothGatt gatt)
  {
    final BluetoothGattService service = gatt.getService(SERVICE);
    final BluetoothGattCharacteristic tx = service != null ? service.getCharacteristic(TX) : null;
    final BluetoothGattDescriptor config = tx != null ? tx.getDescriptor(CLIENT_CONFIG) : null;
    if (config == null)
    {
      Logger.w(TAG, "The lines of the box can't be subscribed to");
      restartLater();
      return;
    }
    try
    {
      gatt.setCharacteristicNotification(tx, true);
      final boolean started;
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
      {
        started = gatt.writeDescriptor(config, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
               == BluetoothStatusCodes.SUCCESS;
      }
      else
      {
        config.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
        started = gatt.writeDescriptor(config);
      }
      if (!started)
        restartLater();
    }
    catch (SecurityException e)
    {
      restartLater();
    }
  }

  private void onSubscribed(@NonNull BluetoothGatt gatt, int status)
  {
    if (gatt != mGatt)
      return;
    Logger.i(TAG, "subscribed, status " + status);
    if (status == BluetoothGatt.GATT_SUCCESS)
    {
      mReady = true;
      // A box that is not paired yet is connected after the pairing, see onBondStateChanged().
      if (takesLines(gatt.getDevice().getBondState()))
        setState(STATE_CONNECTED);
    }
    else if (status != BluetoothGatt.GATT_INSUFFICIENT_AUTHENTICATION
             && status != BluetoothGatt.GATT_INSUFFICIENT_ENCRYPTION)
    {
      restartLater();
    }
    // Otherwise the phone pairs with the box now, see onBondStateChanged().
  }

  @SuppressLint("MissingPermission")
  @SuppressWarnings("deprecation")
  private void writeNext()
  {
    final BluetoothGatt gatt = mGatt;
    final boolean firmware = mOutgoing.isEmpty();
    final ArrayDeque<byte[]> queue = firmware ? mFirmware : mOutgoing;
    final BluetoothGattCharacteristic characteristic = firmware ? mOta : mRx;
    if (mWriting || gatt == null || characteristic == null || queue.isEmpty())
      return;
    final byte[] data = queue.peek();
    try
    {
      final boolean started;
      // Without a response: the box answers a command with a line, and its data are the answer to HELLO. It
      // tells how much of a firmware it has got in lines too.
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
      {
        started = gatt.writeCharacteristic(characteristic, data, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE)
               == BluetoothStatusCodes.SUCCESS;
      }
      else
      {
        characteristic.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE);
        characteristic.setValue(data);
        started = gatt.writeCharacteristic(characteristic);
      }
      mWriting = started;
      if (started)
      {
        queue.poll();
      }
      else if (firmware)
      {
        // The pieces go one after another, a refused one is written again in a moment.
        mMainHandler.removeCallbacks(mWriter);
        mMainHandler.postDelayed(mWriter, WRITE_RETRY_MS);
      }
      else
      {
        // A refused write is busy with another operation: the line is dropped, HELLO comes again in a second.
        queue.poll();
        writeNext();
      }
    }
    catch (SecurityException e)
    {
      mOutgoing.clear();
      mFirmware.clear();
    }
  }
}
