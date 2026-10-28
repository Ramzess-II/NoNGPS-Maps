# Development notes

Everything needed to continue work on this site. Paths are relative to the project root, so the folder can be moved anywhere.

## Product context
"Non-GPS Organic Maps" is a fork of Organic Maps that navigates without GPS. A small device plugged into the car's OBD-II port reads speed / wheel / steering data and sends it to the phone over Bluetooth. The app dead-reckons the position from the last known point. The site explains this visually and collects pre-orders through an embedded Google Form.

## Decisions made
- Stack: static HTML/CSS/JS, no build step, no dependencies (GitHub Pages / Netlify / Cloudflare Pages).
- Language: Ukrainian only (`lang="uk"`).
- Style: tech/hardware, dark background, neon-green accent (`--accent`), amber (`--amber`) for "GPS jammed" warnings, monospace accents.
- Audience: both drivers and enthusiasts, so the story is simple and the jargon sits in the collapsed "Технічні деталі" block.
- Lead message: resilience to GPS jamming/spoofing. Tunnels/garages and offline/privacy are secondary.
- Animation: scroll-driven story with a sticky stage (5 steps).
- Platforms mentioned: Android + iOS.
- Branding: text wordmark "Non-GPS Organic Maps" plus an explicit "fork of Organic Maps, not affiliated" note in the footer.
- Sections: hero, explainer, tech details, feature cards + specs strip, pre-order, footer. No FAQ.

## Files
| File | Purpose |
|---|---|
| `index.html` | All content. The explainer is one inline SVG inside `#stage`. |
| `styles.css` | Theme tokens in `:root`, layout, per-step scene rules under "scene elements". |
| `script.js` | Maps scroll position in `#how` to steps 1–5; wires the progress buttons; loads the form iframe. |
| `assets/favicon.svg` | Favicon. |
| `README.md` | Quick start / deploy. |

## How the explainer works
- `#how` is 600vh tall; its child `.sticky` stays pinned while the user scrolls.
- `script.js` computes progress `p` (0–1) through the section and picks step `n = floor(p*5)+1`.
- It sets classes on `#stage`: cumulative `at-1…at-n` (things that stay on once introduced) and a single `s-n` (things only shown during the current step, e.g. captions, status text).
- CSS defines each SVG part's hidden default, then reveals/animates it under `.stage.at-N` or `.stage.s-N`. To add or change an effect, edit the rules in `styles.css` rather than the JS.
- Step captions live in `.captions li[data-step]`; the status text inside the phone is `.st1 .st2 .st4 .st5`.
- Changing the number of steps requires updating `STEPS` in `script.js`, the captions and progress buttons in `index.html`, the `.scroll` height in CSS (roughly 120vh per step), and the CSS rules.
- Reduced motion: `prefers-reduced-motion` turns off animation, un-pins the section, jumps to the final step and lists all captions.
- Gotcha: SVG elements that use `transform-box: fill-box` (wheels, pulse ring) need it set in CSS. SMIL animations (`animateMotion`) in the SVG are not paused by the CSS reduced-motion rule.

## Pre-order form
- Put the Google Form embed URL (the `src` from Send → `<>`, ending `?embedded=true`) into `data-form-url` on `<section id="preorder">`.
- `script.js` fills the iframe and the "open in new tab" link from it and hides the placeholder. Iframe height is `900px` in `.form-box iframe`; adjust to the form's length.

## Open TODOs (search `TODO` in `index.html`)
- Google Form embed URL
- Specs: car compatibility, Bluetooth type, accuracy, price, delivery time
- Repo link and contact e-mail (footer, open-source card)
- `og:image` for link previews (not created yet)
- Real accuracy claim in "Технічні деталі" (drift paragraph)
- Visual QA: the SVG was written without being viewed in a browser; check positions of the device, data path, Bluetooth arcs and phone map at desktop and ~375px.

## Verification checklist
- `python3 -m http.server 8000`, then open it at desktop and mobile widths.
- Scroll through all 5 steps forward and backward; progress bars jump to the right step.
- Reduced-motion emulation shows the static layout.
- Form iframe loads with a real URL; the fallback link opens the form.
- Lighthouse: performance and accessibility ≥ 90.
