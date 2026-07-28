import { describe, expect, it, vi } from "vitest";

import {
  buildCartSaveRefreshCallbacks,
  type CartSaveCallbacks,
  CHECKOUT_PAYMENT_REFRESH_FAILED_MESSAGE,
} from "$app/components/Checkout/checkoutPaymentRefresh";

const CONFIG = { type: "payment-element" };

// A save that never answers, for the cases where only "was a save re-issued?" matters.
const neverAnswers = (_callbacks: CartSaveCallbacks) => {};

describe("buildCartSaveRefreshCallbacks", () => {
  it("does nothing further when the save delivered a configuration", () => {
    const save = vi.fn();
    const onUnrecoverable = vi.fn();
    const callbacks = buildCartSaveRefreshCallbacks({ save, onUnrecoverable });

    callbacks.onSuccess({ props: { cart: {}, checkout_payment: CONFIG } });
    callbacks.onFinish({});

    expect(save).not.toHaveBeenCalled();
    expect(onUnrecoverable).not.toHaveBeenCalled();
  });

  it("re-issues the save when the response is lost entirely", () => {
    // A dropped connection, a timeout, or a 500 rendering an HTML error page: onSuccess never runs,
    // so nothing told us what the server now holds. The hold on Pay stays and we save again, which
    // re-sends the cart the client holds so the answer describes that same cart.
    const save = vi.fn(neverAnswers);
    const onUnrecoverable = vi.fn();
    const callbacks = buildCartSaveRefreshCallbacks({ save, onUnrecoverable });

    callbacks.onFinish({});

    expect(save).toHaveBeenCalledTimes(1);
    // Nothing is reported yet — the recovery save is still the buyer's way out.
    expect(onUnrecoverable).not.toHaveBeenCalled();
  });

  it("re-issues the save when the response came back without a configuration", () => {
    // A validation error is a valid Inertia response, but it carries no recomputed configuration,
    // which leaves the same question open: which cart does the server hold now?
    const save = vi.fn(neverAnswers);
    const callbacks = buildCartSaveRefreshCallbacks({ save, onUnrecoverable: vi.fn() });

    callbacks.onSuccess({ props: { errors: { cart: "is invalid" } } });
    callbacks.onFinish({});

    expect(save).toHaveBeenCalledTimes(1);
  });

  it("does not recover when a newer save interrupted this one", () => {
    // The buyer edited the cart again while the save was in flight. Inertia's synchronous request
    // stream has one interruptible slot, so the newer save took this one's place and reports
    // `interrupted` here. That newer save carries the buyer's latest cart and its response is what
    // lifts the hold; recovering on its behalf would race two saves and risk adopting this older
    // one's answer for a cart the buyer no longer has.
    const save = vi.fn(neverAnswers);
    const onUnrecoverable = vi.fn();
    const callbacks = buildCartSaveRefreshCallbacks({ save, onUnrecoverable });

    callbacks.onFinish({ interrupted: true });

    expect(save).not.toHaveBeenCalled();
    expect(onUnrecoverable).not.toHaveBeenCalled();
  });

  it("does not recover when the save was cancelled", () => {
    const save = vi.fn(neverAnswers);
    const onUnrecoverable = vi.fn();
    const callbacks = buildCartSaveRefreshCallbacks({ save, onUnrecoverable });

    callbacks.onFinish({ cancelled: true });

    expect(save).not.toHaveBeenCalled();
    expect(onUnrecoverable).not.toHaveBeenCalled();
  });

  it("leaves the hold on and tells the buyer to reload when the recovery save also fails", () => {
    const onUnrecoverable = vi.fn();
    // Every save is lost, so the chain runs out of recoveries.
    const save = vi.fn((callbacks: CartSaveCallbacks) => callbacks.onFinish({}));
    const callbacks = buildCartSaveRefreshCallbacks({ save, onUnrecoverable });

    callbacks.onFinish({});

    expect(save).toHaveBeenCalledTimes(1);
    expect(onUnrecoverable).toHaveBeenCalledWith(CHECKOUT_PAYMENT_REFRESH_FAILED_MESSAGE);
  });

  it("stays quiet when the recovery save delivers the configuration", () => {
    // The reducer adopts it through the page's props and the hold lifts on its own, so there is
    // nothing to tell the buyer.
    const onUnrecoverable = vi.fn();
    const save = vi.fn((callbacks: CartSaveCallbacks) => {
      callbacks.onSuccess({ props: { checkout_payment: CONFIG } });
      callbacks.onFinish({});
    });
    const callbacks = buildCartSaveRefreshCallbacks({ save, onUnrecoverable });

    callbacks.onFinish({});

    expect(onUnrecoverable).not.toHaveBeenCalled();
  });

  it("does not recover forever while the server keeps failing", () => {
    // Bounded so an outage cannot turn one edit into an unbounded chain of saves.
    const save = vi.fn((callbacks: CartSaveCallbacks) => callbacks.onFinish({}));
    const callbacks = buildCartSaveRefreshCallbacks({ save, onUnrecoverable: vi.fn() });

    callbacks.onFinish({});

    expect(save).toHaveBeenCalledTimes(1);
  });

  it("does not recover when a recovery save is itself interrupted by a newer edit", () => {
    const onUnrecoverable = vi.fn();
    const save = vi.fn((callbacks: CartSaveCallbacks) => callbacks.onFinish({ interrupted: true }));
    const callbacks = buildCartSaveRefreshCallbacks({ save, onUnrecoverable });

    callbacks.onFinish({});

    expect(save).toHaveBeenCalledTimes(1);
    // The newer edit owns the hold now, so no alert and no further save.
    expect(onUnrecoverable).not.toHaveBeenCalled();
  });

  it("does not recover after a save that did deliver, even if a later save is lost", () => {
    // Each save builds its own callbacks, so one save's outcome can never be read as another's.
    const save = vi.fn(neverAnswers);
    const delivered = buildCartSaveRefreshCallbacks({ save, onUnrecoverable: vi.fn() });
    delivered.onSuccess({ props: { checkout_payment: CONFIG } });
    delivered.onFinish({});
    expect(save).not.toHaveBeenCalled();

    const lost = buildCartSaveRefreshCallbacks({ save, onUnrecoverable: vi.fn() });
    lost.onFinish({});

    expect(save).toHaveBeenCalledTimes(1);
  });
});
