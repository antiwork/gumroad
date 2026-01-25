import cx from "classnames";
import * as React from "react";

import { classNames } from "$app/utils/classNames";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { showAlert } from "$app/components/server-components/Alert";
import { Card, CardContent } from "$app/components/ui/Card";

type Props = {
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
};

type FormData = {
  full_name: string;
  vat_id: string;
  street_address: string;
  city: string;
  state: string;
  zip_code: string;
  country: string;
  additional_notes: string;
};

type FormErrors = {
  [K in keyof FormData]?: boolean;
};

async function sendInvoice({
  id,
  email,
  full_name,
  vat_id,
  street_address,
  city,
  state,
  zip_code,
  country_code,
  additional_notes,
}: {
  id: string;
  email: string;
  full_name: string;
  vat_id: string | null;
  street_address: string;
  city: string;
  state: string;
  zip_code: string;
  country_code: string;
  additional_notes: string;
}) {
  const response = await request({
    method: "POST",
    url: Routes.send_invoice_path(id, { email }),
    accept: "json",
    data: {
      id,
      email,
      full_name,
      vat_id,
      street_address,
      city,
      state,
      zip_code,
      country_code,
      additional_notes,
    },
  });
  if (!response.ok) throw new ResponseError();
  return (await response.json()) as
    | { success: true; message: string; file_location: string }
    | { success: false; message: string };
}

