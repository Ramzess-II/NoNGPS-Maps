package app.organicmaps.search;

import android.content.Context;
import android.graphics.drawable.Drawable;
import android.text.TextUtils;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageView;
import android.widget.TextView;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.recyclerview.widget.RecyclerView;
import app.organicmaps.R;
import app.organicmaps.sdk.bookmarks.data.BookmarkInfo;
import app.organicmaps.sdk.bookmarks.data.BookmarkManager;
import app.organicmaps.sdk.util.StringUtils;
import app.organicmaps.util.UiUtils;
import app.organicmaps.utils.Graphics;
import java.util.ArrayList;
import java.util.List;

// The rows of the Bookmarks tab: all bookmarks, nearest first.
class SearchBookmarksAdapter extends RecyclerView.Adapter<SearchBookmarksAdapter.ViewHolder>
{
  interface OnBookmarkClickListener
  {
    void onBookmarkClick(long bookmarkId);
  }

  @NonNull
  private final OnBookmarkClickListener mListener;
  @NonNull
  private List<SearchBookmarks.Item> mItems = new ArrayList<>();

  SearchBookmarksAdapter(@NonNull OnBookmarkClickListener listener)
  {
    mListener = listener;
  }

  void setItems(@NonNull List<SearchBookmarks.Item> items)
  {
    mItems = items;
    notifyDataSetChanged();
  }

  @NonNull
  @Override
  public ViewHolder onCreateViewHolder(@NonNull ViewGroup parent, int viewType)
  {
    final View view = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_bookmark, parent, false);
    UiUtils.hide(view.findViewById(R.id.more));
    final ViewHolder holder = new ViewHolder(view);
    view.setOnClickListener(v -> {
      final int position = holder.getBindingAdapterPosition();
      if (position != RecyclerView.NO_POSITION)
        mListener.onBookmarkClick(mItems.get(position).id);
    });
    return holder;
  }

  @Override
  public void onBindViewHolder(@NonNull ViewHolder holder, int position)
  {
    final SearchBookmarks.Item item = mItems.get(position);
    holder.mName.setText(item.name);
    final Context context = holder.itemView.getContext();
    final String distance =
        item.distance == null ? null : StringUtils.nativeFormatDistance(item.distance).toString(context);
    final String subtitle = TextUtils.isEmpty(distance) ? item.listName : distance + " • " + item.listName;
    holder.mSubtitle.setText(subtitle);
    holder.mIcon.setImageDrawable(icon(item.id, context));
  }

  @Override
  public int getItemCount()
  {
    return mItems.size();
  }

  @Nullable
  static Drawable icon(long bookmarkId, @NonNull Context context)
  {
    final BookmarkInfo info = BookmarkManager.INSTANCE.getBookmarkInfo(bookmarkId);
    if (info == null)
      return null;
    return Graphics.drawCircleAndImage(info.getIcon().argb(), R.dimen.track_circle_size, info.getIcon().getResId(),
                                       R.dimen.bookmark_icon_size, context);
  }

  static class ViewHolder extends RecyclerView.ViewHolder
  {
    @NonNull
    private final ImageView mIcon;
    @NonNull
    private final TextView mName;
    @NonNull
    private final TextView mSubtitle;

    ViewHolder(@NonNull View itemView)
    {
      super(itemView);
      mIcon = itemView.findViewById(R.id.iv__bookmark_color);
      mName = itemView.findViewById(R.id.tv__bookmark_name);
      mSubtitle = itemView.findViewById(R.id.tv__bookmark_distance);
      // The row is the touch target, the icon only shows the color.
      mIcon.setClickable(false);
      mIcon.setBackground(null);
    }
  }
}
