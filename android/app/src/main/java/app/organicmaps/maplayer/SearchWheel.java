package app.organicmaps.maplayer;

import android.animation.Animator;
import android.animation.AnimatorInflater;
import android.content.res.ColorStateList;
import android.view.View;
import android.widget.ImageView;
import androidx.annotation.DrawableRes;
import androidx.annotation.IdRes;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.StringRes;
import app.organicmaps.R;
import app.organicmaps.sdk.search.SearchEngine;
import app.organicmaps.sdk.util.concurrency.UiThread;
import app.organicmaps.util.ThemeUtils;
import app.organicmaps.util.UiUtils;

/**
 * The quick search of the navigation: the categories on a half circle beside the right map panel, its flat side at
 * the panel. A category is searched on the map, the button of the panel then shows it and clears it. The wheel closes
 * by itself after a while.
 */
public class SearchWheel implements View.OnClickListener
{
  static final long CLOSE_DELAY_MILLIS = 5000L;

  enum Tap
  {
    OPEN,
    CLOSE,
    CLEAR
  }

  /**
   * The button of the panel closes an open wheel, else clears the searched category, else opens the wheel.
   */
  @NonNull
  static Tap onButton(boolean expanded, boolean searching)
  {
    if (expanded)
      return Tap.CLOSE;
    return searching ? Tap.CLEAR : Tap.OPEN;
  }

  public enum SearchOption
  {
    FUEL(R.id.search_fuel, R.drawable.ic_routing_fuel_off, R.string.category_fuel),
    PARKING(R.id.search_parking, R.drawable.ic_routing_parking_off, R.string.category_parking),
    EAT(R.id.search_eat, R.drawable.ic_routing_eat_off, R.string.category_eat),
    FOOD(R.id.search_food, R.drawable.ic_routing_food_off, R.string.category_food),
    ATM(R.id.search_atm, R.drawable.ic_routing_atm_off, R.string.category_atm);

    @IdRes
    private final int mResId;
    @DrawableRes
    private final int mDrawableOff;
    @StringRes
    private final int mQueryId;

    SearchOption(@IdRes int resId, @DrawableRes int drawableOff, @StringRes int queryId)
    {
      this.mResId = resId;
      this.mDrawableOff = drawableOff;
      this.mQueryId = queryId;
    }

    @NonNull
    public static SearchOption fromResId(@IdRes int resId)
    {
      for (SearchOption searchOption : SearchOption.values())
      {
        if (searchOption.mResId == resId)
          return searchOption;
      }
      throw new IllegalArgumentException("No navigation search for id " + resId);
    }
  }

  @NonNull
  private final View mSearchLayout;
  @NonNull
  private final ImageView mSearchButton;
  @Nullable
  private final ColorStateList mIconTint;
  @NonNull
  private final View.OnClickListener mOnSearchCanceledListener;
  @NonNull
  private final MapButtonsViewModel mMapButtonsViewModel;
  private boolean mIsExpanded;
  @Nullable
  private Animator mAnimator;
  private final Runnable mCloseRunnable = () ->
  {
    if (mIsExpanded)
      toggleSearchLayout();
  };

  public SearchWheel(@NonNull View frame, @NonNull View.OnClickListener onSearchCanceledListener,
                     @NonNull MapButtonsViewModel mapButtonsViewModel)
  {
    mMapButtonsViewModel = mapButtonsViewModel;
    mOnSearchCanceledListener = onSearchCanceledListener;
    mSearchLayout = frame.findViewById(R.id.search_frame);
    mSearchButton = frame.findViewById(R.id.nav_search);
    mSearchButton.setOnClickListener(this);
    mIconTint = mSearchButton.getImageTintList();
    for (SearchOption searchOption : SearchOption.values())
      frame.findViewById(searchOption.mResId).setOnClickListener(this);
    refreshSearchButtonImage();
  }

  /**
   * A category is searched, or the search is cancelled, maybe elsewhere.
   */
  public void onSearchOptionChanged()
  {
    refreshSearchButtonImage();
  }

  /**
   * Closes the wheel at once.
   */
  public void stop()
  {
    UiThread.cancelDelayedTasks(mCloseRunnable);
    mIsExpanded = false;
    if (mAnimator != null)
      mAnimator.cancel();
    UiUtils.hide(mSearchLayout);
  }

  private void toggleSearchLayout()
  {
    // Its end shows the wheel as it is now.
    if (mAnimator != null)
      mAnimator.cancel();
    final int animRes;
    if (mIsExpanded)
    {
      animRes = R.animator.show_zoom_out_alpha;
    }
    else
    {
      animRes = R.animator.show_zoom_in_alpha;
      UiUtils.show(mSearchLayout);
    }
    mIsExpanded = !mIsExpanded;
    // Grows from the middle of the flat side.
    final boolean rtl = mSearchLayout.getLayoutDirection() == View.LAYOUT_DIRECTION_RTL;
    mSearchLayout.setPivotX(rtl ? 0 : mSearchLayout.getWidth());
    mSearchLayout.setPivotY(mSearchLayout.getHeight() / 2f);
    final Animator animator = AnimatorInflater.loadAnimator(mSearchLayout.getContext(), animRes);
    mAnimator = animator;
    animator.setTarget(mSearchLayout);
    animator.addListener(new UiUtils.SimpleAnimatorListener() {
      @Override
      public void onAnimationEnd(Animator animation)
      {
        UiUtils.showIf(mIsExpanded, mSearchLayout);
      }
    });
    animator.start();
    UiThread.cancelDelayedTasks(mCloseRunnable);
    if (mIsExpanded)
      UiThread.runLater(mCloseRunnable, CLOSE_DELAY_MILLIS);
  }

  private void refreshSearchButtonImage()
  {
    final SearchOption searchOption = mMapButtonsViewModel.getSearchOption().getValue();
    mSearchButton.setImageResource(searchOption == null ? R.drawable.ic_search : searchOption.mDrawableOff);
    mSearchButton.setImageTintList(searchOption == null
                                       ? mIconTint
                                       : ColorStateList.valueOf(ThemeUtils.getColor(
                                             mSearchButton.getContext(), androidx.appcompat.R.attr.colorAccent)));
  }

  @Override
  public void onClick(View v)
  {
    if (v.getId() == R.id.nav_search)
      onSearchButtonClick(v);
    else
      startSearch(SearchOption.fromResId(v.getId()));
  }

  private void onSearchButtonClick(View v)
  {
    switch (onButton(mIsExpanded, mMapButtonsViewModel.getSearchOption().getValue() != null))
    {
    case OPEN, CLOSE -> toggleSearchLayout();
    case CLEAR -> mOnSearchCanceledListener.onClick(v);
    }
  }

  private void startSearch(@NonNull SearchOption searchOption)
  {
    mMapButtonsViewModel.setSearchOption(searchOption);
    final String query = mSearchLayout.getContext().getString(searchOption.mQueryId);
    // Category request from navigation search wheel.
    SearchEngine.INSTANCE.searchInteractive(mSearchLayout.getContext(), query, true, System.nanoTime(), false);
    SearchEngine.INSTANCE.setQuery(query);
    toggleSearchLayout();
  }
}
