# Non-GPS Organic Maps — landing site

Static site (HTML/CSS/JS, no build). Ukrainian only.

## Run locally
    python3 -m http.server 8000   # then open http://localhost:8000

## Connect the pre-order form
1. Google Forms → Send → `<>` embed → copy the `src` URL (ends with `?embedded=true`).
2. Paste it into `data-form-url=""` on `<section id="preorder">` in `index.html`.

## Placeholders
Search `TODO` in `index.html` for anything not filled in yet (none at the moment).

## Deploy
`.github/workflows/site-pages.yaml` publishes this folder to GitHub Pages on every push to `master` that touches `site/`. One-time setup: repo Settings → Pages → Source: GitHub Actions.

## Structure
- `index.html` — sections; the explainer is one inline SVG whose parts react to `.at-N` / `.s-N` classes on `#stage`
- `styles.css` — theme tokens in `:root`, per-step animation rules under "scene elements"
- `script.js` — maps scroll position in `#how` to steps 1–5; loads the form
