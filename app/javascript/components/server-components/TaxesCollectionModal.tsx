import * as React from "react";
import { cast, createCast } from "ts-safe-cast";

import { assertResponseError, request, ResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Modal } from "$app/components/Modal";

type Props = {
  taxesOwed: string | null;
  creditCreationDate: string | null;
  name: string | null;
};

type SaveOptInResponse = {
  success: boolean;
  error?: string;
};

export const TaxesCollectionModal = ({ taxesOwed, creditCreationDate, name }: Props) => {
  const uid = React.useId();
  const [signature, setSignature] = React.useState("");
  const [optingIn, setOptingIn] = React.useState(false);
  const [saving, setSaving] = React.useState(false);
  const [error, setError] = React.useState("");

  const save = async () => {
    setSaving(true);
    try {
      const response = await request({
        method: "POST",
        url: Routes.opt_in_to_au_backtax_collection_settings_payments_path(),
        accept: "json",
        data: { signature },
      });
      if (!response.ok) throw new ResponseError();
      const optInResponse: SaveOptInResponse = cast<SaveOptInResponse>(await response.json());
      if (optInResponse.success) return window.location.reload();
      throw new ResponseError(optInResponse.error);
    } catch (e) {
      assertResponseError(e);
      setError(e.message);
    }
    setSaving(false);
  };

  return (
    <div>
      <Button color="accent" onClick={() => setOptingIn(true)}>
        Opt-in to backtaxes collection
      </Button>
      {optingIn ? (
        <Modal
          open
          onClose={() => setOptingIn(false)}
          title="Opt-in to backtaxes collection"
          footer={
            <div>
              <Button color="accent" disabled={signature.length === 0 || saving} onClick={() => void save()}>
                {saving ? <LoadingSpinner /> : null}
                {saving ? "Saving..." : "Save and opt-in"}
              </Button>
            </div>
          }
        >
          <div className="flex flex-col gap-4">
            After opt-in, a negative credit in the amount of {taxesOwed || ""} will be applied to your account on{" "}
            {creditCreationDate || ""}.
            <fieldset>
              <label htmlFor={`${uid}optInFullName`}>
                <span>
                  Type your full name to opt-in: <b>{name || ""}</b>
                </span>
              </label>
              <input
                id={`${uid}optInFullName`}
                type="text"
                aria-invalid={error.length !== 0}
                placeholder="Full name"
                disabled={saving}
                value={signature}
                onChange={(e) => {
                  setSignature(e.target.value);
                }}
                maxLength={100}
              />
              {error ? <small>{error}</small> : null}
            </fieldset>
          </div>
        </Modal>
      ) : null}
    </div>
  );
};

export default register({ component: TaxesCollectionModal, propParser: createCast() });
