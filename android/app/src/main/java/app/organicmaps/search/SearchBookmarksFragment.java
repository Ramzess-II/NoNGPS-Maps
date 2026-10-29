package app.organicmaps.search;

import android.os.Bundle;
import android.view.View;
import androidx.annotation.LayoutRes;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.view.ViewCompat;
import androidx.recyclerview.widget.LinearLayoutManager;
import app.organicmaps.MwmApplication;
import app.organicmaps.R;
import app.organicmaps.base.BaseMwmRecyclerFragment;
import app.organicmaps.util.UiUtils;
import app.organicmaps.widget.PlaceholderView;

public class SearchBookmarksFragment extends BaseMwmRecyclerFragment<SearchBookmarksAdapter>
{
  private PlaceholderView mPlaceHolder;

  @NonNull
  @Override
  protected SearchBookmarksAdapter createAdapter()
  {
    return new SearchBookmarksAdapter((SearchFragment) requireParentFragment());
  }

  @Override
  protected @LayoutRes int getLayoutRes()
  {
    return R.layout.fragment_search_base;
  }

  @Override
  public void onViewCreated(@NonNull View view, @Nullable Bundle savedInstanceState)
  {
    super.onViewCreated(view, savedInstanceState);
    ViewCompat.setOnApplyWindowInsetsListener(getRecyclerView(), null);
    getRecyclerView().setLayoutManager(new LinearLayoutManager(view.getContext()));
    mPlaceHolder = view.findViewById(R.id.placeholder);
    mPlaceHolder.setContent(R.string.bookmarks_empty_list_title, R.string.bookmarks_empty_list_message);
    ((SearchFragment) requireParentFragment()).setRecyclerScrollListener(getRecyclerView());
    reload();
  }

  void reload()
  {
    if (getView() == null)
      return;
    final var location = MwmApplication.from(requireContext()).getLocationHelper().getSavedLocation();
    getAdapter().setItems(SearchBookmarks.all(location));
    UiUtils.showIf(getAdapter().getItemCount() == 0, mPlaceHolder);
  }
}
