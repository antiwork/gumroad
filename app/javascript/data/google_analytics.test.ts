// @vitest-environment happy-dom
import loadGoogleAnalyticsScript from "$vendor/google_analytics_4";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  sanitizedPageLocation,
  sanitizedPageReferrer,
  startTrackingForSeller,
  trackHelpVideoEvent,
} from "./google_analytics";

vi.mock("$vendor/google_analytics_4", () => ({ default: vi.fn() }));

const mockedLoadGoogleAnalyticsScript = vi.mocked(loadGoogleAnalyticsScript);

function enableGa() {
  document.head.innerHTML = '<meta property="gr:google_analytics:enabled" content="true">';
}

function stubGtag() {
  const gtag = vi.fn();
  vi.stubGlobal("gtag", gtag);
  return gtag;
}

const sellerConfig = {
  id: "seller-1",
  googleAnalyticsId: "G-SELLERTEST1",
  facebookPixelId: null,
  tiktokPixelId: null,
  trackFreeSales: false,
};

describe("sanitizedPageLocation", () => {
  it("strips reset_password_token so it never reaches analytics (gumroad-private#1260)", () => {
    expect(sanitizedPageLocation("https://gumroad.com/users/password/edit?reset_password_token=abc123SECRET")).toBe(
      "https://gumroad.com/users/password/edit",
    );
  });

  it("strips other single-use secret tokens while keeping harmless params", () => {
    expect(
      sanitizedPageLocation(
        "https://gumroad.com/some/page?confirmation_token=s1&invitation_token=s2&unlock_token=s3&utm_source=email",
      ),
    ).toBe("https://gumroad.com/some/page?utm_source=email");
  });

  it("leaves URLs without sensitive params unchanged", () => {
    expect(sanitizedPageLocation("https://gumroad.com/l/demo?wanted=true")).toBe(
      "https://gumroad.com/l/demo?wanted=true",
    );
  });

  it("returns an empty string for unparseable URLs rather than forwarding them", () => {
    expect(sanitizedPageLocation("not a url")).toBe("");
  });
});

describe("sanitizedPageReferrer", () => {
  it("strips reset_password_token from the referrer so page_referrer never leaks it (gumroad-private#1260)", () => {
    expect(sanitizedPageReferrer("https://gumroad.com/users/password/edit?reset_password_token=abc123SECRET")).toBe(
      "https://gumroad.com/users/password/edit",
    );
  });

  it("keeps an empty referrer empty (GA treats it as no referrer)", () => {
    expect(sanitizedPageReferrer("")).toBe("");
  });

  it("leaves harmless referrers unchanged", () => {
    expect(sanitizedPageReferrer("https://google.com/search?q=gumroad")).toBe("https://google.com/search?q=gumroad");
  });

  it("drops unparseable referrers rather than forwarding them unstripped", () => {
    expect(sanitizedPageReferrer("not a url")).toBe("");
  });
});

describe("startTrackingForSeller", () => {
  beforeEach(() => {
    document.head.innerHTML = "";
    vi.unstubAllGlobals();
    mockedLoadGoogleAnalyticsScript.mockReset();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    mockedLoadGoogleAnalyticsScript.mockReset();
  });

  it("loads gtag for seller-only pages, then issues js before seller config so custom landing events transmit", () => {
    enableGa();
    const gtag = vi.fn();
    mockedLoadGoogleAnalyticsScript.mockImplementation(() => {
      vi.stubGlobal("gtag", gtag);
    });

    startTrackingForSeller(sellerConfig);

    expect(mockedLoadGoogleAnalyticsScript).toHaveBeenCalledOnce();

    expect(gtag).toHaveBeenNthCalledWith(1, "js", expect.any(Date));
    expect(gtag).toHaveBeenNthCalledWith(
      2,
      "config",
      "G-SELLERTEST1",
      expect.objectContaining({ groups: "sellerseller-1", send_page_view: false }),
    );
    expect(gtag).toHaveBeenCalledTimes(2);
  });

  it("does not bootstrap gtag when tracking is off", () => {
    document.head.innerHTML = '<meta property="gr:google_analytics:enabled" content="false">';
    const gtag = stubGtag();

    startTrackingForSeller(sellerConfig);

    expect(gtag).not.toHaveBeenCalled();
  });

  it("does not bootstrap gtag when the seller has no measurement id", () => {
    enableGa();
    const gtag = stubGtag();

    startTrackingForSeller({ ...sellerConfig, googleAnalyticsId: null });

    expect(gtag).not.toHaveBeenCalled();
  });
});

describe("trackHelpVideoEvent", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("sends recommended video events to the Gumroad GA property", () => {
    enableGa();
    const gtag = stubGtag();

    trackHelpVideoEvent("video_start", {
      videoId: "beginner-walkthrough",
      title: "Beginner walkthrough: set up a course",
      url: "/images/help_center/beginner-walkthrough.mp4",
    });
    trackHelpVideoEvent("video_progress", {
      videoId: "beginner-walkthrough",
      title: "Beginner walkthrough: set up a course",
      url: "/images/help_center/beginner-walkthrough.mp4",
      percent: 50,
    });

    expect(gtag).toHaveBeenCalledWith(
      "event",
      "video_start",
      expect.objectContaining({
        send_to: "gumroad",
        video_id: "beginner-walkthrough",
        video_provider: "gumroad",
      }),
    );
    expect(gtag).toHaveBeenCalledWith(
      "event",
      "video_progress",
      expect.objectContaining({ video_percent: 50, send_to: "gumroad" }),
    );
  });

  it("does not send when tracking is off", () => {
    document.head.innerHTML = '<meta property="gr:google_analytics:enabled" content="false">';
    const gtag = stubGtag();

    trackHelpVideoEvent("video_complete", {
      videoId: "beginner-walkthrough",
      title: "Walkthrough",
      url: "/video.mp4",
      percent: 100,
    });

    expect(gtag).not.toHaveBeenCalled();
  });
});
