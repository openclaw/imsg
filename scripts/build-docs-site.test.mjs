import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const builder = path.join(repoRoot, "scripts", "build-docs-site.mjs");

function buildPage(t, body) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "imsg-docs-test-"));
  const docs = path.join(root, "docs");
  fs.mkdirSync(docs);
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const writeDoc = (name, content) => fs.writeFileSync(path.join(docs, name), content);
  writeDoc("index.md", "# Home\n\nWelcome.\n");
  writeDoc("install.md", "# Install\n\nInstall locally.\n");
  writeDoc("quickstart.md", "# Quickstart\n\nStart locally.\n");
  writeDoc("cli.md", body);

  execFileSync(process.execPath, [builder], { cwd: root });
  const first = fs.readFileSync(path.join(root, "dist", "docs-site", "cli.html"), "utf8");
  execFileSync(process.execPath, [builder], { cwd: root });
  const second = fs.readFileSync(path.join(root, "dist", "docs-site", "cli.html"), "utf8");

  assert.equal(second, first);
  return first;
}

function pageToc(page) {
  return page.match(/<nav class="toc"[\s\S]*?<\/nav>/)?.[0];
}

test("escapes malicious heading text once in the TOC", (t) => {
  const page = buildPage(
    t,
    [
      "# CLI",
      "",
      "## Safe",
      "",
      '## <img src=x onerror=alert("toc")> <scr<script>ipt>alert("toc")</scr<script>ipt>',
      "",
    ].join("\n"),
  );
  const toc = pageToc(page);

  assert.equal(
    toc,
    '<nav class="toc" aria-label="On this page"><h2>On this page</h2>' +
      '<a class="toc-l2" href="#safe">Safe</a>' +
      '<a class="toc-l2" href="#img-src-x-onerror-alert-toc-scr-script-ipt-alert-toc-scr-script-ipt">' +
      '&lt;img src=x onerror=alert(&quot;toc&quot;)&gt; ' +
      '&lt;scr&lt;script&gt;ipt&gt;alert(&quot;toc&quot;)&lt;/scr&lt;script&gt;ipt&gt;</a></nav>',
  );
  assert.doesNotMatch(toc, /&amp;lt;|<img|<script/i);
});

test("renders deterministic TOC entries with unique heading anchors", (t) => {
  const page = buildPage(
    t,
    [
      "# CLI",
      "",
      "## Repeat",
      "",
      "> ### **Nested [label](https://example.com)** and `code`",
      "",
      "## Repeat",
      "",
      "## Repeat 2",
      "",
      "### Fish &amp; Chips",
      "",
    ].join("\n"),
  );
  const toc = pageToc(page);

  assert.equal(
    toc,
    '<nav class="toc" aria-label="On this page"><h2>On this page</h2>' +
      '<a class="toc-l2" href="#repeat">Repeat</a>' +
      '<a class="toc-l3" href="#nested-label-https-example-com-and-code">Nested label and code</a>' +
      '<a class="toc-l2" href="#repeat-2">Repeat</a>' +
      '<a class="toc-l2" href="#repeat-2-2">Repeat 2</a>' +
      '<a class="toc-l3" href="#fish-amp-chips">Fish &amp;amp; Chips</a></nav>',
  );

  const headingIds = [...page.matchAll(/<h[23] id="([^"]+)"/g)].map((match) => match[1]);
  const tocIds = [...toc.matchAll(/href="#([^"]+)"/g)].map((match) => match[1]);
  assert.deepEqual(headingIds, tocIds);
  assert.equal(new Set(headingIds).size, headingIds.length);
  assert.match(
    page,
    /<h3 id="nested-label-https-example-com-and-code">[^<]*<a class="anchor"[^>]*>#<\/a><strong>Nested <a href="https:\/\/example\.com">label<\/a><\/strong> and <code>code<\/code><\/h3>/,
  );
});
