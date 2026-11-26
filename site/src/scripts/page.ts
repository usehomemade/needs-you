import { startScene } from "./scene";
/* Page behaviour: theme switch, section reveal, copy buttons, live GitHub
   numbers and the hero scene. Everything works without it. */

const reduced = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

// Theme: follows the system until you pick one. The header button flips
// light/dark; the footer switch also offers "system". Stored in localStorage,
// or in window.name where storage is blocked (sandboxed previews).
const KEY = "ny-theme";
const root = document.documentElement;
const dark = window.matchMedia("(prefers-color-scheme: dark)");
const readChoice = () => {
  let t: string | null = null;
  try { t = localStorage.getItem(KEY); } catch {}
  if (!t) t = /(?:^|;)ny-theme=(light|dark)/.exec(window.name || "")?.[1] ?? null;
  return t === "light" || t === "dark" ? t : "system";
};
const saveChoice = (choice: string) => {
  try {
    if (choice === "system") localStorage.removeItem(KEY);
    else localStorage.setItem(KEY, choice);
  } catch {}
  const rest = (window.name || "").split(";").filter((p) => p && !p.startsWith(KEY + "="));
  if (choice !== "system") rest.push(KEY + "=" + choice);
  try { window.name = rest.join(";"); } catch {}
};
const themeButtons = [...document.querySelectorAll<HTMLButtonElement>("[data-theme-choice]")];
const toggles = [...document.querySelectorAll<HTMLButtonElement>("[data-theme-toggle]")];
const isDark = () => (root.dataset.theme ? root.dataset.theme === "dark" : dark.matches);
const showTheme = (choice: string) => {
  for (const b of themeButtons) b.setAttribute("aria-pressed", String(b.dataset.themeChoice === choice));
  for (const b of toggles) b.setAttribute("aria-label", isDark() ? "Switch to light mode" : "Switch to dark mode");
};
const applyTheme = (choice: string) => {
  if (choice === "system") {
    delete root.dataset.theme;
    root.style.colorScheme = "";
  } else {
    root.dataset.theme = choice;
    root.style.colorScheme = choice;
  }
  saveChoice(choice);
  showTheme(choice);
};
showTheme(readChoice());
for (const b of themeButtons) b.addEventListener("click", () => applyTheme(b.dataset.themeChoice ?? "system"));
for (const b of toggles) b.addEventListener("click", () => applyTheme(isDark() ? "light" : "dark"));
dark.addEventListener("change", () => showTheme(readChoice()));

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
      const icon = el.querySelector("svg");
      el.textContent = compact(data.stars);
      if (icon) el.prepend(icon);
      el.hidden = false;
    }
  }
  if (data.version) setStat("version", data.version);
  if (data.dmg) for (const a of document.querySelectorAll<HTMLAnchorElement>("[data-dmg]")) a.href = data.dmg;
};
refresh().catch(() => {});

// Hero scene.
const scene = document.querySelector<HTMLElement>("[data-scene]");
if (scene) startScene(scene);
