import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { SettingPage } from "$app/parsers/settings";

import { Layout as SettingsLayout } from "$app/components/Settings/Layout";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { FormSection } from "$app/components/ui/FormSection";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Select } from "$app/components/ui/Select";
import { Switch } from "$app/components/ui/Switch";
import { Textarea } from "$app/components/ui/Textarea";

type BillingDetail = {
  full_name: string;
  business_name: string;
  business_id: string;
  street_address: string;
  city: string;
  state: string;
  zip_code: string;
  country_code: string;
  additional_notes: string;
  auto_email_invoice_enabled: boolean;
};

type BillingPageProps = {
  settings_pages: SettingPage[];
  billing_detail: BillingDetail;
  countries: Record<string, string>;
  business_id_country_codes: string[];
  business_id_labels: Record<string, string>;
};

export default function BillingSettingsPage() {
  const props = cast<BillingPageProps>(usePage().props);
  const uid = React.useId();

  const form = useForm({ billing_detail: props.billing_detail });

  const isUsAddress = form.data.billing_detail.country_code === "US";
  const showBusinessId = props.business_id_country_codes.includes(form.data.billing_detail.country_code);
  const businessIdLabel = props.business_id_labels[form.data.billing_detail.country_code] ?? "Business ID";

  const update = (patch: Partial<BillingDetail>) =>
    form.setData("billing_detail", { ...form.data.billing_detail, ...patch });

  const fieldState = (name: keyof BillingDetail) =>
    form.errors[`billing_detail.${name}`] ? ("danger" as const) : undefined;

  const changeCountry = (country_code: string) => {
    update({
      country_code,
      state: country_code === "US" ? form.data.billing_detail.state : "",
      business_id: props.business_id_country_codes.includes(country_code) ? form.data.billing_detail.business_id : "",
    });
  };

  const handleSave = () => {
    form.put(Routes.settings_billing_path(), { preserveScroll: true });
  };

  return (
    <SettingsLayout currentPage="billing" pages={props.settings_pages} onSave={handleSave} canUpdate={!form.processing}>
      <form>
        <FormSection
          header={
            <>
              <h2>Billing details</h2>
              <div>Stored once and used to pre-fill your invoices.</div>
            </>
          }
        >
          <Fieldset state={fieldState("full_name")}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-full_name`}>Full name</Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-full_name`}
              type="text"
              value={form.data.billing_detail.full_name}
              onChange={(e) => update({ full_name: e.target.value })}
            />
          </Fieldset>

          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-business_name`}>Business name (optional)</Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-business_name`}
              type="text"
              value={form.data.billing_detail.business_name}
              onChange={(e) => update({ business_name: e.target.value })}
            />
          </Fieldset>

          <Fieldset state={fieldState("street_address")}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-street_address`}>Street address</Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-street_address`}
              type="text"
              value={form.data.billing_detail.street_address}
              onChange={(e) => update({ street_address: e.target.value })}
            />
          </Fieldset>

          <div
            style={{
              display: "grid",
              gap: "var(--spacer-2)",
              gridTemplateColumns: isUsAddress ? "2fr 1fr 1fr" : "1fr 1fr",
            }}
          >
            <Fieldset state={fieldState("city")}>
              <Label htmlFor={`${uid}-city`}>City</Label>
              <Input
                id={`${uid}-city`}
                type="text"
                value={form.data.billing_detail.city}
                onChange={(e) => update({ city: e.target.value })}
              />
            </Fieldset>

            {isUsAddress ? (
              <Fieldset state={fieldState("state")}>
                <Label htmlFor={`${uid}-state`}>State</Label>
                <Input
                  id={`${uid}-state`}
                  type="text"
                  value={form.data.billing_detail.state}
                  onChange={(e) => update({ state: e.target.value })}
                />
              </Fieldset>
            ) : null}

            <Fieldset state={fieldState("zip_code")}>
              <Label htmlFor={`${uid}-zip_code`}>ZIP code</Label>
              <Input
                id={`${uid}-zip_code`}
                type="text"
                value={form.data.billing_detail.zip_code}
                onChange={(e) => update({ zip_code: e.target.value })}
              />
            </Fieldset>
          </div>

          <Fieldset state={fieldState("country_code")}>
            <Label htmlFor={`${uid}-country_code`}>Country</Label>
            <Select
              id={`${uid}-country_code`}
              value={form.data.billing_detail.country_code}
              onChange={(e) => changeCountry(e.target.value)}
            >
              <option value="">Select country</option>
              {Object.entries(props.countries).map(([code, name]) => (
                <option key={code} value={code}>
                  {name}
                </option>
              ))}
            </Select>
          </Fieldset>

          {showBusinessId ? (
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-business_id`}>{businessIdLabel} (optional)</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-business_id`}
                type="text"
                value={form.data.billing_detail.business_id}
                onChange={(e) => update({ business_id: e.target.value })}
              />
            </Fieldset>
          ) : null}

          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-additional_notes`}>Additional notes (optional)</Label>
            </FieldsetTitle>
            <Textarea
              id={`${uid}-additional_notes`}
              value={form.data.billing_detail.additional_notes}
              onChange={(e) => update({ additional_notes: e.target.value })}
            />
          </Fieldset>
        </FormSection>

        <FormSection header={<h2>Delivery</h2>}>
          <Switch
            checked={form.data.billing_detail.auto_email_invoice_enabled}
            onChange={(e) => update({ auto_email_invoice_enabled: e.target.checked })}
            label="Email me an invoice PDF with every purchase receipt"
          />
        </FormSection>
      </form>
    </SettingsLayout>
  );
}
