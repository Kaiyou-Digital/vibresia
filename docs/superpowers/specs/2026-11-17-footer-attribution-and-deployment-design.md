# Footer attribution and deployment design

**Date:** 2026-11-17

## Goal

Resolve the two open GitHub issues and restore the platform-aware download experience on the live site.

## Issue #51: Luros footer attribution

Add `AI Marketing by Luros` to `site/_partials/footer.html`, linking to `https://luros.minithlabs.com`. Place it in the existing Minith Labs attribution line so the footer stays compact. Regenerate all shared-chrome copies with `scripts/inject-chrome.py`, add a regression test for the text and destination, deploy, and close the issue.

## Issue #49: Search Console tile

No repository work is required. The PostHog warehouse insight and dashboard already exist, as recorded in the issue. Add a completion comment with the dashboard and insight links and close the issue.

## Live deployment correction

The live site was still serving the pre-merge page: `/downloads.js` returned HTTP 404 and the homepage did not include the script. The merged code was correct locally. The root cause was that the Worker and static assets had not been deployed after the merge.

Deploy the current `main` checkout with `npx wrangler deploy`, then verify:

- `https://vibresia.com/` contains `/downloads.js` and platform chooser links.
- `https://vibresia.com/downloads.js` returns HTTP 200.
- `https://vibresia.com/download/windows` redirects to the published Windows beta asset.
- A Windows user agent sees `Download for Windows` in the live page.
- The Luros attribution appears in the live footer.

The platform detection remains an accelerator: unknown agents keep the Mac default, while explicit macOS and Windows choices remain available without JavaScript.
