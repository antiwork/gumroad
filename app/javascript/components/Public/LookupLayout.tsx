import cx from "classnames"
import React, { useEffect, useRef } from "react"

import { lookupCharges, lookupPaypalCharges } from "$app/data/charge"
import { assertResponseError } from "$app/utils/request"

import { showAlert } from "$app/components/server-components/Alert"

const LookupLayout = ({ children, title, type }: {
  children?: React.ReactNode
  title: string
  type: "charge" | "licenseKey"
}) => {
  const [email, setEmail] = React.useState<{ value: string; error?: boolean }>({ value: "" })
  const [last4, setLast4] = React.useState<{ value: string; error?: boolean }>({ value: "" })
  const [invoiceId, setInvoiceId] = React.useState<{ value: string; error?: boolean }>({ value: "" })
  const [isCardLoading, setIsCardLoading] = React.useState(false)
  const [isPaypalLoading, setIsPaypalLoading] = React.useState(false)
  const [success, setSuccess] = React.useState<boolean | null>(null)
  const messageRef = useRef<HTMLDivElement>(null)

  const handleCardLookup = async () => {
    let hasError = false;

    if (!email.value.length) {
      setEmail((prevEmail) => ({ ...prevEmail, error: true }))
      hasError = true;
    }

    if (type === "charge" && last4.value.length !== 4) {
      setLast4((prevLast4) => ({ ...prevLast4, error: true }))
      hasError = true;
    }

    if (hasError) {
      return;
    }

    setIsCardLoading(true)
    try {
      const result = await lookupCharges({
        email: email.value,
        last4: type === "charge" ? last4.value : null
      })
      setSuccess(result.success)
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error")
    } finally {
      setIsCardLoading(false)
    }
  }

  const handlePaypalLookup = async () => {
    if (!invoiceId.value.length) {
      setInvoiceId((prevInvoiceId) => ({ ...prevInvoiceId, error: true }))
      return
    }

    setIsPaypalLoading(true)
    try {
      const result = await lookupPaypalCharges({ invoiceId: invoiceId.value })
      setSuccess(result.success)
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error")
    } finally {
      setIsPaypalLoading(false)
    }
  }

  useEffect(() => {
    if (success !== null && messageRef.current) {
      messageRef.current.scrollIntoView({
        behavior: 'smooth',
        block: 'start'
      });
    }
  }, [success]);

  return (
    <div>
      <header>
        <h1>{title}</h1>
      </header>
      <div>
        {success !== null && (
          <div ref={messageRef} style={{ marginBottom: "var(--spacer-7)" }}>
            {success ? (
              <div className="success" role="status">
                We were able to find a match! It has been emailed to you. Sorry about the inconvenience.
              </div>
            ) : (
              <div className="warning" role="status">
                <div>
                  <p>We weren't able to find a match. Email <a href="mailto:support@gumroad.com">support@gumroad.com</a> with more information, and we'll respond promptly with any information we find about the {type}.</p>
                  {type === "charge" ? (
                  <ul>
                    <li>
                      <strong>charge date</strong> (the date that your statement says you were charged)
                    </li>
                    <li>
                      <strong>charge amount</strong> (the price you were charged)
                    </li>
                    <li>
                      <strong>card details (last 4 and expiry date)</strong> or <strong>PayPal invoice ID</strong>
                    </li>
                  </ul>) : null}
                </div>
              </div>
            )}
          </div>
        )}
        <form onSubmit={(evt) => {
          evt.preventDefault();
          void handleCardLookup();
        }}>
          <section>
            <header>
              <h2>{type === "charge" ? "What was I charged for?" : "Look up your license key"}</h2>
              {type === "charge" ? "Fill out this form and we'll send you a receipt for your charge." : "We'll send you a receipt including your license key."}
            </header>
            <fieldset className={cx({ danger: email.error })}>
              <label htmlFor="email">What email address did you use?</label>
              <input
                id="email"
                className="required"
                placeholder="Email address"
                type="text"
                value={email.value}
                onChange={(evt) => setEmail({ value: evt.target.value })}
              />
            </fieldset>
            {type === "charge" && (
              <fieldset className={cx({ danger: last4.error })}>
                <label htmlFor="cc_last_four">Last 4 digits of your card</label>
                <input
                  id="cc_last_four"
                  className="required"
                  maxLength={4}
                  placeholder="4242"
                  type="tel"
                  value={last4.value}
                  onChange={(evt) => setLast4({ value: evt.target.value })}
                />
              </fieldset>
            )}
            <button
              className="button primary"
              type="submit"
              disabled={isCardLoading}
            >
              {isCardLoading ? "Searching..." : "Search"}
            </button>
          </section>
        </form>
        <form onSubmit={(evt) => {
          evt.preventDefault();
          void handlePaypalLookup();
        }}>
          <section>
            <header>
              <h2>Did you pay with PayPal?</h2>
              Enter the invoice ID from PayPal's email receipt and we'll look it up.
            </header>
            <fieldset className={cx({ danger: invoiceId.error })}>
              <label htmlFor="invoice_id">PayPal Invoice ID</label>
              <input
                id="invoice_id"
                className="required"
                placeholder="XXXXXXXXXXXX"
                type="text"
                value={invoiceId.value}
                onChange={(evt) => setInvoiceId({ value: evt.target.value })}
              />
            </fieldset>
            <fieldset>
              <button
                className="button button-paypal"
                type="submit"
                disabled={isPaypalLoading}
              >
                {isPaypalLoading ? "Searching..." : "Search"}
              </button>
            </fieldset>
          </section>
        </form>
        {children}
      </div>
    </div>
  )
}

export default LookupLayout