export default function New({
  form_info,
  supplier_info,
  seller_info,
  order_info,
  email,
  id,
  countries,
}: Props) {
  const [isLoading, setIsLoading] = React.useState(false);
  const [downloadUrl, setDownloadUrl] = React.useState<string | null>(null);

  const [formData, setFormData] = React.useState<FormData>({
    full_name: form_info.data.full_name ?? "",
    vat_id: "",
    street_address: form_info.data.street_address ?? "",
    city: form_info.data.city ?? "",
    state: form_info.data.state ?? "",
    zip_code: form_info.data.zip_code ?? "",
    country: form_info.data.country_iso2 ?? "",
    additional_notes: "",
  });

  const [errors, setErrors] = React.useState<FormErrors>({});

  const setData = <K extends keyof FormData>(key: K, value: FormData[K]) => {
    setFormData((prev) => ({ ...prev, [key]: value }));
    setErrors((prev) => ({ ...prev, [key]: false }));
  };

  const handleDownload = async () => {
    const requiredFields: (keyof FormData)[] = ["full_name", "street_address", "city", "state", "zip_code", "country"];
    const newErrors: FormErrors = {};

    for (const field of requiredFields) {
      if (!formData[field].length) {
        newErrors[field] = true;
      }
    }

    setErrors(newErrors);

    if (Object.values(newErrors).some(Boolean)) return;

    setIsLoading(true);
    try {
      const result = await sendInvoice({
        id,
        email,
        full_name: formData.full_name,
        vat_id: form_info.display_vat_id ? formData.vat_id : null,
        street_address: formData.street_address,
        city: formData.city,
        state: formData.state,
        zip_code: formData.zip_code,
        country_code: formData.country,
        additional_notes: formData.additional_notes,
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
      <div>
        <Card asChild>
          <main className="mx-auto my-4 h-min max-w-md [&>*]:flex-col [&>*]:items-stretch">
            <CardContent asChild>
              <header className="text-center">
                <h4 className="grow font-bold">{form_info.heading}</h4>
              </header>
            </CardContent>
            <CardContent>
              <fieldset className={classNames({ danger: errors.full_name }, "grow basis-0")}>
                <label htmlFor="full_name">Full name</label>
                <input
                  id="full_name"
                  placeholder="Full name"
                  type="text"
                  value={formData.full_name}
                  onChange={(e) => setData("full_name", e.target.value)}
                />
              </fieldset>
              {form_info.display_vat_id ? (
                <fieldset className="flex-1">
                  <legend>
                    <label htmlFor="chargeable_vat_id">{form_info.vat_id_label}</label>
                  </legend>
                  <input
                    id="chargeable_vat_id"
                    type="text"
                    value={formData.vat_id}
                    onChange={(e) => setData("vat_id", e.target.value)}
                  />
                </fieldset>
              ) : null}
              <fieldset className={classNames({ danger: errors.street_address }, "flex-1")}>
                <label htmlFor="street_address">Street address</label>
                <input
                  id="street_address"
                  type="text"
                  placeholder="Street address"
                  value={formData.street_address}
                  onChange={(e) => setData("street_address", e.target.value)}
                />
              </fieldset>
              <div style={{ display: "grid", gap: "var(--spacer-2)", gridTemplateColumns: "2fr 1fr 1fr" }}>
                <fieldset className={cx({ danger: errors.city })}>
                  <label htmlFor="city">City</label>
                  <input
                    id="city"
                    type="text"
                    placeholder="City"
                    value={formData.city}
                    onChange={(e) => setData("city", e.target.value)}
                  />
                </fieldset>
                <fieldset className={cx({ danger: errors.state })}>
                  <label htmlFor="state">State</label>
                  <input
                    id="state"
                    type="text"
                    placeholder="State"
                    value={formData.state}
                    onChange={(e) => setData("state", e.target.value)}
                  />
                </fieldset>
                <fieldset className={cx({ danger: errors.zip_code })}>
                  <label htmlFor="zip_code">ZIP code</label>
                  <input
                    id="zip_code"
                    type="text"
                    placeholder="ZIP code"
                    value={formData.zip_code}
                    onChange={(e) => setData("zip_code", e.target.value)}
                  />
                </fieldset>
              </div>
              <fieldset className={cx({ danger: errors.country })}>
                <label htmlFor="country">Country</label>
                <select id="country" value={formData.country} onChange={(e) => setData("country", e.target.value)}>
                  <option value="">Select country</option>
                  {Object.entries(countries).map(([code, name]) => (
                    <option key={code} value={code}>
                      {name}
                    </option>
                  ))}
                </select>
              </fieldset>
              <fieldset className={classNames({ danger: errors.additional_notes }, "flex-1")}>
                <legend>
                  <label htmlFor="additional_notes">Additional notes</label>
                </legend>
                <textarea
                  id="additional_notes"
                  name="additional_notes"
                  placeholder="Enter anything else you'd like to appear on your invoice (Optional)"
                  value={formData.additional_notes}
                  onChange={(e) => setData("additional_notes", e.target.value)}
                />
              </fieldset>
            </CardContent>
            <CardContent>
              <h5 className="grow font-bold">{supplier_info.heading}</h5>
              {supplier_info.attributes.map((attribute, index) => (
                <div key={index}>
                  {attribute.label ? <h6 className="font-bold">{attribute.label}</h6> : null}
                  <p className="whitespace-pre">{attribute.value}</p>
                </div>
              ))}
              <h5 className="font-bold">{seller_info.heading}</h5>
              {seller_info.attributes.map((attribute, index) => (
                <div key={index}>
                  {attribute.label ? <h6 className="font-bold">{attribute.label}</h6> : null}
                  {attribute.value}
                </div>
              ))}
            </CardContent>
            <CardContent>
              <h5 className="grow font-bold">{order_info.heading}</h5>
              <div>
                <h6 className="font-bold">{order_info.invoice_date_attribute.label}</h6>
                <span>{order_info.invoice_date_attribute.value}</span>
              </div>
              <div>
                <h6 className="font-bold">To</h6>
                <div style={{ opacity: formData.full_name.length ? undefined : "var(--disabled-opacity)" }}>
                  {formData.full_name || "Edgar Gumstein"}
                </div>
                <div style={{ opacity: formData.street_address.length ? undefined : "var(--disabled-opacity)" }}>
                  {formData.street_address || "123 Gum Road"}
                </div>
                <div>
                  <span style={{ opacity: formData.city.length ? undefined : "var(--disabled-opacity)" }}>
                    {`${formData.city || "San Francisco"},`}
                  </span>{" "}
                  <span style={{ opacity: formData.state.length ? undefined : "var(--disabled-opacity)" }}>
                    {formData.state || "CA"}
                  </span>{" "}
                  <span style={{ opacity: formData.zip_code.length ? undefined : "var(--disabled-opacity)" }}>
                    {formData.zip_code || "94107"}
                  </span>
                </div>
                <div style={{ opacity: formData.country.length ? undefined : "var(--disabled-opacity)" }}>
                  {countries[formData.country] || "United States"}
                </div>
              </div>
              {formData.additional_notes.length ? (
                <div>
                  <h6 className="font-bold">Additional notes</h6>
                  {formData.additional_notes}
                </div>
              ) : null}
              {order_info.form_attributes.map((attribute, index) => (
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
                <Button color="accent" onClick={() => void handleDownload()} disabled={isLoading}>
                  Download
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

New.disableLayout = true;
