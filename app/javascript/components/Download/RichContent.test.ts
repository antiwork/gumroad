// @vitest-environment happy-dom
import { getSchema } from "@tiptap/core";
import { DOMSerializer, Node } from "@tiptap/pm/model";
import StarterKit from "@tiptap/starter-kit";
import { describe, expect, it } from "vitest";

import { RichContentLink } from "$app/components/Download/RichContent";

const schema = getSchema([
  StarterKit,
  RichContentLink.configure({ saleInfo: null, licenseKey: null, rootDomain: "gumroad.com" }),
]);

const renderLink = (href: unknown) => {
  const doc = Node.fromJSON(schema, {
    type: "doc",
    content: [
      { type: "paragraph", content: [{ type: "text", text: "Open", marks: [{ type: "link", attrs: { href } }] }] },
    ],
  });
  const container = document.createElement("div");
  container.appendChild(DOMSerializer.fromSchema(schema).serializeFragment(doc.content));
  return container.querySelector("a");
};

describe("RichContentLink", () => {
  it("renders a seller's link with its href", () => {
    expect(renderLink("https://example.com/guide")?.getAttribute("href")).toBe("https://example.com/guide");
  });

  it("refuses a link whose href is not a string, so an array cannot smuggle in a javascript: URL", () => {
    expect(() => renderLink(["javascript:alert(document.domain)"])).toThrow(TypeError);
  });
});
