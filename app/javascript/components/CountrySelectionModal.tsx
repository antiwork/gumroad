import { router } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { classNames } from "$app/utils/classNames";
import { assertResponseError, request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Checkbox } from "$app/components/Checkbox";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Modal } from "$app/components/Modal";

type Props = {
  country: string | null;
  countries: Record<string, string>;
};

export const CountrySelectionModal = ({ country: initialCountry, countries }: Props) => {
  const uid = React.useId();
  const [country, setCountry] = React.useState(initialCountry ?? "US");
  const [saving, setSaving] = React.useState(false);
  const checkboxes = [
    "I have a valid, government-issued photo ID",
    "I have proof of residence within this country",
    "If I am signing up as a business, it is registered in the country above",
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
      const { error } = cast<{ error: string }>(await response.json());
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
          <fieldset className={classNames("flex flex-col gap-2", !!error && "danger")}>
            <legend className="mb-2">
              <label htmlFor={`${uid}country`}>Country</label>
            </legend>
            <div className="relative">
              <select
                id={`${uid}country`}
                className={classNames(
                  "bg-filled h-12 w-full appearance-none rounded border px-3 pr-8 font-[inherit] text-base focus:border-accent focus:ring-1 focus:ring-accent focus:outline-none disabled:opacity-50",
                  error ? "border-danger" : "border-border",
                )}
                value={country}
                onChange={(e) => setCountry(e.target.value)}
                disabled={saving}
              >
                {Object.entries(countries).map(([code, name]) => (
                  <option key={code} value={code} disabled={name.includes("(not supported)")}>
                    {name}
                  </option>
                ))}
              </select>
              <div className="pointer-events-none absolute inset-y-0 right-3 flex items-center">
                <Icon name="outline-cheveron-down" className="h-4 w-4 text-muted" />
              </div>
            </div>
            {error ? <small className="text-danger">{error}</small> : null}
          </fieldset>

          <fieldset className="flex flex-col gap-2">
            <legend className="mb-2 text-base font-bold">To ensure prompt payouts, please check off each item:</legend>
            {checkboxes.map((item, i) => (
              <label key={item} className="flex cursor-pointer gap-3">
                <Checkbox
                  checked={checked.includes(i)}
                  onChange={(e) =>
                    setChecked(e.target.checked ? [...checked, i] : checked.filter((item) => item !== i))
                  }
                />{" "}
                {item}
              </label>
            ))}
          </fieldset>
          <h4>You may have to forfeit your balance if you want to change your country in the future.</h4>
        </div>
      </Modal>
    </div>
  );
};

export default CountrySelectionModal;
