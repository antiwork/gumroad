import { router } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { assertResponseError, request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Modal } from "$app/components/Modal";
import { Checkbox } from "$app/components/ui/Checkbox";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Label } from "$app/components/ui/Label";
import { Select } from "$app/components/ui/Select";

type Props = {
  country: string | null;
  countries: Record<string, string>;
};

export const CountrySelectionModal = ({ country: initialCountry, countries }: Props) => {
  const uid = React.useId();
  const [country, setCountry] = React.useState(initialCountry ?? "US");
  const [saving, setSaving] = React.useState(false);
  // Save is only enabled once every box is checked, so each line has to be something the seller can
  // truthfully check. The old list asked separately for "proof of residence within this country" and
  // "individual, or my business is registered in the country above", which contradicted itself for a
  // legitimate and supported case: the non-resident owner of a company registered in the chosen
  // country (for example, someone living in China who owns a US LLC with an EIN and a US business
  // bank account). Their business genuinely is registered in the US, but they have no US residence
  // to prove, so they could never check all three and could never get past this modal to reach the
  // Business account type on the payments page. Residence and business registration are two ways of
  // establishing the same connection to the country, so they belong in one either/or line.
  const checkboxes = [
    "I have a valid, government-issued photo ID",
    "I live in the country above, or my business is registered there",
  ];
  const [checked, setChecked] = React.useState<number[]>([]);
  const [error, setError] = React.useState("");

  const save = async () => {
    setSaving(true);
    try {
      const response = await request({
        method: "POST",
        url: Routes.set_country_settings_payments_path(),
        accept: "json",
        data: { country },
      });
      if (response.ok) return window.location.reload();
      const { error } = typia.assert<{ error: string }>(await response.json());
      setError(error);
    } catch (e) {
      assertResponseError(e);
      setError("Sorry, something went wrong. Please try again.");
    }
    setSaving(false);
  };

  return (
    <div>
      <Modal
        open
        onClose={() => {
          const previousRoute = sessionStorage.getItem("inertia_previous_route");
          if (previousRoute) {
            window.history.back();
          } else {
            router.get(Routes.dashboard_path());
          }
        }}
        title="Where are you located?"
        footer={
          <Button color="accent" disabled={checked.length !== checkboxes.length || saving} onClick={() => void save()}>
            {saving ? <LoadingSpinner /> : null}
            {saving ? "Saving..." : "Save"}
          </Button>
        }
      >
        <div className="flex flex-col gap-4">
          <Fieldset state={error ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}country`}>Country</Label>
            </FieldsetTitle>
            <Select id={`${uid}country`} value={country} onChange={(e) => setCountry(e.target.value)} disabled={saving}>
              {Object.entries(countries).map(([code, name]) => (
                <option key={code} value={code} disabled={name.includes("(not supported)")}>
                  {name}
                </option>
              ))}
            </Select>
            {error ? <FieldsetDescription>{error}</FieldsetDescription> : null}
          </Fieldset>
          <Fieldset>
            <FieldsetTitle>To ensure prompt payouts, please check off each item:</FieldsetTitle>
            {checkboxes.map((item, i) => (
              <Label key={item}>
                <Checkbox
                  checked={checked.includes(i)}
                  onChange={(e) =>
                    setChecked(e.target.checked ? [...checked, i] : checked.filter((item) => item !== i))
                  }
                />{" "}
                {item}
              </Label>
            ))}
          </Fieldset>
        </div>
      </Modal>
    </div>
  );
};

export default CountrySelectionModal;
