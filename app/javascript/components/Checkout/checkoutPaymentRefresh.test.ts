import { describe, expect, it, vi } from "vitest";

import {
  buildCartSaveRefreshCallbacks,
  type CartSaveCallbacks,
  CHECKOUT_PAYMENT_REFRESH_FAILED_MESSAGE,
  createLaneInvalidationSuppressor,
} from "$app/components/Checkout/checkoutPaymentRefresh";

const CONFIG = { type: "payment-element" };

// A save that never answers, for the cases where only "was a save re-issued?" matters.
const neverAnswers = (_callbacks: CartSaveCallbacks) => {};

describe("buildCartSaveRefreshCallbacks", () => {
  it("adopts the configuration and does nothing further when the save delivered one", () => {
    const save = vi.fn();
    const onDelivered = vi.fn();
    const onUnrecoverable = vi.fn();
    const callbacks = buildCartSaveRefreshCallbacks({ onDelivered, save, onUnrecoverable });

    callbacks.onSuccess({ props: { cart: {}, checkout_payment: CONFIG } });
    callbacks.onFinish({});

    expect(onDelivered).toHaveBeenCalledWith(CONFIG);
    expect(save).not.toHaveBeenCalled();
    expect(onUnrecoverable).not.toHaveBeenCalled();
  });

  it("does not adopt before the save finishes", () => {
    // Whether this save still speaks for the buyer's cart is only known at onFinish, which is where
    // Inertia reports displacement. Adopting in onSuccess would lift a hold the buyer's next edit
    // has already re-taken.
    const onDelivered = vi.fn();
    const callbacks = buildCartSaveRefreshCallbacks({ onDelivered, save: vi.fn(), onUnrecoverable: vi.fn() });

    callbacks.onSuccess({ props: { checkout_payment: CONFIG } });

    expect(onDelivered).not.toHaveBeenCalled();
  });

  it("does not adopt a configuration from a save a newer edit displaced", () => {
    // The response arrived, but the buyer edited the cart again while it was in flight, so this
    // configuration describes the cart from before that edit. Adopting it would clear the hold the
    // newer edit placed and re-enable Pay against an element mounted for the previous cart. The
    // newer save's own response is what lifts the hold.
    const onDelivered = vi.fn();
    const save = vi.fn();
    const onUnrecoverable = vi.fn();
    const callbacks = buildCartSaveRefreshCallbacks({ onDelivered, save, onUnrecoverable });

    callbacks.onSuccess({ props: { checkout_payment: CONFIG } });
    callbacks.onFinish({ interrupted: true });

    expect(onDelivered).not.toHaveBeenCalled();
    expect(save).not.toHaveBeenCalled();
    expect(onUnrecoverable).not.toHaveBeenCalled();
  });

  it("does not adopt a configuration from a cancelled save that had answered", () => {
    const onDelivered = vi.fn();
    const callbacks = buildCartSaveRefreshCallbacks({ onDelivered, save: vi.fn(), onUnrecoverable: vi.fn() });

    callbacks.onSuccess({ props: { checkout_payment: CONFIG } });
    callbacks.onFinish({ cancelled: true });

    expect(onDelivered).not.toHaveBeenCalled();
  });

  it("does not adopt the configuration the server sent back with a rejected edit", () => {
    // The rejected save's redirect re-renders the configuration from the cart the server kept, so
    // it describes the pre-edit cart while the buyer is still looking at the edited one.
    const onDelivered = vi.fn();
    const callbacks = buildCartSaveRefreshCallbacks({
      onDelivered,
      save: vi.fn(neverAnswers),
      onUnrecoverable: vi.fn(),
    });

    callbacks.onSuccess({
      props: { checkout_payment: CONFIG, flash: { message: "Sorry, something went wrong.", status: "danger" } },
    });
    callbacks.onFinish({});

    expect(onDelivered).not.toHaveBeenCalled();
  });

  it("re-issues the save when the response is lost entirely", () => {
    // A dropped connection, a timeout, or a 500 rendering an HTML error page: onSuccess never runs,
    // so nothing told us what the server now holds. The hold on Pay stays and we save again, which
    // re-sends the cart the client holds so the answer describes that same cart.
    const save = vi.fn(neverAnswers);
    const onUnrecoverable = vi.fn();
    const callbacks = buildCartSaveRefreshCallbacks({ onDelivered: vi.fn(), save, onUnrecoverable });

    callbacks.onFinish({});

    expect(save).toHaveBeenCalledTimes(1);
    // Nothing is reported yet — the recovery save is still the buyer's way out.
    expect(onUnrecoverable).not.toHaveBeenCalled();
  });

  it("re-issues the save when the response came back without a configuration", () => {
    // A transport-level truncation or a response that simply omitted the prop leaves the same
    // question open: which cart does the server hold now?
    const save = vi.fn(neverAnswers);
    const callbacks = buildCartSaveRefreshCallbacks({ onDelivered: vi.fn(), save, onUnrecoverable: vi.fn() });

    callbacks.onSuccess({ props: {} });
    callbacks.onFinish({});

    expect(save).toHaveBeenCalledTimes(1);
  });

  it("re-issues the save when the server reported the edit failed, even though a configuration came back", () => {
    // The shape CheckoutController#update actually produces on a handled failure. Every one of its
    // outcomes is a redirect to checkout_path, so the reloaded page always carries a well-formed
    // checkout_payment — but on a failure the edit did not persist, so that configuration
    // describes the PRE-edit cart while the buyer is still looking at the edited one. Adopting it
    // would clear the hold and re-enable Pay against an element mounted for a different cart.
    const save = vi.fn(neverAnswers);
    const callbacks = buildCartSaveRefreshCallbacks({ onDelivered: vi.fn(), save, onUnrecoverable: vi.fn() });

    callbacks.onSuccess({
      props: {
        checkout_payment: { integration: "payment_element" },
        flash: { message: "Sorry, something went wrong. Please try again.", status: "danger" },
      },
    });
    callbacks.onFinish({});

    expect(save).toHaveBeenCalledTimes(1);
  });

  it("accepts a configuration delivered alongside a non-error flash", () => {
    // Only an error flash means the edit was rejected. A notice or warning riding along with a
    // successful save must not send the hold into a pointless recovery round trip.
    const save = vi.fn(neverAnswers);
    const onDelivered = vi.fn();
    const onUnrecoverable = vi.fn();
    const callbacks = buildCartSaveRefreshCallbacks({ onDelivered, save, onUnrecoverable });

    callbacks.onSuccess({
      props: {
        checkout_payment: { integration: "payment_element" },
        flash: { message: "Discount applied.", status: "success" },
      },
    });
    callbacks.onFinish({});

    expect(onDelivered).toHaveBeenCalledWith({ integration: "payment_element" });
    expect(save).not.toHaveBeenCalled();
    expect(onUnrecoverable).not.toHaveBeenCalled();
  });

  it("does not recover when a newer save interrupted this one", () => {
    // The buyer edited the cart again while the save was in flight. Inertia's synchronous request
    // stream has one interruptible slot, so the newer save took this one's place and reports
    // `interrupted` here. That newer save carries the buyer's latest cart and its response is what
    // lifts the hold; recovering on its behalf would race two saves and risk adopting this older
    // one's answer for a cart the buyer no longer has.
    const save = vi.fn(neverAnswers);
    const onUnrecoverable = vi.fn();
    const callbacks = buildCartSaveRefreshCallbacks({ onDelivered: vi.fn(), save, onUnrecoverable });

    callbacks.onFinish({ interrupted: true });

    expect(save).not.toHaveBeenCalled();
    expect(onUnrecoverable).not.toHaveBeenCalled();
  });

  it("does not recover when the save was cancelled", () => {
    const save = vi.fn(neverAnswers);
    const onUnrecoverable = vi.fn();
    const callbacks = buildCartSaveRefreshCallbacks({ onDelivered: vi.fn(), save, onUnrecoverable });

    callbacks.onFinish({ cancelled: true });

    expect(save).not.toHaveBeenCalled();
    expect(onUnrecoverable).not.toHaveBeenCalled();
  });

  it("leaves the hold on and tells the buyer to reload when the recovery save also fails", () => {
    const onUnrecoverable = vi.fn();
    // Every save is lost, so the chain runs out of recoveries.
    const save = vi.fn((callbacks: CartSaveCallbacks) => callbacks.onFinish({}));
    const callbacks = buildCartSaveRefreshCallbacks({ onDelivered: vi.fn(), save, onUnrecoverable });

    callbacks.onFinish({});

    expect(save).toHaveBeenCalledTimes(1);
    expect(onUnrecoverable).toHaveBeenCalledWith(CHECKOUT_PAYMENT_REFRESH_FAILED_MESSAGE);
  });

  it("stays quiet and adopts when the recovery save delivers the configuration", () => {
    const onDelivered = vi.fn();
    const onUnrecoverable = vi.fn();
    const save = vi.fn((callbacks: CartSaveCallbacks) => {
      callbacks.onSuccess({ props: { checkout_payment: CONFIG } });
      callbacks.onFinish({});
    });
    const callbacks = buildCartSaveRefreshCallbacks({ onDelivered, save, onUnrecoverable });

    callbacks.onFinish({});

    expect(onDelivered).toHaveBeenCalledWith(CONFIG);
    expect(onUnrecoverable).not.toHaveBeenCalled();
  });

  it("does not recover forever while the server keeps failing", () => {
    // Bounded so an outage cannot turn one edit into an unbounded chain of saves.
    const save = vi.fn((callbacks: CartSaveCallbacks) => callbacks.onFinish({}));
    const callbacks = buildCartSaveRefreshCallbacks({ onDelivered: vi.fn(), save, onUnrecoverable: vi.fn() });

    callbacks.onFinish({});

    expect(save).toHaveBeenCalledTimes(1);
  });

  it("does not recover when a recovery save is itself interrupted by a newer edit", () => {
    const onUnrecoverable = vi.fn();
    const save = vi.fn((callbacks: CartSaveCallbacks) => callbacks.onFinish({ interrupted: true }));
    const callbacks = buildCartSaveRefreshCallbacks({ onDelivered: vi.fn(), save, onUnrecoverable });

    callbacks.onFinish({});

    expect(save).toHaveBeenCalledTimes(1);
    // The newer edit owns the hold now, so no alert and no further save.
    expect(onUnrecoverable).not.toHaveBeenCalled();
  });

  it("does not recover after a save that did deliver, even if a later save is lost", () => {
    // Each save builds its own callbacks, so one save's outcome can never be read as another's.
    const save = vi.fn(neverAnswers);
    const delivered = buildCartSaveRefreshCallbacks({ onDelivered: vi.fn(), save, onUnrecoverable: vi.fn() });
    delivered.onSuccess({ props: { checkout_payment: CONFIG } });
    delivered.onFinish({});
    expect(save).not.toHaveBeenCalled();

    const lost = buildCartSaveRefreshCallbacks({ onDelivered: vi.fn(), save, onUnrecoverable: vi.fn() });
    lost.onFinish({});

    expect(save).toHaveBeenCalledTimes(1);
  });
});

