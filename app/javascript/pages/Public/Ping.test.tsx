// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import { spawnSync } from "node:child_process";
import { createHmac } from "node:crypto";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import Ping from "$app/pages/Public/Ping";
import { cast } from "$app/utils/cast";

vi.mock("$app/components/Developer/Layout", () => ({
  Layout: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));

const SECRET = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const BODY = "sale_id=1&product_name=Caf%C3%A9&custom=café";
const SKEW_PAST_LIMIT_SECONDS = 600;

type VerifyCase = { t: string; v1: string; body: string };
type VerifyResult = { code: number; message?: string } | { error: string };

// The snippets are fragments, so each runs as the body of a function over the header's t and v1 and
// the raw body bytes; a rejection becomes { code, message } and anything thrown becomes { error }.
const NODE_HARNESS = `
const crypto = require("node:crypto");
const { snippet, secret, cases } = JSON.parse(require("node:fs").readFileSync(0, "utf8"));
const verify = new Function("crypto", "secret", "t", "v1", "rawBody", "res", snippet);
const res = { status: (code) => ({ send: (message) => ({ code, message }) }) };
const results = cases.map(({ t, v1, body }) => {
  try {
    return verify(crypto, secret, t, v1, Buffer.from(body, "utf8"), res) ?? { code: 200 };
  } catch (error) {
    return { error: String(error) };
  }
});
process.stdout.write(JSON.stringify(results));
`;

const PYTHON_HARNESS = `
import hashlib, hmac, json, sys, textwrap, time

class Rejected(Exception):
    pass

def abort(code, message):
    raise Rejected(code, message)

data = json.load(sys.stdin)
exec("def verify(secret, t, v1, raw_body):\\n" + textwrap.indent(data["snippet"], "    "))
results = []
for case in data["cases"]:
    try:
        verify(data["secret"], case["t"], case["v1"], case["body"].encode())
        results.append({"code": 200})
    except Rejected as rejection:
        results.append({"code": rejection.args[0], "message": rejection.args[1]})
    except Exception as error:
        results.append({"error": repr(error)})
print(json.dumps(results))
`;

const snippet = (caption: string) => {
  const code = screen.getByText(caption).closest("figure")?.querySelector("code")?.textContent;
  if (!code) throw new Error(`Could not find the ${caption} snippet`);
  return code;
};

const run = (command: string, args: string[], snippetSource: string, cases: VerifyCase[]): VerifyResult[] => {
  const result = spawnSync(command, args, { input: JSON.stringify({ snippet: snippetSource, secret: SECRET, cases }) });
  if (result.status !== 0) throw new Error(`${command} exited ${result.status}: ${result.stderr.toString()}`);
  return cast<VerifyResult[]>(JSON.parse(result.stdout.toString()));
};

const sign = (t: string, body: string) => createHmac("sha256", SECRET).update(`${t}.${body}`).digest("hex");

const verifyCases = () => {
  const now = Math.floor(Date.now() / 1000);
  const fresh = String(now);
  const past = String(now - SKEW_PAST_LIMIT_SECONDS);
  const future = String(now + SKEW_PAST_LIMIT_SECONDS);
  const cases: Record<string, VerifyCase> = {
    valid: { t: fresh, v1: sign(fresh, BODY), body: BODY },
    tamperedBody: { t: fresh, v1: sign(fresh, BODY), body: `${BODY}&price=0` },
    stale: { t: past, v1: sign(past, BODY), body: BODY },
    future: { t: future, v1: sign(future, BODY), body: BODY },
    unicodeSignature: { t: fresh, v1: "é".repeat(64), body: BODY },
    shortSignature: { t: fresh, v1: "abc", body: BODY },
    malformedTimestamp: { t: "soon", v1: sign("soon", BODY), body: BODY },
  };
  return { names: Object.keys(cases), cases: Object.values(cases) };
};

const expectedResults = {
  valid: { code: 200 },
  tamperedBody: { code: 400, message: "bad signature" },
  stale: { code: 400, message: "stale" },
  future: { code: 400, message: "stale" },
  unicodeSignature: { code: 400, message: "bad signature" },
  shortSignature: { code: 400, message: "bad signature" },
  malformedTimestamp: { code: 400, message: "stale" },
};

beforeEach(() => vi.stubGlobal("Routes", { settings_advanced_path: () => "/settings/advanced", api_path: () => "/api" }));
afterEach(cleanup);

describe("Ping receiver verification snippets", () => {
  it.each([
    ["Node", process.execPath, ["-e", NODE_HARNESS]],
    ["Python", "python3", ["-I", "-c", PYTHON_HARNESS]],
  ])("the %s snippet accepts only a fresh, matching signature and refuses malformed input cleanly", (caption, command, args) => {
    render(<Ping />);
    const { names, cases } = verifyCases();

    const results = run(command, args, snippet(caption), cases);

    expect(Object.fromEntries(names.map((name, index) => [name, results[index]]))).toEqual(expectedResults);
  });
});
