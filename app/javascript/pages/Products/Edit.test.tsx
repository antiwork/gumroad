// @vitest-environment happy-dom
import { act, cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

import ProductEditInertiaPage from "$app/pages/Products/Edit";
import { installPopstateClaims, markVisitStarted } from "$app/utils/popstateClaims";

Object.assign(globalThis, { SSR: false });

// One entry per LazyProductEditPage INSTANCE lifetime. The editor seeds its
// state from props once (useState(props.product)), so navigating between
// products must remount it — the key by product id is what guarantees that.
const mounts = vi.hoisted((): string[] => []);
vi.mock("$app/components/ProductEdit/load", () => ({
  LazyProductEditPage: ({ id }: { id: string }) => {
    React.useEffect(() => {
      mounts.push(id);
    }, []);
    return null;
  },
}));

// How Inertia answers a visit: `onSuccess` runs only when the server responded with props,
// `onFinish` always runs, carrying the flags that say how the visit ended.
type Visit = { completed: boolean; cancelled: boolean; interrupted: boolean };
type ReloadOptions = { onSuccess: () => void; onFinish: (visit: Visit) => void };

const inertia = vi.hoisted(() => {
  const reload = vi.fn<(options: ReloadOptions) => void>();
  // `router.on` subscribers. The page uses the global "finish" event to wait out the visit that
  // replaced a reload it could not use, so the mock has to let a test fire one.
  const finishListeners = new Set<() => void>();
  const on = vi.fn((event: string, callback: () => void) => {
    if (event === "finish") finishListeners.add(callback);
    return () => finishListeners.delete(callback);
  });
  const emitFinish = () => {
    for (const callback of [...finishListeners]) callback();
  };
  const locationReload = vi.fn();
  return { reload, on, finishListeners, emitFinish, locationReload };
});

const pageProps = vi.hoisted((): { current: Record<string, unknown> } => ({ current: {} }));
vi.mock("@inertiajs/react", () => ({
  usePage: () => ({ props: pageProps.current }),
  router: { reload: inertia.reload, on: inertia.on },
}));

vi.mock("$app/hooks/useDropbox", () => ({ useDropbox: () => {} }));

const reload = inertia.reload;

// The page's last resort when its reload did not come back: replace the document.
Object.defineProperty(window.location, "reload", {
  configurable: true,
  writable: true,
  value: inertia.locationReload,
});

const skeletonIsShowing = () => document.querySelector('[aria-busy="true"]') !== null;

const makePageProps = (id: string): Record<string, unknown> => ({
  dropbox_api_key: null,
  id,
  unique_permalink: `permalink-${id}`,
  thumbnail: null,
  refund_policies: [],
  currency_type: "usd",
  is_tiered_membership: false,
  can_close_membership_tiers: false,
  is_listed_on_discover: false,
  is_physical: false,
  profile_sections: [],
  taxonomies: [],
  taxonomy_attributes: [],
  earliest_membership_price_change_date: "2026-08-10T00:00:00.000Z",
  custom_domain_verification_status: null,
  sales_count_for_inventory: 0,
  successful_sales_count: 0,
  ratings: { count: 0, average: 0, percentages: [0, 0, 0, 0, 0] },
  seller: { id: "seller-id", name: "Seller", avatar_url: "", profile_url: "", is_verified: false },
  existing_files: [],
  current_seller_external_id: "seller-external-id",
  aws_key: "",
  s3_url: "",
  available_countries: [],
  google_client_id: "",
  seller_refund_policy_enabled: false,
  seller_refund_policy: { title: "", fine_print: null },
  cancellation_discounts_enabled: false,
  receipt_email_from: "seller@example.com",
  price_checker_enabled: false,
  custom_html_pages_enabled: false,
  auto_marketing_enabled: false,
  custom_html_store_hostnames: [],
  custom_html_global_nav_hosts: [],
  custom_html_global_nav_paths: [],
  ai_generated: false,
  product: {
    name: `Product ${id}`,
    description: "",
    custom_permalink: null,
    price_cents: 100,
    suggested_price_cents: null,
    customizable_price: false,
    eligible_for_installment_plans: false,
    allow_installment_plan: false,
    installment_plan: null,
    custom_button_text_option: null,
    custom_summary: null,
    custom_html: null,
    custom_view_content_button_text: null,
    custom_view_content_button_text_max_length: 20,
    custom_receipt_text: null,
    custom_receipt_text_max_length: 1_000,
    custom_failed_payment_text: null,
    custom_failed_payment_text_max_length: 500,
    custom_attributes: [],
    taxonomy_attribute_values: {},
    inferred_taxonomy_attribute_values: {},
    file_attributes: [],
    max_purchase_count: null,
    quantity_enabled: false,
    can_enable_quantity: true,
    should_show_sales_count: false,
    hide_sold_out_variants: false,
    is_epublication: false,
    product_refund_policy_enabled: false,
    refund_policy: {
      allowed_refund_periods_in_days: [],
      max_refund_period_in_days: 30,
      fine_print_enabled: false,
      fine_print: null,
      title: "",
    },
    is_published: false,
    free_trial_enabled: false,
    free_trial_duration_amount: null,
    free_trial_duration_unit: null,
    should_include_last_post: false,
    should_show_all_posts: false,
    block_access_after_membership_cancellation: false,
    duration_in_months: null,
    subscription_duration: null,
    integrations: { discord: null, circle: null, google_calendar: null },
    covers: [],
    availabilities: [],
    section_ids: [],
    taxonomy_id: null,
    tags: [],
    display_product_reviews: false,
    is_adult: false,
    discover_fee_per_thousand: 0,
    shipping_destinations: [],
    shipping_excluded_country_codes: [],
    custom_domain: "",
    collaborating_user: null,
    native_type: "digital",
    files: [],
    rich_content: [],
    variants: [],
    has_same_rich_content_for_all_variants: false,
    is_multiseat_license: false,
    call_limitation_info: null,
    require_shipping: false,
    cancellation_discount: null,
    default_offer_code: null,
    public_files: [],
    community_chat_enabled: false,
    confirmed_removed_variant_ids: [],
    confirmed_removed_rich_content_ids: [],
  },
});

installPopstateClaims();

beforeEach(() => {
  mounts.length = 0;
  reload.mockReset();
  inertia.on.mockClear();
  inertia.finishListeners.clear();
  inertia.locationReload.mockReset();
  markVisitStarted();
});

afterEach(cleanup);

it("remounts the editor when the Inertia visit switches products, and only then", async () => {
  pageProps.current = makePageProps("product-a");
  const { rerender } = render(<ProductEditInertiaPage />);
  await act(async () => {});
  expect(mounts).toEqual(["product-a"]);

  // Same product, refreshed props: the editor instance (and its state) stays.
  pageProps.current = makePageProps("product-a");
  rerender(<ProductEditInertiaPage />);
  await act(async () => {});
  expect(mounts).toEqual(["product-a"]);

  // Different product: the editor must remount so its state reseeds from the
  // new product's props.
  pageProps.current = makePageProps("product-b");
  rerender(<ProductEditInertiaPage />);
  await act(async () => {});
  expect(mounts).toEqual(["product-a", "product-b"]);
});

it("waits for current props before mounting the editor on a page restored from history", async () => {
  window.dispatchEvent(new PopStateEvent("popstate"));
  pageProps.current = makePageProps("product-a");
  const { rerender } = render(<ProductEditInertiaPage />);
  await act(async () => {});
  expect(mounts).toEqual([]);
  expect(reload).toHaveBeenCalledTimes(1);

  pageProps.current = makePageProps("product-a");
  act(() => {
    reload.mock.calls[0]?.[0].onSuccess();
  });
  rerender(<ProductEditInertiaPage />);
  await act(async () => {});
  expect(mounts).toEqual(["product-a"]);
  expect(reload).toHaveBeenCalledTimes(1);
});

it("mounts the editor straight away on a visit", async () => {
  window.dispatchEvent(new PopStateEvent("popstate"));
  markVisitStarted();
  pageProps.current = makePageProps("product-a");
  render(<ProductEditInertiaPage />);
  await act(async () => {});
  expect(mounts).toEqual(["product-a"]);
  expect(reload).not.toHaveBeenCalled();
});

it("reloads the document when a history restore's reload fails, instead of mounting the stale snapshot", async () => {
  window.dispatchEvent(new PopStateEvent("popstate"));
  pageProps.current = makePageProps("product-a");
  render(<ProductEditInertiaPage />);
  await act(async () => {});
  expect(reload).toHaveBeenCalledTimes(1);
  expect(skeletonIsShowing()).toBe(true);
  expect(inertia.locationReload).not.toHaveBeenCalled();

  // Not cancelled and not interrupted: the request simply failed, so nothing else is coming.
  act(() => {
    reload.mock.calls[0]?.[0].onFinish({ completed: false, cancelled: false, interrupted: false });
  });

  expect(inertia.locationReload).toHaveBeenCalledTimes(1);
  // The props from the history entry are never handed to the editor, and the page does not ask again.
  expect(mounts).toEqual([]);
  expect(skeletonIsShowing()).toBe(true);
  expect(reload).toHaveBeenCalledTimes(1);
});

it("waits out a cancelled reload, asks again once that visit finishes, then mounts from the fresh props", async () => {
  window.dispatchEvent(new PopStateEvent("popstate"));
  pageProps.current = makePageProps("product-a");
  const { rerender } = render(<ProductEditInertiaPage />);
  await act(async () => {});
  expect(reload).toHaveBeenCalledTimes(1);

  // A newer visit replaced the reload, so a full reload here would throw that visit away.
  act(() => {
    reload.mock.calls[0]?.[0].onFinish({ completed: false, cancelled: true, interrupted: false });
  });

  expect(inertia.locationReload).not.toHaveBeenCalled();
  expect(reload).toHaveBeenCalledTimes(1);
  expect(mounts).toEqual([]);
  expect(skeletonIsShowing()).toBe(true);
  expect(inertia.on).toHaveBeenCalledWith("finish", expect.any(Function));

  // That visit finishes: the page asks for its props again.
  act(() => {
    inertia.emitFinish();
  });
  await act(async () => {});
  expect(reload).toHaveBeenCalledTimes(2);
  expect(inertia.locationReload).not.toHaveBeenCalled();
  expect(mounts).toEqual([]);
  expect(skeletonIsShowing()).toBe(true);

  // The second reload answers with current props.
  pageProps.current = makePageProps("product-a");
  act(() => {
    reload.mock.calls[1]?.[0].onSuccess();
  });
  rerender(<ProductEditInertiaPage />);
  await act(async () => {});
  expect(mounts).toEqual(["product-a"]);
  expect(skeletonIsShowing()).toBe(false);
  expect(reload).toHaveBeenCalledTimes(2);
});

it("does not reload the destination when leaving the page cancels the reload", async () => {
  window.dispatchEvent(new PopStateEvent("popstate"));
  pageProps.current = makePageProps("product-a");
  const { unmount } = render(<ProductEditInertiaPage />);
  await act(async () => {});
  expect(reload).toHaveBeenCalledTimes(1);

  // Leaving the editor is what cancels the reload the page started.
  unmount();
  await act(async () => {});
  act(() => {
    reload.mock.calls[0]?.[0].onFinish({ completed: false, cancelled: true, interrupted: false });
  });

  expect(inertia.locationReload).not.toHaveBeenCalled();
  expect(inertia.on).not.toHaveBeenCalled();
  expect(reload).toHaveBeenCalledTimes(1);
});

it("does not reload the document after the seller has already left the page", async () => {
  window.dispatchEvent(new PopStateEvent("popstate"));
  pageProps.current = makePageProps("product-a");
  const { unmount } = render(<ProductEditInertiaPage />);
  await act(async () => {});
  expect(reload).toHaveBeenCalledTimes(1);

  unmount();
  await act(async () => {});
  act(() => {
    reload.mock.calls[0]?.[0].onFinish({ completed: false, cancelled: false, interrupted: false });
  });

  expect(inertia.locationReload).not.toHaveBeenCalled();
  expect(mounts).toEqual([]);
});
