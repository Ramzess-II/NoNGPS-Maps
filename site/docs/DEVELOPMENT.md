# Development notes

Everything needed to continue work on this site. Paths are relative to the project root, so the folder can be moved anywhere.

## Product context
"Non-GPS Organic Maps" is a fork of Organic Maps that navigates without GPS. A small device plugged into the car's OBD-II port reads speed / wheel / steering data and sends it to the phone over Bluetooth. The app dead-reckons the position from the last known point. The site explains this visually and collects pre-orders through an embedded Google Form.

## Decisions made
- Stack: static HTML/CSS/JS, no build step, no dependencies (GitHub Pages / Netlify / Cloudflare Pages).
- Language: Ukrainian only (`lang="uk"`).
- Style: light and warm, taken from the app icon: apricot graph-paper background, brown wood (`--wood`) with diagonal hatching (`--hatch`) and a dark-brown outline (`--ink`), slab-serif headings. Rust (`--warn`) marks "GPS jammed", green (`--ok`) the working state, blue (`--bt`) Bluetooth and the position dot. Light only, so the embedded Google Form doesn't stand out.
- Audience: both drivers and enthusiasts, so the story is simple and the jargon sits in the collapsed "Технічні деталі" block.
- Lead message: resilience to GPS jamming/spoofing. Tunnels/garages and offline/privacy are secondary.
- Animation: the 5-step story switches on a short timer while the section is on screen, with step buttons and a pause button. It used to be driven by scrolling through a pinned section; that was dropped as too slow to get through.
- Platforms mentioned: Android + iOS.
- Branding: text wordmark "Non-GPS Organic Maps" plus an explicit "fork of Organic Maps, not affiliated" note in the footer.
- Sections: hero, how to get it (5 steps from the OBD-II port to accurate navigation), explainer, tech details, feature cards + specs strip, pre-order, footer. No FAQ.

## Files
| File | Purpose |
|---|---|
| `index.html` | All content. The explainer is one inline SVG inside `#stage`. |
| `styles.css` | Theme tokens in `:root`, layout, per-step scene rules under "scene elements". |
| `script.js` | Switches the explainer's steps on a timer; wires the step and pause buttons; loads the form iframe. |
| `assets/icon-180.png` | Favicon, Apple touch icon and the top-bar logo; `app-icon.png` scaled down with `sips -Z 180`. |
| `assets/og.png`, `assets/app-icon.png` | Link-preview image (1200×630, a headless Chrome screenshot of the icon and wordmark on the site background) and the Android app icon it is built from. |
| `README.md` | Quick start / deploy. |

## How the explainer works
- `script.js` shows each step for `STEP_MS[n-1]` (3.5 s; the last one 6 s, so the dot drives its route once) and loops back to step 1.
- The timer runs only while at least half of `#stage` is on screen, the tab is visible and the pause button is off; otherwise `#stage` gets `data-paused`. A step button jumps to that step and restarts its timer.
- The current step's progress bar fills over `--step`, which `script.js` sets to the step's time; `data-paused` pauses the fill.
- It sets classes on `#stage`: cumulative `at-1…at-n` (things that stay on once introduced) and a single `s-n` (things only shown during the current step, e.g. captions, status text).
- CSS defines each SVG part's hidden default, then reveals/animates it under `.stage.at-N` or `.stage.s-N`. To add or change an effect, edit the rules in `styles.css` rather than the JS.
- Step captions live in `.captions li[data-step]`; the status text inside the phone is `.st1 .st2 .st4 .st5`.
- Changing the number of steps requires updating `STEPS` in `script.js`, the captions and progress buttons in `index.html`, and the CSS rules (scene classes and the progress selectors).
- Reduced motion: `prefers-reduced-motion` turns off animation and the timer, shows the final step and lists all captions.
- The hatched wood fill `url(#wood)` is defined once in a hidden SVG at the top of `<body>`; the explainer and the step illustrations in `#get` use it.
- Gotcha: the explainer's scene classes (`.device`, `.led`, `.data`, `.route`, `.arc`, `.spin`, …) are global and start hidden; other SVGs use `il-` classes instead.
- Gotcha: SVG elements that use `transform-box: fill-box` (wheels, pulse ring) need it set in CSS. SMIL animations (`animateMotion`) in the SVG are not paused by the CSS reduced-motion rule.

## Pre-order form
- Put the Google Form embed URL (the `src` from Send → `<>`, ending `?embedded=true`) into `data-form-url` on `<section id="preorder">`.
- `script.js` fills the iframe and the "open in new tab" link from it and hides the placeholder. Iframe height is `900px` in `.form-box iframe`; adjust to the form's length.

## Open items
- `og:image` URL in `index.html` is absolute and uses `https://ramzess-ii.github.io/NoNGPS-Maps/`; change it if a custom domain is attached.
- Delivery time is "Повідомимо після передзамовлення" until it is fixed.
- Labels inside the explainer SVG are very small at ~375px width.
- Accuracy is described qualitatively (car sensors, not phone); no measured figure is published.

## Verification checklist
- `python3 -m http.server 8000`, then open it at desktop and mobile widths.
- Scroll through all 5 steps forward and backward; progress bars jump to the right step.
- Reduced-motion emulation shows the static layout.
- Form iframe loads with a real URL; the fallback link opens the form.
- Lighthouse: performance and accessibility ≥ 90.
