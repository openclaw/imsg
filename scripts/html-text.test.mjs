import assert from "node:assert/strict";
import test from "node:test";

import { stripHtmlTags } from "./html-text.mjs";

test("stripHtmlTags removes nested and unterminated markup in one pass", () => {
  assert.equal(
    stripHtmlTags('<a class="anchor" href="#heading">#</a><em>Heading</em>'),
    "#Heading",
  );
  assert.equal(stripHtmlTags("<strong>broken"), "broken");
  assert.equal(stripHtmlTags("Heading <strong"), "Heading ");
  assert.equal(stripHtmlTags('<span title="1 > 0">Heading</span>'), "Heading");
  assert.equal(stripHtmlTags("1 < 2"), "1 < 2");
  assert.equal(stripHtmlTags("<<<script>img>"), "img>");
});
