import { useForm, usePage } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { classNames } from "$app/utils/classNames";

import { Button } from "$app/components/Button";
import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Card, CardContent } from "$app/components/ui/Card";

type PageProps = {
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
  file_location?: string | null;
};

export default function GenerateInvoicePage() {
  const props = cast<PageProps>(usePage().props);
  const [downloadUrl, setDownloadUrl] = React.useState<string | null>(props.file_location ?? null);

  const form = useForm({
    full_name: props.form_info.data.full_name ?? "",
    vat_id: "",
    street_address: props.form_info.data.street_address ?? "",
    city: props.form_info.data.city ?? "",
    state: props.form_info.data.state ?? "",
    zip_code: props.form_info.data.zip_code ?? "",
    country_code: props.form_info.data.country_iso2 ?? "",
    additional_notes: "",
  });

  React.useEffect(() => {
    if (props.file_location && !downloadUrl) {
      setDownloadUrl(props.file_location);
      window.open(props.file_location, "_blank");
    }
  }, [props.file_location, downloadUrl]);

  const handleDownload = () => {
    // Client-side validation
    const requiredFields: Array<keyof typeof form.data> = ["full_name", "street_address", "city", "state", "zip_code", "country_code"];
    const hasErrors = requiredFields.some((field) => !form.data[field]);

    if (hasErrors) {
      // Client-side validation - just prevent submission
      // Server will return validation errors if needed
      return;
    }

    form.post(Routes.send_invoice_purchase_path(props.id, { email: props.email }), {
      onSuccess: (page) => {
        const responseProps = cast<PageProps>(page.props);
        if (responseProps.file_location) {
          setDownloadUrl(responseProps.file_location);
          window.open(responseProps.file_location, "_blank");
        }
      },
    });
  };

  return (
    <>
      <div>
        <Card asChild>
          <main className="mx-auto my-4 h-min max-w-md [&>*]:flex-col [&>*]:items-stretch">
            <CardContent asChild>
              <header className="text-center">
                <h4 className="grow font-bold">{props.form_info.heading}</h4>
              </header>
            </CardContent>
            <CardContent>
              <fieldset className={classNames({ danger: form.errors.full_name }, "grow basis-0")}>
                <label htmlFor="full_name">Full name</label>
                <input
                  id="full_name"
                  placeholder="Full name"
                  type="text"
                  value={form.data.full_name}
                  onChange={(e) => form.setData("full_name", e.target.value)}
                  required
                />
              </fieldset>
              {props.form_info.display_vat_id ? (
                <fieldset className="flex-1">
                  <legend>
                    <label htmlFor="chargeable_vat_id">{props.form_info.vat_id_label}</label>
                  </legend>
                  <input
                    id="chargeable_vat_id"
                    type="text"
                    value={form.data.vat_id}
                    onChange={(e) => form.setData("vat_id", e.target.value)}
                  />
                </fieldset>
              ) : null}
              <fieldset className={classNames({ danger: form.errors.street_address }, "flex-1")}>
                <label htmlFor="street_address">Street address</label>
                <input
                  id="street_address"
                  type="text"
                  placeholder="Street address"
                  value={form.data.street_address}
                  onChange={(e) => form.setData("street_address", e.target.value)}
                  required
                />
              </fieldset>
              <div style={{ display: "grid", gap: "var(--spacer-2)", gridTemplateColumns: "2fr 1fr 1fr" }}>
                <fieldset className={cx({ danger: form.errors.city })}>
                  <label htmlFor="city">City</label>
                  <input
                    id="city"
                    type="text"
                    placeholder="City"
                    value={form.data.city}
                    onChange={(e) => form.setData("city", e.target.value)}
                    required
                  />
                </fieldset>
                <fieldset className={cx({ danger: form.errors.state })}>
                  <label htmlFor="state">State</label>
                  <input
                    id="state"
                    type="text"
                    placeholder="State"
                    value={form.data.state}
                    onChange={(e) => form.setData("state", e.target.value)}
                    required
                  />
                </fieldset>
                <fieldset className={cx({ danger: form.errors.zip_code })}>
                  <label htmlFor="zip_code">ZIP code</label>
                  <input
                    id="zip_code"
                    type="text"
                    placeholder="ZIP code"
                    value={form.data.zip_code}
                    onChange={(e) => form.setData("zip_code", e.target.value)}
                    required
                  />
                </fieldset>
              </div>
              <fieldset className={cx({ danger: form.errors.country_code })}>
                <label htmlFor="country">Country</label>
                <select
                  id="country"
                  value={form.data.country_code}
                  onChange={(e) => form.setData("country_code", e.target.value)}
                  required
                >
                  <option value="">Select country</option>
                  {Object.entries(props.countries).map(([code, name]) => (
                    <option key={code} value={code}>
                      {name}
                    </option>
                  ))}
                </select>
              </fieldset>
              <fieldset className={classNames({ danger: form.errors.additional_notes }, "flex-1")}>
                <legend>
                  <label htmlFor="additional_notes">Additional notes</label>
                </legend>
                <textarea
                  id="additional_notes"
                  name="additional_notes"
                  placeholder="Enter anything else you'd like to appear on your invoice (Optional)"
                  value={form.data.additional_notes}
                  onChange={(e) => form.setData("additional_notes", e.target.value)}
                />
              </fieldset>
            </CardContent>
            <CardContent>
              <h5 className="grow font-bold">{props.supplier_info.heading}</h5>
              {props.supplier_info.attributes.map((attribute, index) => (
                <div key={index}>
                  {attribute.label ? <h6 className="font-bold">{attribute.label}</h6> : null}
                  <p className="whitespace-pre">{attribute.value}</p>
                </div>
              ))}
              <h5 className="font-bold">{props.seller_info.heading}</h5>
              {props.seller_info.attributes.map((attribute, index) => (
                <div key={index}>
                  {attribute.label ? <h6 className="font-bold">{attribute.label}</h6> : null}
                  {attribute.value}
                </div>
              ))}
            </CardContent>
            <CardContent>
              <h5 className="grow font-bold">{props.order_info.heading}</h5>
              <div>
                <h6 className="font-bold">{props.order_info.invoice_date_attribute.label}</h6>
                <span>{props.order_info.invoice_date_attribute.value}</span>
              </div>
              <div>
                <h6 className="font-bold">To</h6>
                <div style={{ opacity: form.data.full_name.length ? undefined : "var(--disabled-opacity)" }}>
                  {form.data.full_name || "Edgar Gumstein"}
                </div>
                <div style={{ opacity: form.data.street_address.length ? undefined : "var(--disabled-opacity)" }}>
                  {form.data.street_address || "123 Gum Road"}
                </div>
                <div>
                  <span style={{ opacity: form.data.city.length ? undefined : "var(--disabled-opacity)" }}>
                    {`${form.data.city || "San Francisco"},`}
                  </span>{" "}
                  <span style={{ opacity: form.data.state.length ? undefined : "var(--disabled-opacity)" }}>
                    {form.data.state || "CA"}
                  </span>{" "}
                  <span style={{ opacity: form.data.zip_code.length ? undefined : "var(--disabled-opacity)" }}>
                    {form.data.zip_code || "94107"}
                  </span>
                </div>
                <div style={{ opacity: form.data.country_code.length ? undefined : "var(--disabled-opacity)" }}>
                  {props.countries[form.data.country_code] || "United States"}
                </div>
              </div>
              {form.data.additional_notes.length ? (
                <div>
                  <h6 className="font-bold">Additional notes</h6>
                  {form.data.additional_notes}
                </div>
              ) : null}
              {props.order_info.form_attributes.map((attribute, index) => (
                <div key={index}>
                  {attribute.label ? <h6 className="font-bold">{attribute.label}</h6> : null}
                  {attribute.value}
                </div>
              ))}
            </CardContent>
            <CardContent asChild>
              <footer className="text-center">
                {downloadUrl ? (
                  <span className="grow">
                    Right-click{" "}
                    <a href={downloadUrl} download>
                      here
                    </a>{" "}
                    and "Save as..." if the PDF hasn't been automatically downloaded to your computer.
                  </span>
                ) : (
                  <span className="grow">This invoice will be downloaded as a PDF to your computer.</span>
                )}
                <Button color="accent" onClick={handleDownload} disabled={form.processing}>
                  {form.processing ? "Processing..." : "Download"}
                </Button>
              </footer>
            </CardContent>
          </main>
        </Card>
      </div>
      <PoweredByFooter />
    </>
  );
}
