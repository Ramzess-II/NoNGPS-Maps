package app.organicmaps.search;

import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageView;
import android.widget.TextView;
import androidx.annotation.NonNull;
import androidx.recyclerview.widget.RecyclerView;
import app.organicmaps.R;
import app.organicmaps.sdk.bookmarks.data.BookmarkInfo;
import app.organicmaps.sdk.bookmarks.data.BookmarkManager;

// The horizontal strip of the first bookmark list, between the search field and the tabs.
class SearchBookmarksStripAdapter extends RecyclerView.Adapter<SearchBookmarksStripAdapter.ViewHolder>
{
  @NonNull
  private final SearchBookmarksAdapter.OnBookmarkClickListener mListener;
  @NonNull
  private long[] mIds = new long[0];

  SearchBookmarksStripAdapter(@NonNull SearchBookmarksAdapter.OnBookmarkClickListener listener)
  {
    mListener = listener;
  }

  void setIds(@NonNull long[] ids)
  {
    mIds = ids;
    notifyDataSetChanged();
  }

  @NonNull
  @Override
  public ViewHolder onCreateViewHolder(@NonNull ViewGroup parent, int viewType)
  {
    final View view =
        LayoutInflater.from(parent.getContext()).inflate(R.layout.item_search_bookmark_strip, parent, false);
    final ViewHolder holder = new ViewHolder(view);
    view.setOnClickListener(v -> {
      final int position = holder.getBindingAdapterPosition();
      if (position != RecyclerView.NO_POSITION)
        mListener.onBookmarkClick(mIds[position]);
    });
    return holder;
  }

  @Override
  public void onBindViewHolder(@NonNull ViewHolder holder, int position)
  {
    final long id = mIds[position];
    final BookmarkInfo info = BookmarkManager.INSTANCE.getBookmarkInfo(id);
    final String name = info == null ? "" : info.getName();
    holder.mName.setText(name);
    holder.itemView.setContentDescription(name);
    holder.mIcon.setImageDrawable(SearchBookmarksAdapter.icon(id, holder.itemView.getContext()));
  }

  @Override
  public int getItemCount()
  {
    return mIds.length;
  }

  static class ViewHolder extends RecyclerView.ViewHolder
  {
    @NonNull
    private final ImageView mIcon;
    @NonNull
    private final TextView mName;

    ViewHolder(@NonNull View itemView)
    {
      super(itemView);
      mIcon = itemView.findViewById(R.id.icon);
      mName = itemView.findViewById(R.id.name);
    }
  }
}
