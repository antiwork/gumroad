import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Button } from "$app/components/Button";
import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Card, CardContent } from "$app/components/ui/Card";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Select } from "$app/components/ui/Select";
import { Textarea } from "$app/components/ui/Textarea";

type NewInvoicePageProps = {
  form_data: {
    purchase_id: string;
    address_fields: {
      full_name: string;
      street_address: string;
      city: string;
      state: string;
      zip_code: string;
      country_code: string;
    };
    email: string;
    vat_id: string;
    additional_notes: string;
  };
  form_metadata: {
    heading: string;
    display_vat_id: boolean;
    vat_id_label: string;
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
    countries: Record<string, string>;
  };
  invoice_file_url?: string | null;
};

const PurchaseNewInvoicePage = () => {
  const { form_data, form_metadata, invoice_file_url } = cast<NewInvoicePageProps>(usePage().props);
  const { supplier_info, seller_info, order_info, countries } = form_metadata;

  const form = useForm(form_data);

  const validateFields = () =>
    Object.entries(form.data.address_fields).reduce((isValid, [key, value]) => {
      if (key === "state" && form.data.address_fields.country_code !== "US") return isValid;
      if (!value.trim()) {
        form.setError(`address_fields.${key}`, "Setting error message for highlighting the field in UI");
        return false;
      }
      return isValid;
    }, true);

  const downloadInvoice = () => {
    if (!validateFields()) return;

    form.transform((data) => ({
      ...data,
      vat_id: form_metadata.display_vat_id ? data.vat_id : null,
    }));

    form.post(Routes.purchase_invoice_path(form.data.purchase_id), {
      only: ["flash", "invoice_file_url"],
      onSuccess: (page) => {
        const { invoice_file_url } = cast<{ invoice_file_url: string }>(page.props);
        if (invoice_file_url) window.open(invoice_file_url, "_blank");
      },
    });
  };

  return (
    <>
      <div>
        <Card asChild>
          <main className="mx-auto my-4 max-w-md [&>*]:flex-col [&>*]:items-stretch">
            <CardContent asChild>
              <header className="text-center">
                <h4 className="grow font-bold">{form_metadata.heading}</h4>
              </header>
            </CardContent>
            <CardContent>
              <Fieldset state={form.errors["address_fields.full_name"] ? "danger" : undefined} className="grow basis-0">
                <Label htmlFor="full_name">Full name</Label>
                <Input
                  id="full_name"
                  type="text"
                  value={form.data.address_fields.full_name}
                  onChange={(e) => form.setData("address_fields.full_name", e.target.value)}
                />
              </Fieldset>
              {form_metadata.display_vat_id ? (
                <Fieldset className="flex-1">
                  <FieldsetTitle>
                    <Label htmlFor="chargeable_vat_id">{form_metadata.vat_id_label}</Label>
                  </FieldsetTitle>
                  <Input
                    id="chargeable_vat_id"
                    type="text"
                    value={form.data.vat_id}
                    onChange={(e) => form.setData("vat_id", e.target.value)}
                  />
                </Fieldset>
              ) : null}
              <Fieldset state={form.errors["address_fields.street_address"] ? "danger" : undefined} className="flex-1">
                <Label htmlFor="street_address">Street address</Label>
                <Input
                  id="street_address"
                  type="text"
                  value={form.data.address_fields.street_address}
                  onChange={(e) => form.setData("address_fields.street_address", e.target.value)}
                />
              </Fieldset>
              <div style={{ display: "grid", gap: "var(--spacer-2)", gridTemplateColumns: "2fr 1fr 1fr" }}>
                <Fieldset state={form.errors["address_fields.city"] ? "danger" : undefined}>
                  <Label htmlFor="city">City</Label>
                  <Input
                    id="city"
                    type="text"
                    value={form.data.address_fields.city}
                    onChange={(e) => form.setData("address_fields.city", e.target.value)}
                  />
                </Fieldset>
                <Fieldset state={form.errors["address_fields.state"] ? "danger" : undefined}>
                  <Label htmlFor="state">State</Label>
                  <Input
                    id="state"
                    type="text"
                    value={form.data.address_fields.state}
                    onChange={(e) => form.setData("address_fields.state", e.target.value)}
                  />
                </Fieldset>
                <Fieldset state={form.errors["address_fields.zip_code"] ? "danger" : undefined}>
                  <Label htmlFor="zip_code">ZIP code</Label>
                  <Input
                    id="zip_code"
                    type="text"
                    value={form.data.address_fields.zip_code}
                    onChange={(e) => form.setData("address_fields.zip_code", e.target.value)}
                  />
                </Fieldset>
              </div>
              <Fieldset state={form.errors["address_fields.country_code"] ? "danger" : undefined}>
                <Label htmlFor="country">Country</Label>
                <Select
                  id="country"
                  value={form.data.address_fields.country_code}
                  onChange={(e) => form.setData("address_fields.country_code", e.target.value)}
                >
                  <option value="">Select country</option>
                  {Object.entries(countries).map(([code, name]) => (
                    <option key={code} value={code}>
                      {name}
                    </option>
                  ))}
                </Select>
              </Fieldset>
              <Fieldset className="flex-1">
                <FieldsetTitle>
                  <Label htmlFor="additional_notes">Additional notes</Label>
                </FieldsetTitle>
                <Textarea
                  id="additional_notes"
                  name="additional_notes"
                  value={form.data.additional_notes}
                  onChange={(e) => form.setData("additional_notes", e.target.value)}
                />
              </Fieldset>
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
                <div
                  style={{ opacity: form.data.address_fields.full_name.length ? undefined : "var(--disabled-opacity)" }}
                >
                  {form.data.address_fields.full_name || "Edgar Gumstein"}
                </div>
                <div
                  style={{
                    opacity: form.data.address_fields.street_address.length ? undefined : "var(--disabled-opacity)",
                  }}
                >
                  {form.data.address_fields.street_address || "123 Gum Road"}
                </div>
                <div>
                  <span
                    style={{ opacity: form.data.address_fields.city.length ? undefined : "var(--disabled-opacity)" }}
                  >
                    {`${form.data.address_fields.city || "San Francisco"},`}
                  </span>{" "}
                  <span
                    style={{ opacity: form.data.address_fields.state.length ? undefined : "var(--disabled-opacity)" }}
                  >
                    {form.data.address_fields.state || "CA"}
                  </span>{" "}
                  <span
                    style={{
                      opacity: form.data.address_fields.zip_code.length ? undefined : "var(--disabled-opacity)",
                    }}
                  >
                    {form.data.address_fields.zip_code || "94107"}
                  </span>
                </div>
                <div
                  style={{
                    opacity: form.data.address_fields.country_code.length ? undefined : "var(--disabled-opacity)",
                  }}
                >
                  {countries[form.data.address_fields.country_code] || "United States"}
                </div>
              </div>
              {form.data.additional_notes.length ? (
                <div>
                  <h6 className="font-bold">Additional notes</h6>
                  {form.data.additional_notes}
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
                {invoice_file_url ? (
                  <span className="grow">
                    Right-click{" "}
                    <a href={invoice_file_url} download>
                      here
                    </a>{" "}
                    and "Save as..." if the PDF hasn't been automatically downloaded to your computer.
                  </span>
                ) : (
                  <span className="grow">This invoice will be downloaded as a PDF to your computer.</span>
                )}
                <Button color="accent" onClick={downloadInvoice} disabled={form.processing}>
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
};

PurchaseNewInvoicePage.publicLayout = true;
export default PurchaseNewInvoicePage;
