/**
 * Repo numbers for the page, read from the public GitHub API at build time.
 * The page refreshes them in the browser too (see Stats script), so a stale
 * build still shows today's stars. Every field has a fallback: a failed or
 * rate-limited request never breaks the build.
 */
export const REPO = "usehomemade/needs-you";
export const REPO_URL = `https://github.com/${REPO}`;
export const RELEASES_URL = `${REPO_URL}/releases`;
export const LATEST_URL = `${RELEASES_URL}/latest`;
export const LICENSE_URL = `${REPO_URL}/blob/main/LICENSE`;

export interface RepoStats {
  stars: number | null;
  version: string;
  releasedAt: string | null;
  releases: number | null;
  downloads: number | null;
  dmgUrl: string;
  releaseUrl: string;
}

/** Used when GitHub can't be reached at build time. */
const FALLBACK: RepoStats = {
  stars: null,
  version: "1.5.0",
  releasedAt: null,
  releases: null,
  downloads: null,
  dmgUrl: LATEST_URL,
  releaseUrl: LATEST_URL,
};

interface Asset {
  name: string;
  download_count: number;
  browser_download_url: string;
}
interface Release {
  tag_name: string;
  html_url: string;
  published_at: string;
  draft: boolean;
  prerelease: boolean;
  assets: Asset[];
}

const api = async <T>(path: string): Promise<T> => {
  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "User-Agent": "needs-you-site",
  };
  const token = process.env.GITHUB_TOKEN;
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(`https://api.github.com${path}`, { headers });
  if (!res.ok) throw new Error(`GitHub ${path}: ${res.status}`);
  return (await res.json()) as T;
};

let cached: Promise<RepoStats> | null = null;

export const repoStats = (): Promise<RepoStats> => {
  cached ??= (async () => {
    const stats = { ...FALLBACK };
    const [repo, releases] = await Promise.allSettled([
      api<{ stargazers_count: number }>(`/repos/${REPO}`),
      api<Release[]>(`/repos/${REPO}/releases?per_page=100`),
    ]);
    if (repo.status === "fulfilled") stats.stars = repo.value.stargazers_count;
    if (releases.status === "fulfilled") {
      const list = releases.value.filter((r) => !r.draft && !r.prerelease);
      const latest = list[0];
      if (latest) {
        stats.version = latest.tag_name.replace(/^v/, "");
        stats.releasedAt = latest.published_at;
        stats.releaseUrl = latest.html_url;
        const dmg = latest.assets.find((a) => a.name.endsWith(".dmg"));
        if (dmg) stats.dmgUrl = dmg.browser_download_url;
      }
      stats.releases = list.length;
      // Installs: DMG and zip downloads (the zip is what in-app updates fetch).
      stats.downloads = list
        .flatMap((r) => r.assets)
        .filter((a) => /\.(dmg|zip)$/.test(a.name))
        .reduce((n, a) => n + a.download_count, 0);
    }
    if (repo.status === "rejected" || releases.status === "rejected") {
      console.warn("[github] using fallback numbers for part of the page");
    }
    return stats;
  })();
  return cached;
};

export const compact = (n: number): string =>
  n >= 1000
    ? `${(n / 1000).toFixed(n >= 10000 ? 0 : 1).replace(/\.0$/, "")}k`
    : String(n);
