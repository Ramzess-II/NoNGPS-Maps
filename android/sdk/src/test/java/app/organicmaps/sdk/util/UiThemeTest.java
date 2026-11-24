package app.organicmaps.sdk.util;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class UiThemeTest
{
  @Test
  public void lightSensorFallsBackToSystemWithoutSensor()
  {
    assertEquals(Config.UiTheme.SYSTEM, Config.UiTheme.resolveSavedTheme("light_sensor", true, false));
    assertEquals(Config.UiTheme.SCHEDULED, Config.UiTheme.resolveSavedTheme("light_sensor", false, false));
  }

  @Test
  public void lightSensorKeptWithSensor()
  {
    assertEquals(Config.UiTheme.LIGHT_SENSOR, Config.UiTheme.resolveSavedTheme("light_sensor", true, true));
    assertEquals(Config.UiTheme.LIGHT_SENSOR, Config.UiTheme.resolveSavedTheme("light_sensor", false, true));
  }

  @Test
  public void otherThemesAreUnchanged()
  {
    assertEquals(Config.UiTheme.DARK, Config.UiTheme.resolveSavedTheme("night", true, false));
    assertEquals(Config.UiTheme.SYSTEM, Config.UiTheme.resolveSavedTheme("", true, false));
    assertEquals(Config.UiTheme.SCHEDULED, Config.UiTheme.resolveSavedTheme("", false, true));
    assertEquals(Config.UiTheme.SCHEDULED, Config.UiTheme.resolveSavedTheme("auto", false, true));
  }
}
