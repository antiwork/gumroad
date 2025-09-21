import cx from "classnames";
import * as React from "react";
import { cast, createCast } from "ts-safe-cast";

import { assertResponseError, request } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { Progress } from "$app/components/Progress";

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
          const referrer = document.referrer;
          if (referrer && new URL(referrer).origin === window.location.origin) {
            window.history.back();
          } else {
            window.location.href = Routes.dashboard_path();
          }
        }}
        title="Where are you located?"
        footer={
          <Button color="accent" disabled={checked.length !== checkboxes.length || saving} onClick={() => void save()}>
            {saving ? <Progress width="1em" /> : null}
            {saving ? "Saving..." : "Save"}
          </Button>
        }
      >
        <div className="paragraphs">
          <fieldset className={cx({ danger: !!error })}>
            <legend>
              <label htmlFor={`${uid}country`}>Country</label>
            </legend>
            <select id={`${uid}country`} value={country} onChange={(e) => setCountry(e.target.value)} disabled={saving}>
              {Object.entries(countries).map(([code, name]) => (
                <option key={code} value={code} disabled={name.includes("(not supported)")}>
                  {name}
                </option>
              ))}
            </select>
            {error ? <small>{error}</small> : null}
          </fieldset>
          <fieldset>
            <legend>To ensure prompt payouts, please check off each item:</legend>
            {checkboxes.map((item, i) => (
              <label key={item}>
                <input
                  type="checkbox"
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

export default register({ component: CountrySelectionModal, propParser: createCast() });
