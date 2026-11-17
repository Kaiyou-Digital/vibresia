import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

test("the footer credits AI Marketing by Luros", async () => {
  const footer = await readFile(new URL("./_partials/footer.html", import.meta.url), "utf8");
  assert.match(footer, />AI Marketing by Luros<\/a>/);
  assert.match(footer, /href="https:\/\/luros\.minithlabs\.com"/);
});
