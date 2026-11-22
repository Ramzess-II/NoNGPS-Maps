Libraries of the log viewer, served by nogps_log_viewer.py so that the page loads nothing from the network.
Files are the unmodified npm dist files, taken from the versions below.

leaflet 1.9.4   leaflet.css, leaflet.js, images/layers.png, images/layers-2x.png  BSD 2-Clause, LICENSE-leaflet.txt
uPlot   1.6.30  uPlot.min.css, uPlot.iife.min.js                                  MIT, LICENSE-uplot.txt

To update: download the same files of the new version from https://cdn.jsdelivr.net/npm/<package>@<version>/dist/
and change the versions here. The layer control takes its icon from images/layers.png, so those two images are
vendored as well; the marker images of leaflet.css are not, because the viewer draws only circle markers.