describe("createLaneInvalidationSuppressor", () => {
  // The keys are opaque strings to this module; these stand in for two carts whose payment lanes
  // differ, e.g. the same item at quantity 1 and quantity 2 (quantity moves the cart total, which
  // is what puts Klarna in or out of the served payment_method_types).
  const ACCEPTED = "seller1|prod|opt|1|500";
  const DETOUR = "seller1|prod|opt|2|1000";

  it("suppresses the claimed key once", () => {
    const { claim, shouldSuppressLaneInvalidation } = createLaneInvalidationSuppressor();

    claim(ACCEPTED);

    expect(shouldSuppressLaneInvalidation(ACCEPTED)).toBe(true);
  });

  it("stops suppressing the claimed key after the echo it was claimed for", () => {
    // The bug this pins: while the claim persisted, returning the cart to the accepted key skipped
    // the invalidation for the rest of the session, so no hold was placed on Pay even though the
    // configuration on screen had been computed for the cart the buyer detoured through.
    const { claim, shouldSuppressLaneInvalidation } = createLaneInvalidationSuppressor();

    claim(ACCEPTED);
    expect(shouldSuppressLaneInvalidation(ACCEPTED)).toBe(true);

    // The buyer edits away from the accepted cart, then back to exactly it.
    expect(shouldSuppressLaneInvalidation(DETOUR)).toBe(false);
    expect(shouldSuppressLaneInvalidation(ACCEPTED)).toBe(false);
  });

  it("does not suppress a key that was never claimed", () => {
    const { claim, shouldSuppressLaneInvalidation } = createLaneInvalidationSuppressor();

    claim(ACCEPTED);

    expect(shouldSuppressLaneInvalidation(DETOUR)).toBe(false);
    // A miss must not consume the claim, or the echo it was made for goes unsuppressed and the
    // accepted offer's resume is dropped.
    expect(shouldSuppressLaneInvalidation(ACCEPTED)).toBe(true);
  });

  it("suppresses nothing before anything is claimed", () => {
    const { shouldSuppressLaneInvalidation } = createLaneInvalidationSuppressor();

    expect(shouldSuppressLaneInvalidation(ACCEPTED)).toBe(false);
  });

  it("replaces an unconsumed claim rather than queueing it", () => {
    // Two offers accepted in a row: only the newest cart's echo is still pending, and the older
    // claim must not survive to exempt that cart later.
    const { claim, shouldSuppressLaneInvalidation } = createLaneInvalidationSuppressor();

    claim(ACCEPTED);
    claim(DETOUR);

    expect(shouldSuppressLaneInvalidation(DETOUR)).toBe(true);
    expect(shouldSuppressLaneInvalidation(ACCEPTED)).toBe(false);
  });
});
