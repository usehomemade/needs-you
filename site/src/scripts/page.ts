import { startScene } from "./scene";
/* Page behaviour: theme switch, section reveal, copy buttons, live GitHub
   numbers and the hero scene. Everything works without it. */

const reduced = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

// Theme: dark until you pick another. The header button flips light/dark;
// the footer switch also offers "system". Stored in localStorage, or in
// window.name where storage is blocked (sandboxed previews).
const KEY = "ny-theme";
const root = document.documentElement;
const dark = window.matchMedia("(prefers-color-scheme: dark)");
const readChoice = () => {
  let t: string | null = null;
  try { t = localStorage.getItem(KEY); } catch {}
  if (!t) t = /(?:^|;)ny-theme=(light|dark|system)/.exec(window.name || "")?.[1] ?? null;
  return t === "light" || t === "system" ? t : "dark";
};
const saveChoice = (choice: string) => {
  try { localStorage.setItem(KEY, choice); } catch {}
  const rest = (window.name || "").split(";").filter((p) => p && !p.startsWith(KEY + "="));
  rest.push(KEY + "=" + choice);
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

// Copy buttons. The Clipboard API can be blocked (sandboxed iframes, old
// browsers), so fall back to execCommand on a hidden textarea, and if that
// fails too, select the command so it can be copied by hand.
const copyText = async (text: string) => {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {}
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.setAttribute("readonly", "");
  ta.style.cssText = "position:fixed;top:0;left:0;opacity:0;pointer-events:none";
  document.body.append(ta);
  ta.select();
  let ok = false;
  try { ok = document.execCommand("copy"); } catch {}
  ta.remove();
  return ok;
};
for (const b of document.querySelectorAll<HTMLButtonElement>("[data-copy]")) {
  let timer = 0;
  b.addEventListener("click", async () => {
    const ok = await copyText(b.dataset.copy ?? "");
    if (!ok) {
      const code = b.parentElement?.querySelector("code");
      if (code) {
        const r = document.createRange();
        r.selectNodeContents(code);
        const s = window.getSelection();
        s?.removeAllRanges();
        s?.addRange(r);
      }
      b.setAttribute("aria-label", "Press Command-C to copy");
      return;
    }
    b.dataset.done = "";
    b.setAttribute("aria-label", "Copied");
    clearTimeout(timer);
    timer = window.setTimeout(() => {
      delete b.dataset.done;
      b.setAttribute("aria-label", "Copy command");
    }, 1500);
  });
}

// GitHub numbers: fetched live on every page load. Nothing is baked into the
// page; until the answer arrives the numbers stay hidden (or show "–"), and if
// GitHub can't be reached the links point at the releases page.
const REPO = "usehomemade/needs-you";
const compact = (n: number) =>
  n >= 1000 ? `${(n / 1000).toFixed(n >= 10000 ? 0 : 1).replace(/\.0$/, "")}k` : String(n);
const setStat = (name: string, text: string) => {
  for (const el of document.querySelectorAll<HTMLElement>(`[data-stat="${name}"]`)) {
    const icon = el.querySelector("svg");
    el.textContent = text;
    if (icon) el.prepend(icon);
    el.hidden = false;
    const box = el.closest<HTMLElement>("[data-stat-box]");
    if (box) box.hidden = false;
  }
};
interface Asset { name: string; download_count: number; browser_download_url: string }
interface Release { tag_name: string; html_url: string; published_at: string; draft: boolean; prerelease: boolean; assets: Asset[] }
const gh = (path: string) =>
  fetch(`https://api.github.com/repos/${REPO}${path}`, { headers: { Accept: "application/vnd.github+json" } }).then((r) => (r.ok ? r.json() : null));
const refresh = async () => {
  const [repo, releases] = await Promise.all([gh(""), gh("/releases?per_page=100")]);
  if (repo && typeof repo.stargazers_count === "number") setStat("stars", compact(repo.stargazers_count));
  if (!Array.isArray(releases)) return;
  const list = (releases as Release[]).filter((r) => !r.draft && !r.prerelease);
  const latest = list[0];
  if (!latest) return;
  setStat("version", latest.tag_name.replace(/^v/, ""));
  const date = new Date(latest.published_at).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });
  setStat("released", `Latest version, ${date}`);
  setStat("releases", String(list.length));
  const downloads = list.flatMap((r) => r.assets).filter((a) => /\.(dmg|zip)$/.test(a.name)).reduce((n, a) => n + a.download_count, 0);
  if (downloads >= 100) setStat("downloads", compact(downloads)); // too few to be worth showing yet
  for (const a of document.querySelectorAll<HTMLAnchorElement>("[data-release]")) a.href = latest.html_url;
  const dmg = latest.assets.find((a) => a.name.endsWith(".dmg"));
  if (dmg) for (const a of document.querySelectorAll<HTMLAnchorElement>("[data-dmg]")) a.href = dmg.browser_download_url;
};
refresh().catch(() => {});

// Hero scene.
const scene = document.querySelector<HTMLElement>("[data-scene]");
if (scene) startScene(scene);
