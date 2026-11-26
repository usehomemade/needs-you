/**
 * Repo links for the page. Every number (stars, version, release date,
 * release count, downloads) and the DMG link is fetched live from the GitHub
 * API in the browser on each page load (scripts/page.ts); nothing is baked in.
 */
export const REPO = "usehomemade/needs-you";
export const REPO_URL = `https://github.com/${REPO}`;
export const RELEASES_URL = `${REPO_URL}/releases`;
export const LATEST_URL = `${RELEASES_URL}/latest`;
export const LICENSE_URL = `${REPO_URL}/blob/main/LICENSE`;
