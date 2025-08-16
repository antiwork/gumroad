import React from "react";
import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import cx from "classnames";
import { Select } from "$app/components/Select";
import { NumberInput } from "$app/components/NumberInput";
import { DateInput } from "$app/components/DateInput";
import { PriceInput } from "$app/components/PriceInput";
import { Details } from "$app/components/Details";
import { DiscountInput } from "$app/components/CheckoutDashboard/DiscountInput";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { type DiscountCollection } from "$app/data/discount_collection";
import { CurrencyCode } from "$app/utils/currency";

type Product = {
  id: string;
  name: string;
  archived: boolean;
  currency_type: CurrencyCode;
  is_tiered_membership: boolean;
};

type BulkCreateCodesFormProps = {
  collection: DiscountCollection | null;
  products: Product[];
  cancel: () => void;
  save: (payload: {
    count: number;
    name_template: string;
    discount: { type: "cents" | "percent"; value: number };
    selectedProductIds: string[];
    universal: boolean;
    max_purchase_count: number | null;
    valid_at: string | null;
    expires_at: string | null;
    minimum_quantity: number | null;
    duration_in_billing_cycles: number | null;
    minimum_amount_cents: number | null;
  }) => void;
  isLoading: boolean;
};

const BulkCreateCodesForm = ({
  collection,
  products,
  cancel,
  save,
  isLoading,
}: BulkCreateCodesFormProps) => {
  const [count, setCount] = React.useState<{ value: number; error?: boolean }>({ value: 10 });
  const [nameTemplate, setNameTemplate] = React.useState<{ value: string; error?: boolean }>({ value: "Event Code {n}" });

  const [discount, setDiscount] = React.useState<{ type: "percent" | "cents"; value: number | null; error?: boolean }>({
    type: "percent",
    value: 10,
  });

  const [universal, setUniversal] = React.useState(false);
  const [selectedProductIds, setSelectedProductIds] = React.useState<{ value: string[]; error?: boolean }>({ value: [] });

  const [limitQuantity, setLimitQuantity] = React.useState(false);
  const [maxQuantity, setMaxQuantity] = React.useState<{ value: number | null; error?: boolean }>({ value: 1 });

  const [limitValidity, setLimitValidity] = React.useState(false);
  const [validAt, setValidAt] = React.useState(new Date());
  const [expiresAt, setExpiresAt] = React.useState<{ error?: boolean; value: Date }>({
    value: new Date(new Date().setHours(new Date().getHours() + 24)),
  });
  const [hasNoEndDate, setHasNoEndDate] = React.useState(false);

  const [hasMinimumQuantity, setHasMinimumQuantity] = React.useState(false);
  const [minimumQuantity, setMinimumQuantity] = React.useState<{ value: number | null; error?: boolean }>({ value: null });

  const [hasMinimumAmount, setHasMinimumAmount] = React.useState(false);
  const [minimumAmount, setMinimumAmount] = React.useState<{ value: number | null; error?: boolean }>({ value: null });

  const [currencyCode, setCurrencyCode] = React.useState<CurrencyCode>("usd");
  const [durationInBillingCycles, setDurationInBillingCycles] = React.useState<number | null>(null);

  const selectedProducts = products.filter(({ id }) => selectedProductIds.value.includes(id));
  const canSetDuration = (universal ? products : selectedProducts).some(({ is_tiered_membership }) => is_tiered_membership);

  const uid = React.useId();

  const handleSubmit = () => {
    if (
      count.value <= 0 ||
      nameTemplate.value === "" ||
      discount.value === null ||
      (limitQuantity && maxQuantity.value === null) ||
      (!hasNoEndDate && validAt > expiresAt.value) ||
      (!universal && selectedProductIds.value.length === 0) ||
      (hasMinimumQuantity && minimumQuantity.value === null) ||
      (hasMinimumAmount && minimumAmount.value === null)
    ) {
      setCount((prevCount) => ({ ...prevCount, error: prevCount.value <= 0 }));
      setNameTemplate((prevTemplate) => ({ ...prevTemplate, error: prevTemplate.value === "" }));
      setDiscount((prevDiscount) => ({ ...prevDiscount, error: prevDiscount.value === null }));
      setMaxQuantity((prevMaxQuantity) => ({
        ...prevMaxQuantity,
        error: limitQuantity && prevMaxQuantity.value === null,
      }));
      setExpiresAt((prevExpiresAt) => ({ ...prevExpiresAt, error: !hasNoEndDate && validAt > prevExpiresAt.value }));
      setSelectedProductIds((prevSelectedProductIds) => ({
        ...prevSelectedProductIds,
        error: !universal && selectedProductIds.value.length === 0,
      }));
      setMinimumQuantity((prevMinimumQuantity) => ({
        ...prevMinimumQuantity,
        error: hasMinimumQuantity && prevMinimumQuantity.value === null,
      }));
      setMinimumAmount((prevMinimumAmount) => ({
        ...prevMinimumAmount,
        error: hasMinimumAmount && prevMinimumAmount.value === null,
      }));
      return;
    }

    save({
      count: count.value,
      name_template: nameTemplate.value,
      discount: { type: discount.type, value: discount.value },
      selectedProductIds: selectedProductIds.value,
      universal,
      max_purchase_count: limitQuantity ? maxQuantity.value : null,
      valid_at: limitValidity ? validAt.toISOString() : null,
      expires_at: limitValidity && !hasNoEndDate ? expiresAt.value.toISOString() : null,
      minimum_quantity: hasMinimumQuantity ? minimumQuantity.value : null,
      duration_in_billing_cycles: canSetDuration ? durationInBillingCycles : null,
      minimum_amount_cents: hasMinimumAmount ? minimumAmount.value : null,
    });
  };

  return (
    <main>
      <header>
        <h1>Bulk Create Discount Codes</h1>
        <div className="actions">
          <Button onClick={cancel} disabled={isLoading}>
            <Icon name="x-square" />
            Cancel
          </Button>
          <Button color="accent" onClick={handleSubmit} disabled={isLoading}>
            {isLoading ? "Creating codes..." : `Create ${count.value} codes`}
          </Button>
        </div>
      </header>
      <form>
        <section>
          <header>
            <div className="paragraphs">
              <div>Generate multiple discount codes at once for your collection "{collection?.name}".</div>
              <div>
                Each code will be unique and can be used independently. Use {nameTemplate.value} to automatically number your codes.
              </div>
              <a data-helper-prompt="How do I bulk create discount codes?">Learn more</a>
            </div>
          </header>

          <fieldset className={cx({ danger: count.error })}>
            <legend>
              <label htmlFor={`${uid}count`}>Number of codes to create</label>
            </legend>
            <NumberInput
              value={count.value}
              onChange={(value) => {
                if (value === null || value > 0) setCount({ value: value || 1 });
              }}
            >
              {(props) => (
                <input
                  id={`${uid}count`}
                  placeholder="10"
                  aria-invalid={count.error}
                  {...props}
                />
              )}
            </NumberInput>
          </fieldset>

          <fieldset className={cx({ danger: nameTemplate.error })}>
            <legend>
              <label htmlFor={`${uid}nameTemplate`}>Name template</label>
            </legend>
            <input
              type="text"
              id={`${uid}nameTemplate`}
              placeholder="Event Code {n}"
              value={nameTemplate.value}
              onChange={(evt) => setNameTemplate({ value: evt.target.value })}
              aria-invalid={nameTemplate.error}
            />
            <small>Use {"{n}"} to automatically number your codes (e.g., "Event Code 1", "Event Code 2")</small>
          </fieldset>

          <fieldset className={cx({ danger: selectedProductIds.error })}>
            <legend>
              <label htmlFor={`${uid}products`}>Products</label>
            </legend>
            <Select
              inputId={`${uid}products`}
              instanceId={`${uid}products`}
              options={products
                .filter(
                  ({ currency_type }) =>
                    discount.type !== "cents" ||
                    selectedProductIds.value.length === 0 ||
                    currency_type === currencyCode,
                )
                .filter((product) => !product.archived)
                .map((product) => ({ id: product.id, label: product.name }))}
              value={selectedProducts.map(({ id, name: label }) => ({
                id,
                label,
              }))}
              isMulti
              isClearable
              placeholder="Products to which these discounts will apply"
              onChange={(selectedIds) => {
                setSelectedProductIds({ value: selectedIds.map(({ id }) => id) });
                setCurrencyCode(
                  (prevCurrencyCode) =>
                    products.find(({ id }) => id === selectedIds[0]?.id)?.currency_type ?? prevCurrencyCode,
                );
              }}
              isDisabled={universal}
              aria-invalid={selectedProductIds.error}
            />
            <label>
              <input
                type="checkbox"
                checked={universal}
                onChange={(evt) => {
                  setUniversal(evt.target.checked);
                  setSelectedProductIds({ value: [] });
                }}
                aria-invalid={selectedProductIds.error}
              />
              All products
            </label>
          </fieldset>

          {canSetDuration ? (
            <fieldset>
              <legend>
                <label htmlFor={`${uid}duration`}>Discount duration for memberships</label>
              </legend>
              <TypeSafeOptionSelect
                id={`${uid}duration`}
                value={durationInBillingCycles === null ? "forever" : "once"}
                onChange={(id) => setDurationInBillingCycles(id === "forever" ? null : 1)}
                options={[
                  { id: "forever", label: "Forever" },
                  { id: "once", label: "Once (first billing period only)" },
                ]}
              />
            </fieldset>
          ) : null}

          <fieldset>
            <legend>Type</legend>
            <DiscountInput
              discount={discount}
              setDiscount={setDiscount}
              currencyCode={currencyCode}
              currencyCodeSelector={
                universal
                  ? {
                      options: [...new Set(products.map(({ currency_type }) => currency_type))] as CurrencyCode[],
                      onChange: setCurrencyCode,
                    }
                  : undefined
              }
              disableFixedAmount={
                discount.type === "percent" &&
                !universal &&
                !selectedProducts.every(({ currency_type }) => currency_type === currencyCode)
              }
            />
          </fieldset>

          <fieldset style={{ gap: "var(--spacer-4)" }}>
            <legend>Settings</legend>
            <Details
              className="toggle"
              open={limitQuantity}
              summary={
                <label>
                  <input
                    type="checkbox"
                    role="switch"
                    checked={limitQuantity}
                    onChange={(evt) => setLimitQuantity(evt.target.checked)}
                  />
                  Limit quantity per code
                </label>
              }
            >
              <div className="dropdown">
                <fieldset className={cx({ danger: maxQuantity.error })}>
                  <legend>
                    <label htmlFor={`${uid}quantity`}>Quantity per code</label>
                  </legend>
                  <NumberInput
                    value={maxQuantity.value}
                    onChange={(value) => {
                      if (value === null || value >= 0) setMaxQuantity({ value });
                    }}
                  >
                    {(props) => (
                      <input id={`${uid}quantity`} placeholder="1" aria-invalid={maxQuantity.error} {...props} />
                    )}
                  </NumberInput>
                </fieldset>
              </div>
            </Details>

            <Details
              className="toggle"
              open={limitValidity}
              summary={
                <label>
                  <input
                    type="checkbox"
                    role="switch"
                    checked={limitValidity}
                    onChange={(evt) => setLimitValidity(evt.target.checked)}
                  />
                  Limit validity period
                </label>
              }
            >
              <div
                className="dropdown"
                style={{
                  display: "grid",
                  gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
                  gap: "var(--spacer-4)",
                }}
              >
                <fieldset>
                  <legend>
                    <label htmlFor={`${uid}validAt`}>Valid from</label>
                  </legend>
                  <DateInput
                    withTime
                    id={`${uid}validAt`}
                    value={validAt}
                    onChange={(date) => {
                      if (date) setValidAt(date);
                    }}
                  />
                  <label>
                    <input
                      type="checkbox"
                      checked={hasNoEndDate}
                      onChange={(evt) => setHasNoEndDate(evt.target.checked)}
                    />
                    No end date
                  </label>
                </fieldset>
                <fieldset className={cx({ danger: expiresAt.error })}>
                  <legend>
                    <label htmlFor={`${uid}expiresAt`}>Valid until</label>
                  </legend>
                  <DateInput
                    withTime
                    id={`${uid}expiresAt`}
                    value={expiresAt.value}
                    onChange={(value) => {
                      if (value) setExpiresAt({ value });
                    }}
                    disabled={hasNoEndDate}
                    aria-invalid={expiresAt.error ?? false}
                  />
                </fieldset>
              </div>
            </Details>

            <Details
              className="toggle"
              open={hasMinimumAmount}
              summary={
                <label>
                  <input
                    type="checkbox"
                    role="switch"
                    checked={hasMinimumAmount}
                    onChange={(evt) => setHasMinimumAmount(evt.target.checked)}
                  />
                  Set a minimum qualifying amount
                </label>
              }
            >
              <div className="dropdown">
                <fieldset className={cx({ danger: minimumAmount.error })}>
                  <legend>
                    <label htmlFor={`${uid}minimumAmount`}>Minimum amount</label>
                  </legend>
                  <PriceInput
                    id={`${uid}minimumAmount`}
                    currencyCode={currencyCode}
                    cents={minimumAmount.value}
                    onChange={(value) => setMinimumAmount({ value })}
                    placeholder="0"
                    hasError={minimumAmount.error ?? false}
                  />
                </fieldset>
              </div>
            </Details>

            <Details
              className="toggle"
              open={hasMinimumQuantity}
              summary={
                <label>
                  <input
                    type="checkbox"
                    role="switch"
                    checked={hasMinimumQuantity}
                    onChange={(evt) => setHasMinimumQuantity(evt.target.checked)}
                  />
                  Set a minimum quantity
                </label>
              }
            >
              <div className="dropdown">
                <fieldset className={cx({ danger: minimumQuantity.error })}>
                  <legend>
                    <label htmlFor={`${uid}minimumQuantity`}>Minimum quantity per product</label>
                  </legend>
                  <NumberInput
                    value={minimumQuantity.value}
                    onChange={(value) => {
                      if (value === null || value >= 0) setMinimumQuantity({ value });
                    }}
                  >
                    {(props) => (
                      <input
                        id={`${uid}minimumQuantity`}
                        placeholder="0"
                        aria-invalid={minimumQuantity.error}
                        {...props}
                      />
                    )}
                  </NumberInput>
                </fieldset>
              </div>
            </Details>
          </fieldset>
        </section>
      </form>
    </main>
  );
};

export { BulkCreateCodesForm };
