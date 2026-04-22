import { Paypal } from "@boxicons/react";
import React, { useEffect, useRef } from "react"

import { lookupCharges, lookupPaypalCharges } from "$app/data/charge"
import { assertResponseError } from "$app/utils/request"

import { Button } from "$app/components/Button"
import { showAlert } from "$app/components/server-components/Alert"
import { Alert } from "$app/components/ui/Alert"
import { Fieldset } from "$app/components/ui/Fieldset"
import { FormSection } from "$app/components/ui/FormSection"
import { Input } from "$app/components/ui/Input"
import { Label } from "$app/components/ui/Label"
import { PageHeader } from "$app/components/ui/PageHeader"

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
      <PageHeader title={title} className="border-b-0 sm:border-b" />
      <div>
        {success !== null && (
          <div ref={messageRef} className="p-4! md:p-8!">
            {success ? (
              <Alert role="status" variant="success">
                We were able to find a match! It has been emailed to you. Sorry about the inconvenience.
              </Alert>
            ) : (
              <Alert role="status" variant="warning">
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
              </Alert>
            )}
          </div>
        )}
        <form onSubmit={(evt) => {
          evt.preventDefault();
          void handleCardLookup();
        }}>
          <FormSection
            header={
              <>
                <h2>{type === "charge" ? "What was I charged for?" : "Look up your license key"}</h2>
                {type === "charge" ? "Fill out this form and we'll send you a receipt for your charge." : "We'll send you a receipt including your license key."}
              </>
            }
          >
            <Fieldset state={email.error ? "danger" : undefined}>
              <Label htmlFor="email">What email address did you use?</Label>
              <Input
                id="email"
                type="text"
                value={email.value}
                onChange={(evt) => setEmail({ value: evt.target.value })}
              />
            </Fieldset>
            {type === "charge" && (
              <Fieldset state={last4.error ? "danger" : undefined}>
                <Label htmlFor="cc_last_four">Last 4 digits of your card</Label>
                <Input
                  id="cc_last_four"
                  maxLength={4}
                  placeholder="4242"
                  type="tel"
                  value={last4.value}
                  onChange={(evt) => setLast4({ value: evt.target.value })}
                />
              </Fieldset>
            )}
            <Button color="primary" type="submit" disabled={isCardLoading}>
              {isCardLoading ? "Searching..." : "Search"}
            </Button>
          </FormSection>
        </form>
        <form onSubmit={(evt) => {
          evt.preventDefault();
          void handlePaypalLookup();
        }}>
          <FormSection
            className="border-t!"
            header={
              <>
                <h2>Did you pay with PayPal?</h2>
                Enter the invoice ID from PayPal's email receipt and we'll look it up.
              </>
            }
          >
            <Fieldset state={invoiceId.error ? "danger" : undefined}>
              <Label htmlFor="invoice_id">PayPal Invoice ID</Label>
              <Input
                id="invoice_id"
                className="required"
                placeholder="XXXXXXXXXXXX"
                type="text"
                value={invoiceId.value}
                onChange={(evt) => setInvoiceId({ value: evt.target.value })}
              />
            </Fieldset>
            <Fieldset>
              <Button
                color="paypal"
                type="submit"
                disabled={isPaypalLoading}
              >
                <Paypal pack="brands" className="size-5" />
                {isPaypalLoading ? "Searching..." : "Search"}
              </Button>
            </Fieldset>
          </FormSection>
        </form>
        {children}
      </div>
    </div>
  )
}

export default LookupLayout
