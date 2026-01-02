import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";
import { Separator } from "$app/components/Separator";
import { Input } from "$app/components/ui/Input";
import { Pill } from "$app/components/ui/Pill";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { WithTooltip } from "$app/components/WithTooltip";

type Props = { card_types: { id: string; name: string }[] };
export const SearchPopover = ({ card_types }: Props) => {
  const searchParams = new URL(useOriginalLocation()).searchParams;
  const [open, setOpen] = React.useState(false);

  return (
    <Popover
      open={open}
      onToggle={setOpen}
      aria-label="Toggle Search"
      trigger={
        <WithTooltip tip="Search" position="bottom">
          <div className="button">
            <Icon name="solid-search" />
          </div>
        </WithTooltip>
      }
    >
      <div style={{ width: "23rem", maxWidth: "100%", display: "grid", gap: "var(--spacer-3)" }}>
        <form action={Routes.admin_search_users_path()} method="get" className="input-with-button">
          <Input>
            <Icon name="person" />
            <input
              autoFocus
              name="query"
              placeholder="Search users (email, name, ID)"
              type="text"
              defaultValue={searchParams.get("query") || ""}
            />
          </Input>
          <Button color="primary" type="submit">
            <Icon name="solid-search" />
          </Button>
        </form>
        <form action={Routes.admin_search_purchases_path()} method="get" className="input-with-button">
          <Input>
            <Icon name="solid-currency-dollar" />
            <input
              name="query"
              placeholder="Search purchases (email, IP, card, external ID)"
              type="text"
              defaultValue={searchParams.get("query") || ""}
            />
          </Input>
          <Button color="primary" type="submit">
            <Icon name="solid-search" />
          </Button>
        </form>
        <form action={Routes.admin_affiliates_path()} method="get" className="input-with-button">
          <Input>
            <Icon name="people-fill" />
            <input
              name="query"
              placeholder="Search affiliates (email, name, ID)"
              type="text"
              defaultValue={searchParams.get("query") || ""}
            />
          </Input>
          <Button color="primary" type="submit">
            <Icon name="solid-search" />
          </Button>
        </form>
        <Separator>or search by card</Separator>
        <form action={Routes.admin_search_purchases_path()} method="get" style={{ display: "contents" }}>
          <select name="card_type" defaultValue={searchParams.get("card_type") || ""}>
            <option value="">Choose card type</option>
            {card_types.map((cardType) => (
              <option key={cardType.id} value={cardType.id}>
                {cardType.name}
              </option>
            ))}
          </select>
          <Input>
            <Icon name="calendar-all" />
            <input
              name="transaction_date"
              placeholder="Date (02/22/2022)"
              type="text"
              defaultValue={searchParams.get("transaction_date") || ""}
            />
          </Input>
          <Input>
            <Icon name="lock-fill" />
            <input
              name="last_4"
              placeholder="Last 4 (7890)"
              type="text"
              pattern="[0-9]{4}"
              maxLength={4}
              autoComplete="cc-number"
              inputMode="numeric"
              defaultValue={searchParams.get("last_4") || ""}
            />
          </Input>
          <Input>
            <Icon name="outline-credit-card" />
            <input
              name="expiry_date"
              placeholder="Expiry (02/22)"
              type="text"
              defaultValue={searchParams.get("expiry_date") || ""}
            />
          </Input>
          <Input>
            <Pill className="-ml-2 shrink-0">$</Pill>
            <input
              name="price"
              placeholder="Price (9.99)"
              type="number"
              inputMode="decimal"
              step="0.01"
              defaultValue={searchParams.get("price") || ""}
            />
          </Input>
          <Button color="primary" type="submit">
            Search
          </Button>
        </form>
      </div>
    </Popover>
  );
};

export default register({ component: SearchPopover, propParser: createCast() });
