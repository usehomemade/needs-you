/* Page behaviour: theme switch, section reveal, copy buttons, live GitHub
   numbers and the hero island demo. Everything works without it. */

const reduced = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

// Theme: system / light / dark, stored per browser.
const KEY = "ny-theme";
const themeButtons = [...document.querySelectorAll<HTMLButtonElement>("[data-theme-choice]")];
const showTheme = (choice: string) => {
  for (const b of themeButtons) b.setAttribute("aria-pressed", String(b.dataset.themeChoice === choice));
};
const applyTheme = (choice: string) => {
  const d = document.documentElement;
  if (choice === "system") {
    delete d.dataset.theme;
    d.style.colorScheme = "";
  } else {
    d.dataset.theme = choice;
    d.style.colorScheme = choice;
  }
  try {
    if (choice === "system") localStorage.removeItem(KEY);
    else localStorage.setItem(KEY, choice);
  } catch {}
  showTheme(choice);
};
try {
  showTheme(localStorage.getItem(KEY) ?? "system");
} catch {}
for (const b of themeButtons) b.addEventListener("click", () => applyTheme(b.dataset.themeChoice ?? "system"));

// Fade-in-up for sections below the fold, once.
if (!reduced() && "IntersectionObserver" in window) {
  const seen = new WeakSet<Element>();
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (!seen.has(e.target)) {
          seen.add(e.target);
          if (!e.isIntersecting && e.boundingClientRect.top > 0) {
            e.target.classList.add("is-pending");
            continue;
          }
        }
        if (e.isIntersecting) {
          e.target.classList.remove("is-pending");
          io.unobserve(e.target);
        }
      }
    },
    { rootMargin: "0px 0px -10% 0px" },
  );
  for (const el of document.querySelectorAll(".ny-reveal")) io.observe(el);
}

// Copy buttons.
for (const b of document.querySelectorAll<HTMLButtonElement>("[data-copy]")) {
  b.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(b.dataset.copy ?? "");
      b.dataset.done = "";
      b.setAttribute("aria-label", "Copied");
      setTimeout(() => {
        delete b.dataset.done;
        b.setAttribute("aria-label", "Copy command");
      }, 1600);
    } catch {}
  });
}

// GitHub numbers: the build wrote them into the page; refresh them here so a
// cached page still shows today's count. Any failure keeps the built values.
const REPO = "usehomemade/needs-you";
const compact = (n: number) =>
  n >= 1000 ? `${(n / 1000).toFixed(n >= 10000 ? 0 : 1).replace(/\.0$/, "")}k` : String(n);
const setStat = (name: string, text: string, show = true) => {
  for (const el of document.querySelectorAll<HTMLElement>(`[data-stat="${name}"]`)) {
    el.textContent = text;
    const box = el.closest<HTMLElement>("[data-stat-box]") ?? el;
    box.hidden = !show;
  }
};
const refresh = async () => {
  const cacheKey = "ny-gh";
  let data: { stars: number; version?: string; dmg?: string } | null = null;
  try {
    const c = JSON.parse(sessionStorage.getItem(cacheKey) ?? "null");
    if (c && Date.now() - c.at < 10 * 60 * 1000) data = c;
  } catch {}
  if (!data) {
    const [repo, rel] = await Promise.all([
      fetch(`https://api.github.com/repos/${REPO}`).then((r) => (r.ok ? r.json() : null)),
      fetch(`https://api.github.com/repos/${REPO}/releases/latest`).then((r) => (r.ok ? r.json() : null)),
    ]);
    if (!repo) return;
    data = {
      stars: repo.stargazers_count,
      version: rel?.tag_name?.replace(/^v/, ""),
      dmg: rel?.assets?.find((a: { name: string }) => a.name.endsWith(".dmg"))?.browser_download_url,
    };
    try {
      sessionStorage.setItem(cacheKey, JSON.stringify({ ...data, at: Date.now() }));
    } catch {}
  }
  if (typeof data.stars === "number") {
    for (const el of document.querySelectorAll<HTMLElement>('[data-stat="stars"]')) {
      el.textContent = compact(data.stars);
      el.hidden = data.stars === 0 && !el.closest("[data-stat-box]");
    }
  }
  if (data.version) setStat("version", data.version);
  if (data.dmg) for (const a of document.querySelectorAll<HTMLAnchorElement>("[data-dmg]")) a.href = data.dmg;
};
refresh().catch(() => {});

// Hero island demo: a made-up "Hey Claude" message, then an agent's question.
type Step = { state: string; ms: number; you?: string; claude?: string; slots?: Record<string, string>; show?: string };
const STEPS: Step[] = [
  { state: "idle", ms: 1400 },
  { state: "wake", ms: 2300, you: "Hey Claude, garden planner: order the seeds for Friday." },
  { state: "thinking", ms: 1100 },
  { state: "sending", ms: 2000, slots: { target: "garden-planner" } },
  { state: "done", ms: 1700, slots: { note: "Sent to garden-planner" }, show: "sent" },
  { state: "idle", ms: 1300, show: "sent" },
  { state: "speaking", ms: 3600, claude: "Tests pass on the branch. Shall I merge it?", show: "ask" },
  { state: "listening", ms: 2400, you: "Yes, merge it.", show: "ask" },
  { state: "done", ms: 2200, slots: { note: "Answered" }, show: "answered" },
];

const stage = document.querySelector<HTMLElement>("[data-demo]");
if (stage) {
  const island = stage.querySelector<HTMLElement>(".ny-island")!;
  const youSub = stage.querySelector<HTMLElement>('[data-who="you"]')!;
  const claudeSub = stage.querySelector<HTMLElement>('[data-who="claude"]')!;
  const show = (step: Step) => {
    island.dataset.state = step.state;
    for (const [k, v] of Object.entries(step.slots ?? {})) {
      const el = island.querySelector<HTMLElement>(`[data-slot="${k}"]`);
      if (el) el.textContent = v;
    }
    for (const layer of island.querySelectorAll<HTMLElement>("[data-layer]")) {
      layer.toggleAttribute("data-on", layer.dataset.layer === step.state);
    }
    youSub.textContent = step.you ?? "";
    claudeSub.textContent = step.claude ?? "";
    for (const el of stage.querySelectorAll<HTMLElement>("[data-when]")) {
      const when = el.dataset.when!.split(" ");
      const reached = STEPS.indexOf(step);
      el.hidden = !when.some((w) => STEPS.slice(0, reached + 1).some((s) => s.show === w));
    }
  };
  if (reduced()) {
    // One still frame: the agent's question on screen.
    show(STEPS[6]);
  } else {
    let i = 0;
    let timer = 0;
    let visible = true;
    const tick = () => {
      show(STEPS[i]);
      timer = window.setTimeout(() => {
        i = (i + 1) % STEPS.length;
        if (visible && !document.hidden) tick();
        else timer = 0;
      }, STEPS[i].ms);
    };
    const resume = () => {
      if (!timer && visible && !document.hidden) tick();
    };
    new IntersectionObserver(([e]) => {
      visible = e.isIntersecting;
      resume();
    }).observe(stage);
    document.addEventListener("visibilitychange", resume);
    tick();
  }
}
