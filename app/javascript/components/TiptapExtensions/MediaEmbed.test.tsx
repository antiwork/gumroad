// @vitest-environment happy-dom
import { describe, expect, it } from "vitest";

import { mediaEmbedUrlCandidates } from "$app/components/TiptapExtensions/MediaEmbed";

const ID = "xwE0xYM0S6k";
const CANONICAL = `https://www.youtube.com/watch?v=${ID}`;

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
