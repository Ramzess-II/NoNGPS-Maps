package app.organicmaps.nogps;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.view.ViewCompat;
import app.organicmaps.R;
import app.organicmaps.base.BaseMwmFragment;
import app.organicmaps.util.WindowInsetUtils;
import java.util.Locale;

/**
 * How NonGPS works: the guide page data/nogps_guide.html in a WebView. Its "Show the intro again" link closes this
 * screen with RESULT_OK, and MwmActivity starts the intro, see nogps.intro.IntroOverlay.
 */
public class HowNoGpsFragment extends BaseMwmFragment
{
  static final String INTRO_URL = "nogps-guide://intro";
  private static final String PAGE_URL = "file:///android_asset/nogps_guide.html";

  enum UrlAction
  {
    /** The page's own link to play the intro. */
    INTRO,
    /** A link to the web: the browser opens it. */
    BROWSER,
    /** The page itself or a file of the app: the WebView loads it. */
    LOAD
  }

  @NonNull
  static UrlAction classify(@NonNull String url)
  {
    if (url.equals(INTRO_URL))
      return UrlAction.INTRO;
    if (url.startsWith("http://") || url.startsWith("https://"))
      return UrlAction.BROWSER;
    return UrlAction.LOAD;
  }

  /** Ukrainian for the uk and ru locales, English for the others, as the page expects. */
  @NonNull
  static String pageLang(@NonNull String language)
  {
    final String l = language.toLowerCase(Locale.ROOT);
    return l.equals("uk") || l.equals("ru") ? "uk" : "en";
  }

  @SuppressLint("SetJavaScriptEnabled")
  @Override
  public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container,
                           @Nullable Bundle savedInstanceState)
  {
    final View root = inflater.inflate(R.layout.how_nogps, container, false);
    final WebView web = root.findViewById(R.id.webview);
    web.getSettings().setJavaScriptEnabled(true);
    web.getSettings().setDefaultTextEncodingName("utf-8");
    web.setWebViewClient(new WebViewClient() {
      @Override
      public boolean shouldOverrideUrlLoading(WebView view, String url)
      {
        switch (classify(url))
        {
        case INTRO ->
        {
          final Activity activity = requireActivity();
          activity.setResult(Activity.RESULT_OK);
          activity.finish();
          return true;
        }
        case BROWSER ->
        {
          try
          {
            startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
          }
          catch (ActivityNotFoundException ignored)
          {}
          return true;
        }
        default ->
        {
          return false;
        }
        }
      }
    });
    web.loadUrl(PAGE_URL + "?lang=" + pageLang(Locale.getDefault().getLanguage()));
    ViewCompat.setOnApplyWindowInsetsListener(root, WindowInsetUtils.PaddingInsetsListener.excludeTop());
    return root;
  }
}
