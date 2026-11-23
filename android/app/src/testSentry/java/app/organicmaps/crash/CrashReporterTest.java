package app.organicmaps.crash;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import android.content.Context;
import android.content.SharedPreferences;
import io.sentry.Hint;
import io.sentry.OptionsContainer;
import io.sentry.Sentry;
import io.sentry.SentryEvent;
import io.sentry.android.core.SentryAndroidOptions;
import io.sentry.protocol.Message;
import java.util.Map;
import org.junit.After;
import org.junit.Test;

public class CrashReporterTest
{
  private static final String DSN = "https://key@o1.ingest.de.sentry.io/1";

  private static void startSentry()
  {
    try
    {
      Sentry.init(OptionsContainer.create(SentryAndroidOptions.class),
                  options -> CrashReporter.configure(options, DSN, "release", "1"));
    }
    catch (Exception e)
    {
      throw new AssertionError(e);
    }
  }

  @After
  public void tearDown()
  {
    Sentry.close();
  }

  @Test
  public void emptyDsnDoesNotStart()
  {
    assertFalse(CrashReporter.shouldStart("", false, true));
    assertFalse(CrashReporter.shouldStart(null, false, true));
  }

  @Test
  public void debugBuildDoesNotStart()
  {
    assertFalse(CrashReporter.shouldStart(DSN, true, true));
  }

  @Test
  public void switchOffDoesNotStart()
  {
    assertFalse(CrashReporter.shouldStart(DSN, false, false));
  }

  @Test
  public void startsWithDsnAndSwitchOn()
  {
    assertTrue(CrashReporter.shouldStart(DSN, false, true));
  }

  @Test
  public void optionsSendNothingPersonal()
  {
    final SentryAndroidOptions options = new SentryAndroidOptions();
    CrashReporter.configure(options, DSN, "release", "2026.11.24+26112401");
    assertFalse(options.isSendDefaultPii());
    assertEquals(0.0, options.getTracesSampleRate(), 0.0);
    assertTrue(options.isEnableScopeSync());
    assertEquals("release", options.getEnvironment());
  }

  @Test
  public void beforeSendDropsEventWithLogsPath()
  {
    final SentryAndroidOptions options = new SentryAndroidOptions();
    CrashReporter.configure(options, DSN, "release", "1");
    final SentryEvent withPath = new SentryEvent();
    final Message message = new Message();
    message.setFormatted("Can't open /storage/emulated/0/Android/data/app/files/logs/101010.log");
    withPath.setMessage(message);
    assertNull(options.getBeforeSend().execute(withPath, new Hint()));

    final SentryEvent clean = new SentryEvent();
    assertNotNull(options.getBeforeSend().execute(clean, new Hint()));
  }

  @Test
  public void assertGoesToScopeExtras()
  {
    startSentry();
    assertTrue(Sentry.isEnabled());
    CrashReporter.reportAssert("engine.cpp:10", "CHECK(a < b) 3 4");
    final Map<String, Object>[] extras = new Map[1];
    Sentry.configureScope(scope -> extras[0] = scope.getExtras());
    assertEquals("CHECK(a < b) 3 4", extras[0].get("assert.message"));
    assertEquals("engine.cpp:10", extras[0].get("assert.source"));
  }

  @Test
  public void coordinatesAreRedactedFromAssertMessage()
  {
    assertEquals("CHECK(d < 5) <num> <num> 12 3.5", CrashReporter.redactNumbers("CHECK(d < 5) 50.450123 -30.5234 12 3.5"));
  }

  @Test
  public void switchOffClosesStartedSentry()
  {
    final SharedPreferences.Editor editor = mock(SharedPreferences.Editor.class);
    when(editor.putBoolean(anyString(), anyBoolean())).thenReturn(editor);
    final SharedPreferences prefs = mock(SharedPreferences.class);
    when(prefs.edit()).thenReturn(editor);
    final Context context = mock(Context.class);
    when(context.getString(anyInt())).thenReturn("SendCrashReports");
    when(context.getPackageName()).thenReturn("app.organicmaps");
    when(context.getSharedPreferences(anyString(), anyInt())).thenReturn(prefs);

    startSentry();
    assertTrue(Sentry.isEnabled());
    CrashReporter.setEnabled(context, false);
    assertFalse(Sentry.isEnabled());
    verify(editor).putBoolean("SendCrashReports", false);
  }

  @Test
  public void switchIsOnByDefault()
  {
    final SharedPreferences prefs = mock(SharedPreferences.class);
    when(prefs.getBoolean(anyString(), anyBoolean())).thenAnswer(i -> i.getArgument(1));
    final Context context = mock(Context.class);
    when(context.getString(anyInt())).thenReturn("SendCrashReports");
    when(context.getPackageName()).thenReturn("app.organicmaps");
    when(context.getSharedPreferences(anyString(), anyInt())).thenReturn(prefs);
    assertTrue(CrashReporter.isEnabled(context));
  }
}
