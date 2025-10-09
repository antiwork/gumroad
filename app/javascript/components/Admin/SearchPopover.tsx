import { useForm } from "@inertiajs/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { WithTooltip } from "$app/components/WithTooltip";

type Props = { card_types: { id: string; name: string }[] };
export const SearchPopover = ({ card_types }: Props) => {
  const currentUrl = useOriginalLocation();
  const searchParams = new URL(currentUrl).searchParams;
  const [open, setOpen] = React.useState(false);

  const getInitialQuery = () => {
    const queryValue = searchParams.get("query") || "";
    const pathname = new URL(currentUrl).pathname;

    if (pathname.includes(Routes.admin_search_users_path())) {
      return { user_query: queryValue, purchase_query: "", affiliate_query: "" };
    } else if (pathname.includes(Routes.admin_search_purchases_path())) {
      return { user_query: "", purchase_query: queryValue, affiliate_query: "" };
    } else if (pathname.includes(Routes.admin_affiliates_path())) {
      return { user_query: "", purchase_query: "", affiliate_query: queryValue };
    }

    return { user_query: "", purchase_query: "", affiliate_query: "" };
  };

  const initialQueries = getInitialQuery();

  const { data, setData, get } = useForm({
    user_query: initialQueries.user_query,
    purchase_query: initialQueries.purchase_query,
    affiliate_query: initialQueries.affiliate_query,
    product_title_query: searchParams.get("product_title_query") || "",
    purchase_status: searchParams.get("purchase_status") || "",
    card_type: searchParams.get("card_type") || "",
    transaction_date: searchParams.get("transaction_date") || "",
    last_4: searchParams.get("last_4") || "",
    expiry_date: searchParams.get("expiry_date") || "",
    price: searchParams.get("price") || "",
  });

  const resetOtherQueryFields = (activeField?: keyof typeof data | null) => {
    const queryFields = ["user_query", "purchase_query", "affiliate_query"] as const;
    const cardFields = ["card_type", "transaction_date", "last_4", "expiry_date", "price"] as const;

    if (activeField === null) {
      queryFields.forEach((field) => setData(field, ""));
      return;
    }

    if (activeField && ["user_query", "purchase_query", "affiliate_query"].includes(activeField)) {
      cardFields.forEach((field) => setData(field, ""));
      queryFields.forEach((field) => {
        if (field !== activeField) setData(field, "");
      });
    }
  };

  const submit = (endpoint: string, queryParam?: keyof typeof data | null) => {
    const queryData = { query: queryParam ? String(data[queryParam]) : "" };
    const url = new URL(endpoint, window.location.origin);
    Object.entries(queryData).forEach(([key, value]) => {
      url.searchParams.set(key, value);
    });

    get(url.toString(), {
      onBefore: () => resetOtherQueryFields(queryParam),
      onSuccess: () => setOpen(false),
    });
  };

  const onUserInputChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setData("user_query", e.target.value);
  };

  const onSearchUsersFormSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    submit(Routes.admin_search_users_path(), "user_query");
  };

  const onPurchaseInputChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setData("purchase_query", e.target.value);
  };

  const onSearchPurchasesFormSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    submit(Routes.admin_search_purchases_path(), "purchase_query");
  };

  const onAffiliateInputChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setData("affiliate_query", e.target.value);
  };

  const onSearchAffiliatesFormSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    submit(Routes.admin_affiliates_path(), "affiliate_query");
  };

  const onCardTypeChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    setData("card_type", e.target.value);
  };

  const onTransactionDateChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setData("transaction_date", e.target.value);
  };

  const onLast4Change = (e: React.ChangeEvent<HTMLInputElement>) => {
    setData("last_4", e.target.value);
  };

  const onExpiryDateChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setData("expiry_date", e.target.value);
  };

  const onPriceChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setData("price", e.target.value);
  };

  const onSearchCardsFormSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    submit(Routes.admin_cards_path(), null);
  };

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
      <div className="grid w-96 max-w-full gap-3">
        <form onSubmit={onSearchUsersFormSubmit} className="input-with-button">
          <div className="input">
            <Icon name="person" />
            <input
              autoFocus
              name="query"
              placeholder="Search users (email, name, ID)"
              type="text"
              value={data.user_query}
              onChange={onUserInputChange}
            />
          </div>
          <Button color="primary" type="submit">
            <Icon name="solid-search" />
          </Button>
        </form>

        <form onSubmit={onSearchPurchasesFormSubmit} className="input-with-button">
          <div className="input">
            <Icon name="solid-currency-dollar" />
            <input
              name="query"
              placeholder="Search purchases (email, IP, card, external ID)"
              type="text"
              value={data.purchase_query}
              onChange={onPurchaseInputChange}
            />
          </div>
          <Button color="primary" type="submit">
            <Icon name="solid-search" />
          </Button>
        </form>

        <form onSubmit={onSearchAffiliatesFormSubmit} className="input-with-button">
          <div className="input">
            <Icon name="people-fill" />
            <input
              name="query"
              placeholder="Search affiliates (email, name, ID)"
              type="text"
              value={data.affiliate_query}
              onChange={onAffiliateInputChange}
            />
          </div>
          <Button color="primary" type="submit">
            <Icon name="solid-search" />
          </Button>
        </form>

        <div role="separator">or search by card</div>

        <form onSubmit={onSearchCardsFormSubmit} style={{ display: "contents" }}>
          <select name="card_type" value={data.card_type} onChange={onCardTypeChange}>
            <option>Choose card type</option>
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
              value={data.transaction_date}
              onChange={onTransactionDateChange}
            />
          </div>
          <div className="input">
            <Icon name="lock-fill" />
            <input
              name="last_4"
              placeholder="Last 4 (7890)"
              type="number"
              value={data.last_4}
              minLength={4}
              maxLength={4}
              onChange={onLast4Change}
            />
          </div>
          <div className="input">
            <Icon name="outline-credit-card" />
            <input
              name="expiry_date"
              placeholder="Expiry (02/22)"
              type="text"
              value={data.expiry_date}
              onChange={onExpiryDateChange}
            />
          </div>
          <div className="input">
            <div className="pill">$</div>
            <input
              name="price"
              placeholder="Price (9.99)"
              type="number"
              step="0.01"
              value={data.price}
              onChange={onPriceChange}
            />
          </div>
          <Button color="primary" type="submit">
            Search
          </Button>
        </form>
      </div>
    </Popover>
  );
};

export default SearchPopover;
