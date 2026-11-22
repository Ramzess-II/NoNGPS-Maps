Libraries of the log viewer, served by nogps_log_viewer.py so that the page loads nothing from the network.
Files are the unmodified npm dist files, taken from the versions below.

leaflet 1.9.4   leaflet.css, leaflet.js         BSD 2-Clause, LICENSE-leaflet.txt
uPlot   1.6.30  uPlot.min.css, uPlot.iife.min.js  MIT, LICENSE-uplot.txt

To update: download the same files of the new version from https://cdn.jsdelivr.net/npm/<package>@<version>/dist/
and change the versions here. leaflet.css refers to images/ (layer control and marker icons) that the viewer
does not use, so they are not vendored.
