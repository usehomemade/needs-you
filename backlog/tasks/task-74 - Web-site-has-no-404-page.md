---
id: TASK-74
title: Web site has no 404 page
status: In Review
assignee: []
created_date: '2026-11-27T12:00:00Z'
labels:
  - bug
  - site
dependencies: []
ordinal: 74000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
site/nginx.conf sends missing pages to /404.html (error_page 404 /404.html), but the site has no 404 page (site/src/pages has only index.astro), so a wrong link on the web site shows nginx's bare default error page. Add site/src/pages/404.astro with the same layout, header and theme as the home page: a short message and a link back home, in light and dark, on phone and desktop.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Added site/src/pages/404.astro (Base layout, short message, link home). `pnpm build` writes dist/404.html. The page is noindex, and the footer's section links now point to /#… so they work from the 404 page too. Checked in the branch preview at /does-not-exist in light and dark, at 1280px and 390px wide. Waiting for the pull request to merge and deploy.
<!-- SECTION:NOTES:END -->
