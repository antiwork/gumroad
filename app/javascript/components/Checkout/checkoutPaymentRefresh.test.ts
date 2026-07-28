import { describe, expect, it, vi } from "vitest";

import {
  buildCartSaveRefreshCallbacks,
  CHECKOUT_PAYMENT_REFRESH_FAILED_MESSAGE,
} from "$app/components/Checkout/checkoutPaymentRefresh";

// A reload that never answers, for the cases where only "was a reload started?" matters.
type ReloadOptions = {
  only: string[];
  onSuccess: (page: { props: Record<string, unknown> }) => void;
  onFinish: () => void;
};
const neverAnswers = (_options: ReloadOptions) => {};

describe("buildCartSaveRefreshCallbacks", () => {
  it("does nothing further when the save delivered a configuration", () => {
    const reload = vi.fn();
    const onUnrecoverable = vi.fn();
    const callbacks = buildCartSaveRefreshCallbacks({ reload, onUnrecoverable });

    callbacks.onSuccess({ props: { cart: {}, checkout_payment: { type: "payment-element" } } });
    callbacks.onFinish();

    expect(reload).not.toHaveBeenCalled();
    expect(onUnrecoverable).not.toHaveBeenCalled();
  });

  it("re-requests the configuration when the response is lost entirely", () => {
    // A dropped connection, a timeout, or a 500 rendering an HTML error page: onSuccess never runs,
    // so nothing told us what the server now holds. The hold on Pay stays and we ask again.
    const reload = vi.fn(neverAnswers);
    const onUnrecoverable = vi.fn();
    const callbacks = buildCartSaveRefreshCallbacks({ reload, onUnrecoverable });

    callbacks.onFinish();

    expect(reload).toHaveBeenCalledTimes(1);
    expect(reload.mock.calls[0]?.[0]).toMatchObject({ only: ["checkout_payment"] });
    // Nothing is reported yet — the retry is still the buyer's way out.
    expect(onUnrecoverable).not.toHaveBeenCalled();
  });

  it("re-requests the configuration when the response came back without one", () => {
    // A validation error is a valid Inertia response, but it carries no recomputed configuration,
    // which leaves the same question open: which cart does the server hold now?
    const reload = vi.fn(neverAnswers);
    const callbacks = buildCartSaveRefreshCallbacks({ reload, onUnrecoverable: vi.fn() });

    callbacks.onSuccess({ props: { errors: { cart: "is invalid" } } });
    callbacks.onFinish();

    expect(reload).toHaveBeenCalledTimes(1);
  });

  it("lifts nothing and tells the buyer to reload when the retry also fails", () => {
    const onUnrecoverable = vi.fn();
    const reload = vi.fn(
      (options: { onSuccess: (page: { props: Record<string, unknown> }) => void; onFinish: () => void }) => {
        // Retry lost too.
        options.onFinish();
      },
    );
    const callbacks = buildCartSaveRefreshCallbacks({ reload, onUnrecoverable });

    callbacks.onFinish();

    expect(onUnrecoverable).toHaveBeenCalledWith(CHECKOUT_PAYMENT_REFRESH_FAILED_MESSAGE);
  });

  it("stays quiet when the retry delivers the configuration", () => {
    // The reducer adopts it through the page's props and the hold lifts on its own, so there is
    // nothing to tell the buyer.
    const onUnrecoverable = vi.fn();
    const reload = vi.fn(
      (options: { onSuccess: (page: { props: Record<string, unknown> }) => void; onFinish: () => void }) => {
        options.onSuccess({ props: { checkout_payment: { type: "payment-element" } } });
        options.onFinish();
      },
    );
    const callbacks = buildCartSaveRefreshCallbacks({ reload, onUnrecoverable });

    callbacks.onFinish();

    expect(onUnrecoverable).not.toHaveBeenCalled();
  });

  it("does not re-request after a save that did deliver, even if a later save is lost", () => {
    // Each save builds its own callbacks, so one save's outcome can never be read as another's.
    const reload = vi.fn(neverAnswers);
    const delivered = buildCartSaveRefreshCallbacks({ reload, onUnrecoverable: vi.fn() });
    delivered.onSuccess({ props: { checkout_payment: { type: "payment-element" } } });
    delivered.onFinish();
    expect(reload).not.toHaveBeenCalled();

    const lost = buildCartSaveRefreshCallbacks({ reload, onUnrecoverable: vi.fn() });
    lost.onFinish();

    expect(reload).toHaveBeenCalledTimes(1);
  });
});
