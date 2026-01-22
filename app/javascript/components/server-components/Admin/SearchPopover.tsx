import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { PopoverRoot as Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { Separator } from "$app/components/Separator";
import { Pill } from "$app/components/ui/Pill";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

type Props = { card_types: { id: string; name: string }[] };
export const SearchPopover = ({ card_types }: Props) => {
  const searchParams = new URL(useOriginalLocation()).searchParams;
  return (
    <Popover>
      <PopoverTrigger aria-label="Toggle Search" asChild>
        <Button>
          <Icon name="solid-search" />
        </Button>
      </PopoverTrigger>
      <PopoverContent sideOffset={4}>
        <div className="grid w-96 max-w-full gap-3">
          <form action={Routes.admin_search_users_path()} method="get" className="flex gap-2">
            <div className="input">
              <Icon name="person" />
              <input
                autoFocus
                name="query"
                placeholder="Search users (email, name, ID)"
                type="text"
                defaultValue={searchParams.get("query") || ""}
              />
            </div>
            <Button color="primary" type="submit">
              <Icon name="solid-search" />
            </Button>
          </form>
          <form action={Routes.admin_search_purchases_path()} method="get" className="flex gap-2">
            <div className="input">
              <Icon name="solid-currency-dollar" />
              <input
                name="query"
                placeholder="Search purchases (email, IP, card, external ID)"
                type="text"
                defaultValue={searchParams.get("query") || ""}
              />
            </div>
            <Button color="primary" type="submit">
              <Icon name="solid-search" />
            </Button>
          </form>
          <form action={Routes.admin_affiliates_path()} method="get" className="flex gap-2">
            <div className="input">
              <Icon name="people-fill" />
              <input
                name="query"
                placeholder="Search affiliates (email, name, ID)"
                type="text"
                defaultValue={searchParams.get("query") || ""}
              />
            </div>
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
            <div className="input">
              <Icon name="calendar-all" />
              <input
                name="transaction_date"
                placeholder="Date (02/22/2022)"
                type="text"
                defaultValue={searchParams.get("transaction_date") || ""}
              />
            </div>
            <div className="input">
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
            </div>
            <div className="input">
              <Icon name="outline-credit-card" />
              <input
                name="expiry_date"
                placeholder="Expiry (02/22)"
                type="text"
                defaultValue={searchParams.get("expiry_date") || ""}
              />
            </div>
            <div className="input">
              <Pill className="-ml-2 shrink-0">$</Pill>
              <input
                name="price"
                placeholder="Price (9.99)"
                type="number"
                inputMode="decimal"
                step="0.01"
                defaultValue={searchParams.get("price") || ""}
              />
            </div>
            <Button color="primary" type="submit">
              Search
            </Button>
          </form>
        </div>
      </PopoverContent>
    </Popover>
  );
};

export default register({ component: SearchPopover, propParser: createCast() });
