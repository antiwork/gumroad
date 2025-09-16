import * as React from "react";
import { cast, createCast } from "ts-safe-cast";

import { SavedCreditCard } from "$app/parsers/card";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request, ResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { showAlert } from "$app/components/server-components/Alert";
import { WithTooltip } from "$app/components/WithTooltip";

type Props = {
  card: SavedCreditCard;
  can_remove: boolean;
  read_only: boolean;
};

export const CreditCardForm = ({ card, can_remove, read_only }: Props) => {
  const [status, setStatus] = React.useState<"removing" | "removed" | null>(null);
  const remove = asyncVoid(async () => {
    setStatus("removing");
    try {
      const response = await request({
        url: Routes.remove_credit_card_settings_payments_path(),
        method: "POST",
        accept: "json",
      });
      if (!response.ok) throw new ResponseError(cast<{ error: string }>(await response.json()).error);
      setStatus("removed");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
      setStatus(null);
    }
  });

  return status === "removed" ? null : (
    <section className="!p-4 md:!p-8">
      <header>
        <h2>Saved credit card</h2>
        <a href="/help/article/216-delete-credit-card-information" target="_blank" rel="noreferrer">
          Learn more.
        </a>
      </header>
      <div className="paragraphs">
        <div className="input read-only" aria-label="Saved credit card">
          <Icon name="outline-credit-card" />
          <span>{card.number}</span>
          <span style={{ marginLeft: "auto" }}>{card.expiration_date}</span>
        </div>
        {read_only ? null : (
          <WithTooltip
            tip={
              can_remove
                ? null
                : "Please cancel any active preorder or membership purchases before removing your credit card."
            }
            position="top"
          >
            <Button outline color="danger" onClick={remove} disabled={!can_remove || status === "removing"}>
              {status === "removing" ? "Removing..." : "Remove credit card"}
            </Button>
          </WithTooltip>
        )}
      </div>
    </section>
  );
};

export default register({ component: CreditCardForm, propParser: createCast() });
