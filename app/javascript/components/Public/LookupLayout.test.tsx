// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react"
import * as React from "react"
import { afterEach, describe, expect, it, vi } from "vitest"

import { assertDefined } from "$app/utils/assert"

import LookupLayout from "$app/components/Public/LookupLayout"

vi.mock("$app/data/charge", () => ({
  lookupCharges: vi.fn(() => new Promise((resolve) => setTimeout(() => resolve({ success: true }), 20))),
  lookupLicenseKey: vi.fn(() => new Promise((resolve) => setTimeout(() => resolve({ success: true }), 20))),
  lookupPaypalCharges: vi.fn(() => new Promise((resolve) => setTimeout(() => resolve({ success: true }), 20))),
}))

afterEach(cleanup)

describe("LookupLayout", () => {
  // greptile-apps P1: submitting the card form and the PayPal form in the same batch, before
  // React commits the disabled-button render, must still send only one email — a ref-gated
  // in-flight check (not the disabled-state render) is what has to close the window.
  it("only dispatches one lookup when both forms are submitted in the same batch", async () => {
    const { lookupCharges, lookupPaypalCharges } = await import("$app/data/charge")

    render(<LookupLayout title="Look up your charge" type="charge" />)

    fireEvent.change(screen.getByLabelText(/what email address did you use/iu), { target: { value: "buyer@example.com" } })
    fireEvent.change(screen.getByLabelText(/last 4 digits/iu), { target: { value: "4242" } })
    fireEvent.change(screen.getByLabelText(/paypal invoice id/iu), { target: { value: "INV123" } })

    const [cardButton, paypalButton] = screen.getAllByRole("button", { name: /search/iu })

    // Both submits fire inside one act() batch so React hasn't committed the disabled-state
    // render before the second handler runs — the window the reported race depends on.
    await act(async () => {
      fireEvent.click(assertDefined(cardButton))
      fireEvent.click(assertDefined(paypalButton))
      await new Promise((resolve) => setTimeout(resolve, 30))
    })

    expect(lookupCharges).toHaveBeenCalledTimes(1)
    expect(lookupPaypalCharges).toHaveBeenCalledTimes(0)
  })
})
