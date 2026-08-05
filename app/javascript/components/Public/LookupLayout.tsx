import { Paypal } from "@boxicons/react"
import React, { useEffect, useRef } from "react"

import { lookupCharges, lookupLicenseKey, lookupPaypalCharges } from "$app/data/charge"
import { assertResponseError } from "$app/utils/request"

import { Button } from "$app/components/Button"
import { showAlert } from "$app/components/server-components/Alert"
import { Alert } from "$app/components/ui/Alert"
import { Fieldset } from "$app/components/ui/Fieldset"
import { FormSection } from "$app/components/ui/FormSection"
import { Input } from "$app/components/ui/Input"
import { Label } from "$app/components/ui/Label"
import { PageHeader } from "$app/components/ui/PageHeader"
import { Select } from "$app/components/ui/Select"

// Gumroad's founding year — the earliest a purchase could exist.
const EARLIEST_PURCHASE_YEAR = 2011
const currentYear = new Date().getFullYear()
const YEARS = Array.from({ length: currentYear - EARLIEST_PURCHASE_YEAR + 1 }, (_, i) => currentYear - i)
const MONTHS = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
]

const LookupLayout = ({ children, title, type }: {
  children?: React.ReactNode
  title: string
  type: "charge" | "licenseKey"
}) => {
  const [email, setEmail] = React.useState<{ value: string; error?: boolean }>({ value: "" })
  const [last4, setLast4] = React.useState<{ value: string; error?: boolean }>({ value: "" })
  const [productQuery, setProductQuery] = React.useState("")
  const [year, setYear] = React.useState("")
  const [month, setMonth] = React.useState("")
  const [invoiceId, setInvoiceId] = React.useState<{ value: string; error?: boolean }>({ value: "" })
  const [isCardLoading, setIsCardLoading] = React.useState(false)
  const [isPaypalLoading, setIsPaypalLoading] = React.useState(false)
  const [success, setSuccess] = React.useState<boolean | null>(null)
  const messageRef = useRef<HTMLDivElement>(null)

  // Only one of the two lookup forms can be in flight — every successful lookup sends a
  // real email, so a double submission means a double send.
  const isAnyLookupLoading = isCardLoading || isPaypalLoading

  const handleYearChange = (evt: React.ChangeEvent<HTMLSelectElement>) => {
    setYear(evt.target.value)
    setMonth("")
  }

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
      const result =
        type === "licenseKey"
          ? await lookupLicenseKey({
              email: email.value,
              productQuery: productQuery.trim() || null,
              year: year || null,
              month: year && month ? month : null,
            })
          : await lookupCharges({
              email: email.value,
              last4: last4.value,
              year: year || null,
              month: year && month ? month : null,
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
            {type === "licenseKey" && (
              <Fieldset>
                <Label htmlFor="product_query">Which product? (optional, name/permalink/URL)</Label>
                <Input
                  id="product_query"
                  type="text"
                  placeholder="Product name, permalink, or URL"
                  value={productQuery}
                  onChange={(evt) => setProductQuery(evt.target.value)}
                />
              </Fieldset>
            )}
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
            <Fieldset>
              <Label htmlFor="year">When did you make the purchase? (optional)</Label>
              <Select id="year" value={year} onChange={handleYearChange}>
                <option value="">Any year</option>
                {YEARS.map((y) => (
                  <option key={y} value={y}>
                    {y}
                  </option>
                ))}
              </Select>
            </Fieldset>
            <Fieldset>
              <Label htmlFor="month">Month (optional)</Label>
              <Select id="month" value={month} disabled={!year} onChange={(evt) => setMonth(evt.target.value)}>
                <option value="">Any month</option>
                {MONTHS.map((name, i) => (
                  <option key={name} value={i + 1}>
                    {name}
                  </option>
                ))}
              </Select>
            </Fieldset>
            <Button color="primary" type="submit" disabled={isAnyLookupLoading}>
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
                disabled={isAnyLookupLoading}
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
