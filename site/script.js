(function () {
  // How long each step of the explainer is shown; the last one lets the dot drive its route once.
  const STEP_MS = [1750, 1750, 1750, 1750, 3000];
  const STEPS = STEP_MS.length;
  const stage = document.getElementById("stage");
  const play = stage.querySelector(".play");
  const scene = stage.querySelector("svg");
  const drive = stage.querySelector(".moving animateMotion");
  const bars = stage.querySelectorAll("[data-go]");
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  let step = 1;
  let visible = false;
  let paused = false;
  let timer = 0;

  // Cumulative classes at-1..at-N (everything up to the step is on) and s-N (only the current step).
  function setStep(n) {
    step = n;
    stage.className = "stage";
    for (let i = 1; i <= n; i++) stage.classList.add("at-" + i);
    stage.classList.add("s-" + n);
    stage.style.setProperty("--step", STEP_MS[n - 1] + "ms");
    bars.forEach((b) => b.toggleAttribute("aria-current", Number(b.dataset.go) === n));
    // The dot runs on the SVG clock; start its route together with the last step.
    if (n === STEPS) drive.beginElement();
  }

  // Runs the timer only while the section is on screen, the tab is open and the user didn't pause.
  function update() {
    const running = visible && !paused && !document.hidden;
    stage.toggleAttribute("data-paused", !running);
    if (running) scene.unpauseAnimations();
    else scene.pauseAnimations();
    clearTimeout(timer);
    if (!running) return;
    // The timer starts over, so the progress fill of the current step starts over too.
    const bar = stage.querySelector('[data-go="' + step + '"]');
    bar.style.animation = "none";
    void bar.offsetWidth;
    bar.style.animation = "";
    timer = setTimeout(() => go((step % STEPS) + 1), STEP_MS[step - 1]);
  }

  function go(n) {
    setStep(n);
    update();
  }

  if (reduced) {
    setStep(STEPS);
  } else {
    setStep(1);
    update();
    new IntersectionObserver((entries) => {
      visible = entries[0].isIntersecting;
      update();
    }, { threshold: 0.5 }).observe(stage);
    document.addEventListener("visibilitychange", update);
  }

  bars.forEach((btn) => {
    btn.addEventListener("click", () => go(Number(btn.dataset.go)));
  });
  play.addEventListener("click", () => {
    paused = !paused;
    play.setAttribute("aria-pressed", String(paused));
    update();
  });

  // Google Form: URL lives in data-form-url on #preorder.
  const pre = document.getElementById("preorder");
  const url = (pre.dataset.formUrl || "").trim();
  if (url) {
    const frame = document.getElementById("form-frame");
    const link = document.getElementById("form-link");
    frame.src = url;
    frame.hidden = false;
    link.href = url.replace("?embedded=true", "").replace("&embedded=true", "");
    link.hidden = false;
    document.getElementById("form-placeholder").hidden = true;
  }
})();
