# NonGPS Maps: the look of the Box sheet

The sheet and its pages are one style on each platform. iOS keeps `insetGrouped` tables, the style of the
platform; Android is a settings list, not a copy of them. Follow this when you add a page or a row, and change it
here when the style itself changes.

## Android

The pages live in `android/app/src/main/res/layout/nogps_box_sheet.xml`, the rows in `nogps_*_row.xml` and
`nogps_box_section.xml`, laid out by `BoxBottomSheet`.

- **No cards.** `@drawable/bg_nogps_group` is for the two tiles of the main page only. A list of rows is never
  wrapped in it.
- **Sections** are a hairline and a heading: a `View` of `@dimen/divider_height` with `?dividerHorizontal`, then a
  `TextView` of 14sp in `?colorAccent` and `@string/robotoMedium`. A first section needs no heading.
- **Rows** are flush with the page: the page's own 20dp padding is the only inset, so no `paddingHorizontal` on a
  row. Every row that does something takes `?selectableItemBackground`, `minHeight` 48dp for one line, or 56dp with
  `paddingVertical="6dp"` for two.
- **Row text**: the title 16sp in the primary colour; a short value at the end of the row 16sp secondary; a
  sentence, like the state of the box, on a second line under the title, 14sp secondary. A sentence never goes at
  the end of a row: it wraps and pushes the title aside.
- **A row that opens a page** ends with `@drawable/ic_nogps_chevron` in a 24dp `ImageView`, not as a compound
  drawable of the value.
- **Hints, footers and empty notes** are 14sp secondary. The status line of a page, like the readiness of the box,
  is 17sp bold in the colour of its state.
- **A row that acts** is `?colorAccent` and turns `?android:textColorSecondary` while it is disabled; one that
  destroys is `@color/base_red`.
- **Nothing from the box**: a page of values keeps its rows and shows `@string/nogps_unknown` in each, so it never
  collapses to a header with nothing under it.

Android: the sheet is as wide as the window (`MwmWidget.BoxBottomSheetDialog` drops the 640dp cap and the side
margins; the content clears the side insets) and at least half the window high (`BoxBottomSheet.minSheetHeight`).

## iOS

`iphone/Maps/UI/Map/MapViewControls/NoGpsBoxSheet.swift` and `NoGpsBoxPage.swift`.

- Rows are `UIListContentConfiguration`: `valueCell()` for a short value, `subtitleCell()` for a sentence under the
  title, `.secondaryLabel` for its colour.
- The bar of the sheet is the system one, filled with `pressBackground`, the colour the list is drawn on, so the
  bar and the top of the page are one surface. `NoGpsBoxSheet.plainBar` sets it: a bar with no style of its own
  gets the green bar of Organic Maps.
- The sheet is the system one and keeps its look: inset and floating on iOS 26 and newer, edge-attached before it.
  UIKit draws any detent below full height as a floating card and offers no partial detent attached to the screen
  edges, so don't file "flush at a short height"; it would mean presenting on `ModalPresentationStepsController`.
- Every page is as high as its content, at least half the window (`NoGpsBoxSheet.sheetHeight`); `.large` stays for
  dragging to the full height.
- A page of values shows every row of its range with `nogps_unknown` until the box tells them.
