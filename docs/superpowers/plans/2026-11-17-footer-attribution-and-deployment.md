# Footer Attribution and Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the Luros footer attribution, deploy the merged Worker and static assets, verify the live platform-aware downloads, and close the two open GitHub issues.

**Architecture:** The shared footer partial remains the single source of truth for attribution and is propagated with the existing chrome injector. The Worker deployment publishes both `worker/index.js` and the `site/` static assets, so one Wrangler deploy restores the Windows download script and its routes.

**Tech Stack:** Static HTML, Node.js test runner, Python chrome injector, Cloudflare Wrangler, GitHub CLI.

---

### Task 1: Add the Luros attribution

**Files:**
- Modify: `site/_partials/footer.html`
- Create: `site/footer.test.js`
- Regenerate: all HTML pages with shared chrome markers

- [ ] **Step 1: Write the failing regression test**

Create `site/footer.test.js` with a test that reads the shared partial and asserts it contains the exact label and destination.

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

test("the footer credits AI Marketing by Luros", async () => {
  const footer = await readFile(new URL("./_partials/footer.html", import.meta.url), "utf8");
  assert.match(footer, />AI Marketing by Luros<\/a>/);
  assert.match(footer, /href="https:\/\/luros\.minithlabs\.com"/);
});
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `node --test site/footer.test.js`
Expected: FAIL because the attribution is absent.

- [ ] **Step 3: Update the shared footer**

Place the attribution in the existing Minith Labs line:

```html
<p>🩷 from <a href="https://minithlabs.com">Minith Labs</a> · <a href="https://luros.minithlabs.com">AI Marketing by Luros</a> · <a href="https://github.com/sydlawrencedev/vibresia">Source on GitHub</a> · <a href="https://github.com/sydlawrencedev/vibresia/issues">Report an issue</a></p>
```

- [ ] **Step 4: Propagate the shared footer**

Run: `python3 scripts/inject-chrome.py "$PWD"`
Expected: `navbar and footer injected into ... page(s)`.

- [ ] **Step 5: Verify the test and chrome**

Run:

```bash
node --test site/footer.test.js
python3 scripts/inject-chrome.py --check "$PWD"
```

Expected: PASS.

- [ ] **Step 6: Commit only scoped paths**

```bash
git add site/_partials/footer.html site/footer.test.js site/index.html site/agents.html site/vibescapes.html site/vibe.html site/admin.html site/privacy.html site/terms.html site/author/syd-lawrence.html site/comparison.html site/blog site/comparison site/share site/stats/data
git commit -m "feat: credit AI Marketing by Luros"
```

### Task 2: Verify and deploy

**Files:**
- No code changes expected.

- [ ] **Step 1: Run the complete local verification**

Run:

```bash
npm test
python3 scripts/inject-chrome.py --check "$PWD"
node scripts/check-links.mjs
```

Expected: all tests and checks pass.

- [ ] **Step 2: Push the attribution commit**

Run: `git push origin main`
Expected: `main` advances on the remote.

- [ ] **Step 3: Deploy the Worker and static assets**

Run: `npx wrangler deploy`
Expected: Wrangler reports a successful deployment and version ID.

- [ ] **Step 4: Verify the live site**

Run:

```bash
curl -sS https://vibresia.com/ | grep -F 'downloads.js'
curl -sS -o /dev/null -w '%{http_code}\n' https://vibresia.com/downloads.js
curl -sSI https://vibresia.com/download/windows | grep -i '^location:'
curl -sS https://vibresia.com/ | grep -F 'AI Marketing by Luros'
```

Expected:

- The homepage contains `/downloads.js`.
- `/downloads.js` returns `200`.
- `/download/windows` redirects to the `windows-v0.1.0` asset.
- The homepage contains `AI Marketing by Luros`.

- [ ] **Step 5: Verify the Windows browser behaviour**

Use the available browser tooling with a Windows user agent, or add a temporary local HTTP server and use Chromium DevTools with a Windows user-agent override. Confirm the primary CTA reads `Download for Windows` and points to `/download/windows`. Remove any temporary files afterward.

### Task 3: Close the issues

- [ ] **Step 1: Comment on and close issue #49**

Run:

```bash
gh issue comment 49 --body "Completed. The Search Console warehouse insight is live on the Search pages by template dashboard, with the links recorded in this issue. No repository change was needed."
gh issue close 49
```

- [ ] **Step 2: Comment on and close issue #51**

Run:

```bash
gh issue comment 51 --body "Added the AI Marketing by Luros attribution to the shared site footer and deployed it."
gh issue close 51
```

- [ ] **Step 3: Confirm repository and issue state**

Run:

```bash
gh issue list --state open
git status --short --branch
```

Expected: no open issues and a clean tracked working tree.
