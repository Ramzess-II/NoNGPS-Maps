package app.organicmaps.maplayer;

import android.annotation.SuppressLint;
import android.content.Context;
import android.util.AttributeSet;
import android.view.MotionEvent;
import android.widget.LinearLayout;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

/**
 * A panel of map buttons the user can move up and down, see MapPanelDragger. The dragger sees the touches on the
 * buttons too, and takes them from the buttons while the panel is lifted.
 */
public class MapPanelLayout extends LinearLayout
{
  @Nullable
  private MapPanelDragger mDragger;

  public MapPanelLayout(Context context)
  {
    super(context);
  }

  public MapPanelLayout(Context context, @Nullable AttributeSet attrs)
  {
    super(context, attrs);
  }

  public MapPanelLayout(Context context, @Nullable AttributeSet attrs, int defStyleAttr)
  {
    super(context, attrs, defStyleAttr);
  }

  void setDragger(@Nullable MapPanelDragger dragger)
  {
    mDragger = dragger;
  }

  @Override
  public boolean onInterceptTouchEvent(@NonNull MotionEvent event)
  {
    return mDragger != null && mDragger.onTouch(event);
  }

  // The panel itself does nothing on a click: a touch between the buttons is kept for the dragger.
  @SuppressLint("ClickableViewAccessibility")
  @Override
  public boolean onTouchEvent(@NonNull MotionEvent event)
  {
    if (mDragger == null)
      return super.onTouchEvent(event);
    // onInterceptTouchEvent() has given the down to the dragger already.
    if (event.getActionMasked() != MotionEvent.ACTION_DOWN)
      mDragger.onTouch(event);
    return true;
  }

  @Override
  protected void onDetachedFromWindow()
  {
    super.onDetachedFromWindow();
    if (mDragger != null)
      mDragger.stop();
  }
}
