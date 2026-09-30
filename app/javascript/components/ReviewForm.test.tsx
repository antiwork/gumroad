// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { getReviewVideoUploadContext } from "$app/data/product_reviews";
import { LoggedInUserLayout } from "$app/inertia/layout";
import { ResponseError } from "$app/utils/request";

import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { LoggedInUserProvider, parseLoggedInUser } from "$app/components/LoggedInUser";
import { ReviewForm, type Review } from "$app/components/ReviewForm";

const mocks = vi.hoisted(() => {
  const pageProps: Record<string, unknown> = {};
  return { getReviewVideoUploadContext: vi.fn(), setProductRating: vi.fn(), pageProps };
});

vi.mock("$app/data/product_reviews", () => ({
  getReviewVideoUploadContext: mocks.getReviewVideoUploadContext,
  setProductRating: mocks.setProductRating,
}));
vi.mock("$vendor/evaporate.cjs", () => ({ default: vi.fn() }));
vi.mock("@inertiajs/react", () => ({
  usePage: () => ({ props: mocks.pageProps }),
  router: { replaceProp: vi.fn() },
}));
vi.mock("$app/layouts/components/MetaTags", () => ({ default: () => null }));
vi.mock("$app/components/CurrentSeller", () => ({
  CurrentSellerProvider: ({ children }: { children: React.ReactNode }) => children,
  parseCurrentSeller: () => null,
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn(), default: () => null }));
vi.mock("$app/components/ReviewForm/ReviewVideoRecorder", () => ({ ReviewVideoRecorder: () => null }));

const mockGetReviewVideoUploadContext = vi.mocked(getReviewVideoUploadContext);

beforeAll(() => {
  Object.assign(globalThis, {
    Routes: new Proxy({}, { get: (_target, name: string) => () => `/${String(name).replace(/_path$|_url$/u, "")}` }),
  });
});

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

const uploadContext = { aws_access_key_id: "key", s3_url: "https://s3.example.com/bucket", user_id: "user-id" };

const rawLoggedInUser = {
  id: "user-id",
  email: "buyer@example.com",
  name: "Buyer",
  avatar_url: "https://example.com/avatar.png",
  confirmed: true,
  team_memberships: [],
  can_create_brand_account: false,
  has_payout_setup_to_port: false,
  can_port_bank_payout_setup: false,
  will_copy_bank_payout: false,
  policies: {
    affiliate_requests_onboarding_form: { update: false },
    direct_affiliate: { create: false, update: false },
    collaborator: { create: false, update: false },
    product: { create: false },
    product_review_response: { update: false },
    balance: { index: false, export: false },
    checkout_offer_code: { create: false },
    checkout_form: { update: false },
    upsell: { create: false },
    settings_payments_user: { show: false },
    settings_main_user: { update_username: false },
    settings_profile: { manage_social_connections: false, update: false },
    settings_third_party_analytics_user: { update: false },
    installment: { create: false },
    workflow: { create: false },
    utm_link: { index: false },
    community: { index: false },
    churn: { show: false },
    page: { index: false, create: false },
    user: { view_store_agent: false, use_store_agent: false },
  },
  promoted_nav_items: [],
  lazy_load_offscreen_discover_images: false,
};

const domains = {
  scheme: "https",
  appDomain: "app.example.com",
  rootDomain: "example.com",
  shortDomain: "short.example.com",
  discoverDomain: "discover.example.com",
  thirdPartyAnalyticsDomain: "analytics.example.com",
  apiDomain: "api.example.com",
};

const savedReview = (video: Review["video"] = null): Review => ({
  anonymous: false,
  rating: 4,
  message: null,
  video,
});

const form = (props: Partial<React.ComponentProps<typeof ReviewForm>> = {}, key?: string) => (
  <ReviewForm
    key={key}
    permalink="alpha"
    purchaseId="purchase-id"
    purchaseEmailDigest="digest"
    review={null}
    {...props}
  />
);

const withProviders = (children: React.ReactNode, loggedIn = true) => (
  <DomainSettingsProvider value={domains}>
    <LoggedInUserProvider value={loggedIn ? parseLoggedInUser(rawLoggedInUser) : null}>{children}</LoggedInUserProvider>
  </DomainSettingsProvider>
);

