import { readFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import * as sass from "sass";
import { describe, expect, it } from "vitest";

// The entrypoints are read from disk and compiled here: an `import` of a stylesheet is stubbed out
// under vitest, and the assertion has to run against what a recipient's client receives.
const entrypointPath = (name: string) => fileURLToPath(new URL(`../../entrypoints/${name}.scss`, import.meta.url));

const compile = (name: string) => {
  const path = entrypointPath(name);
  return sass.compileString(readFileSync(path, "utf8"), {
    url: pathToFileURL(path),
    loadPaths: ["app/javascript"],
  }).css;
};

// A client that reports a dark preference paints the message background itself, so the app's dark
// tokens land as light text and hairlines on top of it. The email bundle must not ship them.
describe("email stylesheet", () => {
  const css = compile("email");

  it("does not follow the client's dark preference", () => {
    expect(css).not.toContain("prefers-color-scheme");
    expect(css).not.toContain("#242423");
  });

  it("keeps the light tokens the email layout reads", () => {
    expect(css).toContain("--body-bg: #ffffff");
    expect(css).toContain("--color: 0 0 0");
    expect(css).toContain("--border-alpha: 1");
  });
});

describe("app stylesheet", () => {
  it("still ships the dark tokens", () => {
    expect(compile("design")).toContain("#242423");
  });
});
