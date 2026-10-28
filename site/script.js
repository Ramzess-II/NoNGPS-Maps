(function () {
  const STEPS = 5;
  const section = document.getElementById("how");
  const stage = document.getElementById("stage");
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Cumulative classes at-1..at-N (everything up to the step is on) and s-N (only the current step).
  function setStep(n) {
    if (stage.dataset.step === String(n)) return;
    stage.dataset.step = n;
    stage.className = "stage";
    for (let i = 1; i <= n; i++) stage.classList.add("at-" + i);
    stage.classList.add("s-" + n);
  }

  function onScroll() {
    const rect = section.getBoundingClientRect();
    const total = rect.height - window.innerHeight;
    const p = Math.min(1, Math.max(0, -rect.top / total));
    setStep(Math.min(STEPS, Math.floor(p * STEPS) + 1));
  }

  if (reduced) {
    setStep(STEPS);
  } else {
    setStep(1);
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll);
    onScroll();
  }

  // Progress buttons jump to the matching scroll position.
  document.querySelectorAll("[data-go]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const n = Number(btn.dataset.go);
      const total = section.offsetHeight - window.innerHeight;
      const top = section.getBoundingClientRect().top + window.scrollY;
      window.scrollTo({ top: top + total * ((n - 0.5) / STEPS) });
    });
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
