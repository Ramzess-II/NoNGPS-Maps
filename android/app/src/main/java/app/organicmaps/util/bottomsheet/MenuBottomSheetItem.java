package app.organicmaps.util.bottomsheet;

public class MenuBottomSheetItem
{
  public final int titleRes;
  public final int iconRes;
  public final int badgeCount;
  /** The item opens a group of its own: the sheet draws a divider above it. */
  public final boolean startsGroup;
  public final OnClickListener onClickListener;

  public MenuBottomSheetItem(int titleRes, int iconRes, OnClickListener onClickListener)
  {
    this(titleRes, iconRes, 0, false, onClickListener);
  }

  public MenuBottomSheetItem(int titleRes, int iconRes, int badgeCount, OnClickListener onClickListener)
  {
    this(titleRes, iconRes, badgeCount, false, onClickListener);
  }

  public MenuBottomSheetItem(int titleRes, int iconRes, int badgeCount, boolean startsGroup,
                             OnClickListener onClickListener)
  {
    this.titleRes = titleRes;
    this.iconRes = iconRes;
    this.badgeCount = badgeCount;
    this.startsGroup = startsGroup;
    this.onClickListener = onClickListener;
  }

  public interface OnClickListener
  {
    void onClick();
  }
}
