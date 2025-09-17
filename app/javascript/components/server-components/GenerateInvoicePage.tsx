import cx from "classnames";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { sendInvoice } from "$app/data/invoice";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { showAlert } from "$app/components/server-components/Alert";

type FieldState = { value: string; error?: boolean };

const GenerateInvoicePage = ({
  form_info,
  supplier_info,
  seller_info,
  order_info,
  email,
  id,
  countries,
}: {
  form_info: {
    heading: string;
    display_vat_id: boolean;
    vat_id_label: string;
    data: {
      full_name: string | null;
      street_address: string | null;
      city: string | null;
      state: string | null;
      zip_code: string | null;
      country_iso2: string | null;
    };
  };
  supplier_info: {
    heading: string;
    attributes: { label: string | null; value: string }[];
  };
  seller_info: {
    heading: string;
    attributes: { label: string | null; value: string }[];
  };
  order_info: {
    heading: string;
    invoice_date_attribute: { label: string; value: string };
    form_attributes: { label: string | null; value: string | null }[];
  };
  email: string;
  id: string;
  countries: Record<string, string>;
}) => {
  const [isLoading, setIsLoading] = React.useState(false);

  const [fullName, setFullName] = React.useState<FieldState>({ value: form_info.data.full_name ?? "" });
  const [vatId, setVatId] = React.useState("");
  const [streetAddress, setStreetAddress] = React.useState<FieldState>({
    value: form_info.data.street_address ?? "",
  });
  const [city, setCity] = React.useState<FieldState>({ value: form_info.data.city ?? "" });
  const [state, setState] = React.useState<FieldState>({ value: form_info.data.state ?? "" });
  const [zipCode, setZipCode] = React.useState<FieldState>({ value: form_info.data.zip_code ?? "" });
  const [country, setCountry] = React.useState<FieldState>({ value: form_info.data.country_iso2 ?? "" });
  const [additionalNotes, setAdditionalNotes] = React.useState<FieldState>({ value: "" });

  const [downloadUrl, setDownloadUrl] = React.useState<string | null>(null);

  const handleDownload = async () => {
    setFullName((prev) => ({ ...prev, error: !prev.value.length }));
    setStreetAddress((prev) => ({ ...prev, error: !prev.value.length }));
    setCity((prev) => ({ ...prev, error: !prev.value.length }));
    setState((prev) => ({ ...prev, error: !prev.value.length }));
    setZipCode((prev) => ({ ...prev, error: !prev.value.length }));
    setCountry((prev) => ({ ...prev, error: !prev.value.length }));

    if ([fullName, streetAddress, city, state, zipCode, country].some((field) => !field.value.length)) return;

    setIsLoading(true);
    try {
      const result = await sendInvoice({
        id,
        email,
        full_name: fullName.value,
        vat_id: form_info.display_vat_id ? vatId : null,
        street_address: streetAddress.value,
        city: city.value,
        state: state.value,
        zip_code: zipCode.value,
        country_code: country.value,
        additional_notes: additionalNotes.value,
      });

      showAlert(result.message, result.success ? "success" : "error");

      if (result.success) {
        window.open(result.file_location, "_blank");
        setDownloadUrl(result.file_location);
      }
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <>
      <main className="stack">
        <header>
          <h4>{form_info.heading}</h4>
        </header>
        <div>
          <fieldset className={cx({ danger: fullName.error })}>
            <label htmlFor="full_name">Full name</label>
            <input
              id="full_name"
              placeholder="Full name"
              type="text"
              value={fullName.value}
              onChange={(e) => setFullName({ value: e.target.value })}
            />
          </fieldset>
          {form_info.display_vat_id ? (
            <fieldset>
              <legend>
                <label htmlFor="chargeable_vat_id">{form_info.vat_id_label}</label>
              </legend>
              <input id="chargeable_vat_id" type="text" value={vatId} onChange={(e) => setVatId(e.target.value)} />
            </fieldset>
          ) : null}
          <fieldset className={cx({ danger: streetAddress.error })}>
            <label htmlFor="street_address">Street address</label>
            <input
              id="street_address"
              type="text"
              placeholder="Street address"
              value={streetAddress.value}
              onChange={(e) => setStreetAddress({ value: e.target.value })}
            />
          </fieldset>
          <div style={{ display: "grid", gap: "var(--spacer-2)", gridTemplateColumns: "2fr 1fr 1fr" }}>
            <fieldset className={cx({ danger: city.error })}>
              <label htmlFor="city">City</label>
              <input
                id="city"
                type="text"
                placeholder="City"
                value={city.value}
                onChange={(e) => setCity({ value: e.target.value })}
              />
            </fieldset>
            <fieldset className={cx({ danger: state.error })}>
              <label htmlFor="state">State</label>
              <input
                id="state"
                type="text"
                placeholder="State"
                value={state.value}
                onChange={(e) => setState({ value: e.target.value })}
              />
            </fieldset>
            <fieldset className={cx({ danger: zipCode.error })}>
              <label htmlFor="zip_code">ZIP code</label>
              <input
                id="zip_code"
                type="text"
                placeholder="ZIP code"
                value={zipCode.value}
                onChange={(e) => setZipCode({ value: e.target.value })}
              />
            </fieldset>
          </div>
          <fieldset className={cx({ danger: country.error })}>
            <label htmlFor="country">Country</label>
            <select id="country" value={country.value} onChange={(e) => setCountry({ value: e.target.value })}>
              <option value="">Select country</option>
              {Object.entries(countries).map(([code, name]) => (
                <option key={code} value={code}>
                  {name}
                </option>
              ))}
            </select>
          </fieldset>
          <fieldset className={cx({ danger: additionalNotes.error })}>
            <legend>
              <label htmlFor="additional_notes">Additional notes</label>
            </legend>
            <textarea
              id="additional_notes"
              name="additional_notes"
              placeholder="Enter anything else you'd like to appear on your invoice (Optional)"
              value={additionalNotes.value}
              onChange={(e) => setAdditionalNotes({ value: e.target.value })}
            />
          </fieldset>
        </div>
        <div>
          <h5>{supplier_info.heading}</h5>
          {supplier_info.attributes.map((attribute, index) => (
            <div key={index}>
              {attribute.label ? <h6>{attribute.label}</h6> : null}
              <p className="whitespace-pre">{attribute.value}</p>
            </div>
          ))}
          <h5>{seller_info.heading}</h5>
          {seller_info.attributes.map((attribute, index) => (
            <div key={index}>
              {attribute.label ? <h6>{attribute.label}</h6> : null}
              {attribute.value}
            </div>
          ))}
        </div>
        <div>
          <h5>{order_info.heading}</h5>
          <div>
            <h6>{order_info.invoice_date_attribute.label}</h6>
            <span>{order_info.invoice_date_attribute.value}</span>
          </div>
          <div>
            <h6>To</h6>
            <div style={{ opacity: fullName.value.length ? undefined : "var(--disabled-opacity)" }}>
              {fullName.value || "Edgar Gumstein"}
            </div>
            <div style={{ opacity: streetAddress.value.length ? undefined : "var(--disabled-opacity)" }}>
              {streetAddress.value || "123 Gum Road"}
            </div>
            <div>
              <span style={{ opacity: city.value.length ? undefined : "var(--disabled-opacity)" }}>
                {`${city.value || "San Francisco"},`}
              </span>{" "}
              <span style={{ opacity: state.value.length ? undefined : "var(--disabled-opacity)" }}>
                {state.value || "CA"}
              </span>{" "}
              <span style={{ opacity: zipCode.value.length ? undefined : "var(--disabled-opacity)" }}>
                {zipCode.value || "94107"}
              </span>
            </div>
            <div style={{ opacity: country.value.length ? undefined : "var(--disabled-opacity)" }}>
              {countries[country.value] || "United States"}
            </div>
          </div>
          {additionalNotes.value.length ? (
            <div>
              <h6>Additional notes</h6>
              {additionalNotes.value}
            </div>
          ) : null}
          {order_info.form_attributes.map((attribute, index) => (
            <div key={index}>
              {attribute.label ? <h6>{attribute.label}</h6> : null}
              {attribute.value}
            </div>
          ))}
        </div>
        <footer>
          {downloadUrl ? (
            <span>
              Right-click{" "}
              <a href={downloadUrl} download>
                here
              </a>{" "}
              and "Save as..." if the PDF hasn't been automatically downloaded to your computer.
            </span>
          ) : (
            <span>This invoice will be downloaded as a PDF to your computer.</span>
          )}
          <Button color="accent" onClick={() => void handleDownload()} disabled={isLoading}>
            Download
          </Button>
        </footer>
      </main>
      <PoweredByFooter />
    </>
  );
};

export default register({
  component: GenerateInvoicePage,
  propParser: createCast(),
});