const postButton = () => screen.getByRole<HTMLButtonElement>("button", { name: "Update review" });
const chooseVideoReview = () => fireEvent.click(screen.getByRole("radio", { name: "Video review" }));
const chooseTextReview = () => fireEvent.click(screen.getByRole("radio", { name: "Text review" }));

describe("ReviewForm upload context", () => {
  describe("while no video can be recorded", () => {
    it("does not request the upload context when a logged-in buyer opens a new review form", () => {
      render(withProviders(form()));

      expect(mockGetReviewVideoUploadContext).not.toHaveBeenCalled();
    });

    it("does not request the upload context for every form on a page listing many purchases awaiting review", () => {
      const purchaseIds = Array.from({ length: 91 }, (_, index) => `purchase-${index}`);

      render(withProviders(<>{purchaseIds.map((purchaseId) => form({ purchaseId }, purchaseId))}</>));

      expect(screen.getAllByRole("radio", { name: "Text review" })).toHaveLength(91);
      expect(mockGetReviewVideoUploadContext).not.toHaveBeenCalled();
    });

    it("does not request the upload context when an existing text review is shown", () => {
      render(withProviders(form({ review: savedReview() })));

      expect(screen.getByText("Your rating:")).toBeTruthy();
      expect(mockGetReviewVideoUploadContext).not.toHaveBeenCalled();
    });

    it("does not request the upload context when an existing video review is only being viewed", () => {
      render(withProviders(form({ review: savedReview({ id: "video-id", thumbnail_url: null }) })));

      expect(screen.queryByRole("radio", { name: "Video review" })).toBeNull();
      expect(mockGetReviewVideoUploadContext).not.toHaveBeenCalled();
    });

    it("does not request the upload context for a preview form even in video mode", () => {
      render(withProviders(form({ preview: true })));

      chooseVideoReview();

      expect(mockGetReviewVideoUploadContext).not.toHaveBeenCalled();
    });

    it("does not request the upload context for a logged-out buyer who picks video review", () => {
      render(withProviders(form(), false));

      chooseVideoReview();

      expect(screen.getByRole("link", { name: "Log in" })).toBeTruthy();
      expect(mockGetReviewVideoUploadContext).not.toHaveBeenCalled();
    });
  });

  describe("when the buyer chooses a video review", () => {
    it("requests the upload context once and enables posting after it arrives", async () => {
      mockGetReviewVideoUploadContext.mockResolvedValue(uploadContext);
      render(withProviders(form({ review: savedReview() })));
      fireEvent.click(screen.getByRole("button", { name: "Edit" }));

      expect(mockGetReviewVideoUploadContext).not.toHaveBeenCalled();
      chooseVideoReview();

      expect(mockGetReviewVideoUploadContext).toHaveBeenCalledTimes(1);
      await waitFor(() => expect(postButton().disabled).toBe(false));
      expect(screen.queryByText("Failed to get upload context")).toBeNull();
    });

    it("keeps posting disabled while the upload context is still loading", () => {
      mockGetReviewVideoUploadContext.mockReturnValue(new Promise(() => {}));
      render(withProviders(form({ review: savedReview() })));
      fireEvent.click(screen.getByRole("button", { name: "Edit" }));

      chooseVideoReview();

      expect(mockGetReviewVideoUploadContext).toHaveBeenCalledTimes(1);
      expect(postButton().disabled).toBe(true);
    });

    it("requests the upload context when an existing video review is opened for editing", async () => {
      mockGetReviewVideoUploadContext.mockResolvedValue(uploadContext);
      render(withProviders(form({ review: savedReview({ id: "video-id", thumbnail_url: null }) })));

      fireEvent.click(screen.getByRole("button", { name: "Edit" }));

      expect(mockGetReviewVideoUploadContext).toHaveBeenCalledTimes(1);
      await waitFor(() => expect(postButton().disabled).toBe(false));
    });

    it("reuses the loaded upload context when the buyer switches between text and video review", async () => {
      mockGetReviewVideoUploadContext.mockResolvedValue(uploadContext);
      render(withProviders(form({ review: savedReview() })));
      fireEvent.click(screen.getByRole("button", { name: "Edit" }));

      chooseVideoReview();
      await waitFor(() => expect(postButton().disabled).toBe(false));
      chooseTextReview();
      chooseVideoReview();

      expect(postButton().disabled).toBe(false);
      expect(mockGetReviewVideoUploadContext).toHaveBeenCalledTimes(1);
    });

    it("does not request the upload context again when the page re-renders its logged-in user", async () => {
      mockGetReviewVideoUploadContext.mockResolvedValue(uploadContext);
      const tree = () => withProviders(form({ review: savedReview() }));
      const { rerender } = render(tree());
      fireEvent.click(screen.getByRole("button", { name: "Edit" }));
      chooseVideoReview();
      await waitFor(() => expect(postButton().disabled).toBe(false));

      // Each render of a layout parses a fresh logged-in user object, so every re-render hands the
      // form a new object with the same contents.
      for (let poll = 0; poll < 5; poll++) rerender(tree());

      expect(mockGetReviewVideoUploadContext).toHaveBeenCalledTimes(1);
    });

    it("does not request the upload context while the page re-renders during a pending request", () => {
      mockGetReviewVideoUploadContext.mockReturnValue(new Promise(() => {}));
      const tree = () => withProviders(form({ review: savedReview() }));
      const { rerender } = render(tree());
      fireEvent.click(screen.getByRole("button", { name: "Edit" }));
      chooseVideoReview();

      for (let poll = 0; poll < 5; poll++) rerender(tree());

      expect(mockGetReviewVideoUploadContext).toHaveBeenCalledTimes(1);
    });
  });

  describe("when the upload context cannot be loaded", () => {
    it("shows the failure and keeps posting disabled", async () => {
      mockGetReviewVideoUploadContext.mockRejectedValue(new ResponseError());
      render(withProviders(form({ review: savedReview() })));
      fireEvent.click(screen.getByRole("button", { name: "Edit" }));

      chooseVideoReview();

      expect(await screen.findByText("Failed to get upload context")).toBeTruthy();
      expect(postButton().disabled).toBe(true);
    });

    it("does not retry on its own while the page re-renders", async () => {
      mockGetReviewVideoUploadContext.mockRejectedValue(new ResponseError());
      const tree = () => withProviders(form({ review: savedReview() }));
      const { rerender } = render(tree());
      fireEvent.click(screen.getByRole("button", { name: "Edit" }));
      chooseVideoReview();
      await screen.findByText("Failed to get upload context");

      for (let poll = 0; poll < 5; poll++) rerender(tree());

      expect(mockGetReviewVideoUploadContext).toHaveBeenCalledTimes(1);
    });

    it("retries when the buyer leaves and re-enters video review, and clears the failure once it loads", async () => {
      mockGetReviewVideoUploadContext.mockRejectedValueOnce(new ResponseError());
      mockGetReviewVideoUploadContext.mockResolvedValueOnce(uploadContext);
      render(withProviders(form({ review: savedReview() })));
      fireEvent.click(screen.getByRole("button", { name: "Edit" }));
      chooseVideoReview();
      await screen.findByText("Failed to get upload context");

      chooseTextReview();
      chooseVideoReview();

      await waitFor(() => expect(postButton().disabled).toBe(false));
      expect(screen.queryByText("Failed to get upload context")).toBeNull();
      expect(mockGetReviewVideoUploadContext).toHaveBeenCalledTimes(2);
    });
  });

  describe("inside the Inertia layout that re-renders on every page poll", () => {
    const renderInLayout = () => {
      Object.assign(mocks.pageProps, { flash: null, logged_in_user: rawLoggedInUser, current_seller: null });
      const tree = () => (
        <DomainSettingsProvider value={domains}>
          <LoggedInUserLayout>{form({ review: savedReview() })}</LoggedInUserLayout>
        </DomainSettingsProvider>
      );
      return { ...render(tree()), tree };
    };

    it("does not request the upload context from any layout re-render while the form is in text mode", () => {
      const { rerender, tree } = renderInLayout();

      for (let poll = 0; poll < 5; poll++) rerender(tree());

      expect(mockGetReviewVideoUploadContext).not.toHaveBeenCalled();
    });

    it("requests the upload context once across layout re-renders in video mode", async () => {
      mockGetReviewVideoUploadContext.mockResolvedValue(uploadContext);
      const { rerender, tree } = renderInLayout();
      fireEvent.click(screen.getByRole("button", { name: "Edit" }));
      chooseVideoReview();
      await waitFor(() => expect(postButton().disabled).toBe(false));

      for (let poll = 0; poll < 5; poll++) rerender(tree());

      expect(mockGetReviewVideoUploadContext).toHaveBeenCalledTimes(1);
    });
  });
});
