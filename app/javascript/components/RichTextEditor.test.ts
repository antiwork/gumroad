import { describe, expect, it } from "vitest";

import { getSchema } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";

import { dropUnknownNodes, validateUrl } from "$app/components/RichTextEditor";

describe("validateUrl", () => {
  it("rejects empty input", () => {
    expect(validateUrl()).toBe(false);
    expect(validateUrl("")).toBe(false);
    expect(validateUrl("   ")).toBe(false);
  });

  it("adds https:// when no scheme is given", () => {
    expect(validateUrl("example.com")).toBe("https://example.com/");
    expect(validateUrl("example.com/path?a=1")).toBe("https://example.com/path?a=1");
  });

  it("adds https:// to a bare host with a port, rather than reading the host as a scheme", () => {
    expect(validateUrl("example.com:8080/path")).toBe("https://example.com:8080/path");
  });

  it("repairs mistyped http(s) schemes", () => {
    expect(validateUrl("http:/example.com")).toBe("https://example.com/");
    expect(validateUrl("https//example.com")).toBe("https://example.com/");
  });

  it("keeps custom app schemes so sellers can deep-link into their own app", () => {
    expect(validateUrl("goodsnooze://activate?key=__license_key__")).toBe("goodsnooze://activate?key=__license_key__");
    expect(validateUrl("my-app.desktop://open")).toBe("my-app.desktop://open");
  });

  it("rejects schemes that can execute script or read local resources", () => {
    expect(validateUrl("javascript://%0aalert(1)")).toBe(false);
    expect(validateUrl("JavaScript://alert(1)")).toBe(false);
    expect(validateUrl("data://text/html,<script>alert(1)</script>")).toBe(false);
    expect(validateUrl("vbscript://msgbox(1)")).toBe(false);
    expect(validateUrl("file:///etc/passwd")).toBe(false);
    expect(validateUrl("blob://something")).toBe(false);
  });

  it("rejects input that is not a URL at all", () => {
    expect(validateUrl("http://")).toBe(false);
  });
});

describe("dropUnknownNodes", () => {
  const schema = getSchema([StarterKit]);

  it("drops a node type the schema doesn't know, keeping its siblings", () => {
    const content = [
      { type: "paragraph", content: [{ type: "text", text: "before" }] },
      { type: "license", attrs: {} },
      { type: "paragraph", content: [{ type: "text", text: "after" }] },
    ];

    expect(dropUnknownNodes(content, schema)).toEqual([
      { type: "paragraph", content: [{ type: "text", text: "before" }] },
      { type: "paragraph", content: [{ type: "text", text: "after" }] },
    ]);
  });

  it("drops an unknown node nested inside a known container without dropping the container", () => {
    const content = [
      {
        type: "blockquote",
        content: [{ type: "license", attrs: {} }, { type: "paragraph", content: [{ type: "text", text: "kept" }] }],
      },
    ];

    expect(dropUnknownNodes(content, schema)).toEqual([
      { type: "blockquote", content: [{ type: "paragraph", content: [{ type: "text", text: "kept" }] }] },
    ]);
  });

  it("leaves a document made only of known node types untouched", () => {
    const content = [{ type: "paragraph", content: [{ type: "text", text: "hello" }] }];
    expect(dropUnknownNodes(content, schema)).toEqual(content);
  });
});
