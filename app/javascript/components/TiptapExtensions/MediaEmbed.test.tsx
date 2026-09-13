// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { EmbedMediaForm, mediaEmbedUrlCandidates } from "$app/components/TiptapExtensions/MediaEmbed";

const state = vi.hoisted(() => ({ requests: new Array<string>(), bodies: new Array<unknown>() }));

vi.mock("$app/utils/request", () => ({
  request: async ({ url }: { url: string }) => {
    state.requests.push(url);
    return { json: async () => state.bodies[state.requests.length - 1] };
  },
  assertResponseError: () => undefined,
}));

const ID = "xwE0xYM0S6k";
const CANONICAL = `https://www.youtube.com/watch?v=${ID}`;
const EMBED = {
  html: '<iframe src="https://iframely.net/api/iframe?url=x"></iframe>',
  title: "Welcome",
  url: CANONICAL,
  provider_name: "YouTube",
};
const NOT_FOUND = { status: 404, error: "The content is no longer available at the origin" };

const askedUrls = () => state.requests.map((url) => new URL(url).searchParams.get("url"));

const insertUrl = async (value: string) => {
  const onEmbedReceived = vi.fn();
  render(<EmbedMediaForm type="embed" onEmbedReceived={onEmbedReceived} onClose={() => undefined} />);
  const input = document.querySelector<HTMLInputElement>("input.top-level-input");
  if (!input) throw new Error("embed input did not mount");
  input.value = value;
  const insert = [...document.querySelectorAll("button")].find((button) => button.textContent === "Insert");
  if (!insert) throw new Error("insert button did not mount");
  await act(async () => {
    fireEvent.click(insert);
  });
  return onEmbedReceived;
};

afterEach(() => {
  cleanup();
  state.requests.length = 0;
  state.bodies.length = 0;
});

describe("mediaEmbedUrlCandidates", () => {
  it("rewrites every YouTube spelling of a video to the canonical watch URL", () => {
    const forms = [
      `https://youtu.be/${ID}`,
      `https://www.youtube.com/watch?v=${ID}`,
      `https://youtube.com/watch?v=${ID}&feature=share`,
      `https://m.youtube.com/watch?v=${ID}`,
      `https://music.youtube.com/watch?v=${ID}`,
      `https://www.youtube.com/shorts/${ID}`,
      `https://www.youtube.com/embed/${ID}`,
      `https://www.youtube.com/live/${ID}`,
      `https://www.youtube-nocookie.com/embed/${ID}`,
      `https://youtu.be/${ID}?si=39y64u9WmoVVivHh`,
    ];

    for (const form of forms) {
      expect(mediaEmbedUrlCandidates(form)[0], form).toBe(CANONICAL);
    }
  });

  it("keeps a start offset, since dropping it would change what the embed plays", () => {
    expect(mediaEmbedUrlCandidates(`https://youtu.be/${ID}?t=42`)[0]).toBe(`${CANONICAL}&t=42`);
    expect(mediaEmbedUrlCandidates(`https://www.youtube.com/watch?v=${ID}&start=1m10s`)[0]).toBe(
      `${CANONICAL}&t=1m10s`,
    );
  });

  it("offers a second, distinct spelling so one poisoned cache key cannot kill the embed", () => {
    expect(mediaEmbedUrlCandidates(`https://youtu.be/${ID}`)).toEqual([
      CANONICAL,
      `https://www.youtube.com/embed/${ID}`,
    ]);
  });

  it("passes a non-YouTube URL through unchanged", () => {
    for (const url of [
      "https://vimeo.com/76979871",
      "https://x.com/gumroad/status/1663556902624845824",
      "https://www.youtube.com/playlist?list=PL1234567890",
      "https://www.youtube.com/@somechannel",
      "https://youtu.be/not-an-id",
      "youtu.be/xwE0xYM0S6k",
      "not a url at all",
    ]) {
      expect(mediaEmbedUrlCandidates(url), url).toEqual([url]);
    }
  });
});

describe("EmbedMediaForm", () => {
  it("asks for the canonical URL and stops there when iframely answers", async () => {
    state.bodies = [EMBED];

    const onEmbedReceived = await insertUrl(`https://youtu.be/${ID}?si=39y64u9WmoVVivHh`);

    expect(askedUrls()).toEqual([CANONICAL]);
    expect(onEmbedReceived).toHaveBeenCalledWith(EMBED);
  });

  it("retries with the fallback spelling before giving up on a stale lookup", async () => {
    state.bodies = [NOT_FOUND, EMBED];

    const onEmbedReceived = await insertUrl(`https://youtu.be/${ID}`);

    expect(askedUrls()).toEqual([CANONICAL, `https://www.youtube.com/embed/${ID}`]);
    expect(onEmbedReceived).toHaveBeenCalledWith(EMBED);
  });

  it("does not retry a non-YouTube URL iframely cannot embed", async () => {
    state.bodies = [NOT_FOUND];

    await insertUrl("https://vimeo.com/76979871");

    expect(askedUrls()).toEqual(["https://vimeo.com/76979871"]);
  });
});
