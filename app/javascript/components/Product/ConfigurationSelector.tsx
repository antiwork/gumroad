import cx from "classnames";
import {
  addMinutes,
  compareAsc,
  differenceInMinutes,
  eachDayOfInterval,
  eachMinuteOfInterval,
  endOfDay,
  interval,
  isEqual,
  max,
  min,
  roundToNearestMinutes,
  startOfDay,
  subMinutes,
} from "date-fns";
import * as React from "react";

import { CallAvailability, getRemainingCallAvailabilities } from "$app/data/call_availabilities";
import { Discount } from "$app/parsers/checkout";
import { ProductNativeType } from "$app/parsers/product";
import {
  CurrencyCode,
  formatPriceCentsWithCurrencySymbol,
  formatPriceCentsWithoutCurrencySymbol,
  formatPriceCentsWithoutCurrencySymbolAndComma,
  getMinPriceCents,
} from "$app/utils/currency";
import { formatCallDate } from "$app/utils/date";
import { applyOfferCodeToCents } from "$app/utils/offer-code";
import { formatInstallmentPaymentSchedule } from "$app/utils/price";
import { recurrenceNames, recurrenceLabels, RecurrenceId } from "$app/utils/recurringPricing";

import { Breaklines } from "$app/components/Breaklines";
import { Button } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { NumberInput } from "$app/components/NumberInput";
import { PriceInput } from "$app/components/PriceInput";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { Calendar } from "$app/components/ui/Calendar";
import { useRunOnce } from "$app/components/useRunOnce";

const PWYWInput = React.forwardRef<
  HTMLInputElement,
  {
    currencyCode: CurrencyCode;
    cents: number | null;
    onChange: (newCents: number | null) => void;
    onBlur: () => void;
    suggestedPriceCents: number | null;
    hasError: boolean;
    hideLabel?: boolean;
  }
>(({ currencyCode, cents, onChange, suggestedPriceCents, hasError, onBlur, hideLabel }, ref) => {
  const uid = React.useId();

  return (
    <fieldset className={cx({ danger: hasError })}>
      {!hideLabel ? (
        <legend>
          <label htmlFor={uid}>Name a fair price:</label>
        </legend>
      ) : null}
      <PriceInput
        id={uid}
        currencyCode={currencyCode}
        cents={cents}
        onChange={onChange}
        placeholder={`${formatPriceCentsWithoutCurrencySymbol(currencyCode, suggestedPriceCents || 0)}+`}
        hasError={hasError}
        onBlur={() => {
          const minPriceCents = getMinPriceCents(currencyCode);
          if (cents && cents < minPriceCents) onChange(minPriceCents);
          onBlur();
        }}
        ref={ref}
        ariaLabel="Price"
      />
    </fieldset>
  );
});
PWYWInput.displayName = "PWYWInput";

export type PriceSelection = {
  rent: boolean;
  optionId: string | null;
  price: { error: boolean; value: number | null };
  quantity: number;
  recurrence: RecurrenceId | null;
  callStartTime: string | null;
  payInInstallments: boolean;
};

export type Option = {
  id: string;
  name: string;
  quantity_left: number | null;
  description: string;
  price_difference_cents: number | null;
  recurrence_price_values:
    | {
        [key in RecurrenceId]?: { price_cents: number; suggested_price_cents: number | null };
      }
    | null;
  is_pwyw: boolean;
  duration_in_minutes: number | null;
  status?: string | undefined;
};

export type Rental = { price_cents: number; rent_only: boolean };

export type PurchasingPowerParityDetails = { country: string; factor: number; minimum_price: number };

export type Recurrences = {
  default: RecurrenceId;
  enabled: { recurrence: RecurrenceId; price_cents: number; id: string }[];
};

export type Product = {
  permalink: string;
  rental: Rental | null;
  options: Option[];
  currency_code: CurrencyCode;
  price_cents: number;
  installment_plan: { number_of_installments: number } | null;
  is_tiered_membership: boolean;
  is_legacy_subscription: boolean;
  is_quantity_enabled: boolean;
  is_multiseat_license: boolean;
  quantity_remaining: number | null;
  recurrences: Recurrences | null;
  pwyw: { suggested_price_cents: number | null } | null;
  ppp_details: PurchasingPowerParityDetails | null;
  native_type: ProductNativeType;
  hide_sold_out_variants?: boolean;
};

export const getMaxQuantity = (product: Product, option: Option | null) =>
  option?.quantity_left != null && product.quantity_remaining !== null
    ? Math.min(option.quantity_left, product.quantity_remaining)
    : (option?.quantity_left ?? product.quantity_remaining);

export const hasMetDiscountConditions = (discount: Discount | null, quantity: number) =>
  quantity >= (discount?.minimum_quantity ?? 0);

export const computeDiscountedPrice = (
  priceCents: number,
  discount: Discount | null,
  product: Product,
): { value: number; ppp: boolean } => {
  const discountedPrice = { value: discount ? applyOfferCodeToCents(discount, priceCents) : priceCents, ppp: false };
  if (product.ppp_details && priceCents !== 0) {
    const pppDiscountedPrice = Math.max(
      Math.round(product.ppp_details.factor * priceCents),
      product.ppp_details.minimum_price,
    );
    if (pppDiscountedPrice < discountedPrice.value) return { value: pppDiscountedPrice, ppp: true };
  }
  return discountedPrice;
};

export const applySelection = (product: Product, discount: Discount | null, selection: PriceSelection) => {
  const basePriceCents = !product.is_legacy_subscription
    ? selection.rent && product.rental
      ? product.rental.price_cents
      : product.price_cents
    : (product.recurrences?.enabled.find(({ recurrence }) => recurrence === selection.recurrence)?.price_cents ?? 0);
  const selectedOption = product.options.find(({ id }) => id === selection.optionId) ?? null;
  const maxQuantity = getMaxQuantity(product, selectedOption);
  const priceCents = basePriceCents + (selectedOption ? computeOptionPrice(selectedOption, selection.recurrence) : 0);
  const discountedPrice = computeDiscountedPrice(
    priceCents,
    hasMetDiscountConditions(discount, selection.quantity) ? discount : null,
    product,
  );
  return {
    selectedOption,
    basePriceCents,
    priceCents,
    discountedPriceCents: discountedPrice.value,
    pppDiscounted: discountedPrice.ppp,
    isPWYW: product.is_tiered_membership ? (selectedOption?.is_pwyw ?? false) : !!product.pwyw,
    maxQuantity,
    hasOptions: product.options.length > 0,
    hasRentOption: product.rental && !product.rental.rent_only,
    hasMultipleRecurrences: product.recurrences && product.recurrences.enabled.length > 1,
    hasConfigurableQuantity:
      product.is_multiseat_license || (product.is_quantity_enabled && (maxQuantity === null || maxQuantity > 1)),
  };
};

export const computeOptionPrice = (option: Option, selectedRecurrence: RecurrenceId | null) =>
  (selectedRecurrence !== null ? (option.recurrence_price_values?.[selectedRecurrence]?.price_cents ?? 0) : 0) +
  (option.price_difference_cents ?? 0);

export const OptionRadioButton = ({
  disabled,
  selected,
  onClick,
  priceCents,
  name,
  description,
  quantityLeft,
  currencyCode,
  isPWYW,
  status,
  discount,
  recurrence,
  product,
  hidePrice,
}: {
  disabled?: boolean;
  selected: boolean;
  onClick?: () => void;
  priceCents: number | null;
  name: string;
  description: string;
  quantityLeft?: number | null;
  currencyCode: CurrencyCode;
  isPWYW: boolean;
  status?: string | undefined;
  discount: Discount | null;
  recurrence?: RecurrenceId | null;
  product: Product;
  hidePrice?: boolean | undefined;
}) => {
  priceCents ??= 0;
  const { value: discountedPriceCents } = computeDiscountedPrice(priceCents, discount, product);
  return (
    <Button
      role="radio"
      aria-checked={selected}
      disabled={disabled}
      aria-label={name}
      onClick={onClick}
      itemProp="offer"
      itemType="https://schema.org/Offer"
      itemScope
      style={recurrence ? { flexDirection: "column" } : undefined}
    >
      {status ? (
        <div role="status" className="info">
          {status}
        </div>
      ) : null}
      {hidePrice ? null : (
        <div className="pill">
          {discountedPriceCents < priceCents ? (
            <>
              <s>{formatPriceCentsWithCurrencySymbol(currencyCode, priceCents, { symbolFormat: "long" })}</s>{" "}
            </>
          ) : null}
          {formatPriceCentsWithCurrencySymbol(currencyCode, discountedPriceCents, {
            symbolFormat: "long",
          })}
          {isPWYW ? "+" : null}
          {recurrence ? ` ${recurrenceLabels[recurrence]}` : null}
          <div itemProp="price" hidden>
            {formatPriceCentsWithoutCurrencySymbolAndComma(currencyCode, discountedPriceCents)}
          </div>
          <div itemProp="priceCurrency" hidden>
            {currencyCode}
          </div>
        </div>
      )}
      <div>
        <h4>{name}</h4>
        {quantityLeft != null ? <small>{`${quantityLeft} left`}</small> : null}
        {description ? (
          <div>
            <Breaklines text={description} />
          </div>
        ) : null}
      </div>
    </Button>
  );
};

const getClientTimeZone = () => ({
  shortFormattedName: new Intl.DateTimeFormat("en-US", { timeZoneName: "short" }).format(new Date()).split(", ")[1],
  longFormattedName: new Intl.DateTimeFormat("en-US", { timeZoneName: "long" }).format(new Date()).split(", ")[1],
});

const roundToNearestDisplayTime = (time: Date) =>
  roundToNearestMinutes(time, { nearestTo: 30, roundingMethod: "ceil" });

const CallDateAndTimeSelector = ({
  product,
  selectedOption,
  selectedStartTime: rawSelectedStartTime,
  onChange,
}: {
  product: Product;
  selectedOption: Option;
  selectedStartTime: string | null;
  onChange: ({ callStartTime }: { callStartTime: Date | null }) => void;
}) => {
  const [isLoading, setIsLoading] = React.useState(true);
  const [availabilities, setAvailabilities] = React.useState<CallAvailability[]>([]);

  const clientTimeZone = getClientTimeZone();
  const callDurationInMinutes = selectedOption.duration_in_minutes ?? 0;
  const selectedStartTime = rawSelectedStartTime ? new Date(rawSelectedStartTime) : undefined;
  const lastAvailability = availabilities.length > 0 ? availabilities[availabilities.length - 1] : null;

  useRunOnce(() => void loadAvailabilities());
  React.useEffect(() => {
    if (isLoading) return;
    if (selectedStartTime && isStartTimeAvailable(selectedStartTime)) return;
    onChange({ callStartTime: firstAvailableStartTime });
  }, [selectedOption, availabilities]);

  const loadAvailabilities = async () => {
    setIsLoading(true);
    const availabilities = await getRemainingCallAvailabilities(product.permalink);
    setAvailabilities(availabilities);
    setIsLoading(false);
  };

  const availabilitiesByDate = React.useMemo(
    () =>
      availabilities.reduce<Record<string, typeof availabilities>>((byDate, availability) => {
        eachDayOfInterval(interval(availability.start_time, availability.end_time)).forEach((date) => {
          (byDate[date.toDateString()] ??= []).push(availability);
        });
        return byDate;
      }, {}),
    [availabilities],
  );

  const getAvailableStartTimesByDate = (date: Date) => {
    const dayStart = startOfDay(date);
    const dayEnd = endOfDay(date);

    const availabilities = availabilitiesByDate[date.toDateString()] ?? [];
    const startTimes: Date[] = [];

    for (const availability of availabilities) {
      const earliestStartTime = max([availability.start_time, dayStart]);
      const roundedEarliestStartTime = roundToNearestDisplayTime(earliestStartTime);
      const latestStartTime = min([subMinutes(availability.end_time, callDurationInMinutes), dayEnd]);

      if (earliestStartTime > latestStartTime) {
        continue;
      }
      if (roundedEarliestStartTime > latestStartTime) {
        startTimes.push(earliestStartTime);
      } else {
        startTimes.push(...eachMinuteOfInterval(interval(roundedEarliestStartTime, latestStartTime), { step: 30 }));
      }
    }

    return startTimes;
  };

  const firstAvailableStartTime = React.useMemo(() => {
    const ascendingAvailableDates = Object.keys(availabilitiesByDate)
      .map((date) => new Date(date))
      .sort(compareAsc);
    for (const availableDate of ascendingAvailableDates) {
      const times = getAvailableStartTimesByDate(availableDate);
      if (times[0]) {
        return times[0];
      }
    }
    return null;
  }, [callDurationInMinutes, availabilities]);

  const dateAvailabilityCache = React.useMemo<Record<string, Record<number, boolean>>>(() => ({}), [availabilities]);
  const isAvailableOnDate = (date: Date) => {
    const dateString = date.toDateString();
    const cached = dateAvailabilityCache[dateString]?.[callDurationInMinutes];
    if (cached) return cached;

    const dayStart = startOfDay(date);
    const isAvailable =
      availabilitiesByDate[dateString]?.some((availability) => {
        const availabilityStart = max([availability.start_time, dayStart]);
        return differenceInMinutes(availability.end_time, availabilityStart) >= callDurationInMinutes;
      }) ?? false;

    return ((dateAvailabilityCache[dateString] ??= {})[callDurationInMinutes] = isAvailable);
  };

  const isStartTimeAvailable = (startTime: Date) => {
    const endTime = addMinutes(startTime, callDurationInMinutes);
    return availabilitiesByDate[startTime.toDateString()]?.find(
      (availability) => availability.start_time <= startTime && endTime <= availability.end_time,
    );
  };

  const setSelectedDateFromReactCalendar = (date: Date) =>
    onChange({ callStartTime: getAvailableStartTimesByDate(date)[0] ?? null });

  if (firstAvailableStartTime === null && !isLoading) {
    return (
      <div role="status" className="warning">
        {product.options.length > 1 ? "There are no available times for this option." : "There are no available times."}
      </div>
    );
  }

  return (
    <>
      <section>
        <h4
          style={{
            marginBottom: "var(--spacer-2)",
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
          }}
        >
          <span>Select a date</span>
          {isLoading ? <LoadingSpinner /> : null}
        </h4>
        <Calendar
          locale={{ code: "en-US" }}
          mode="single"
          selected={selectedStartTime}
          startMonth={firstAvailableStartTime ?? new Date()}
          endMonth={lastAvailability ? new Date(lastAvailability.end_time) : new Date()}
          disabled={(date) => !isAvailableOnDate(date)}
          onSelect={(date) => {
            if (date) setSelectedDateFromReactCalendar(date);
          }}
        />
      </section>
      {selectedStartTime ? (
        <section>
          <h4
            style={{
              display: "flex",
              alignItems: "center",
              justifyContent: "space-between",
              marginBottom: "var(--spacer-2)",
            }}
          >
            <span>Select a time</span>
            <span title={clientTimeZone.longFormattedName} suppressHydrationWarning>
              {clientTimeZone.shortFormattedName}
            </span>
          </h4>
          <div role="radiogroup" className="radio-buttons" style={{ gridTemplateColumns: "repeat(2, 1fr)" }}>
            {getAvailableStartTimesByDate(selectedStartTime).map((time) => (
              <Button
                role="radio"
                key={time.toISOString()}
                aria-checked={isEqual(selectedStartTime, time)}
                onClick={() => onChange({ callStartTime: time })}
                style={{ justifyContent: "center" }}
              >
                <div>{formatCallDate(time, { date: { hidden: true }, timeZone: { hidden: true } })}</div>
              </Button>
            ))}
          </div>
        </section>
      ) : null}
      {selectedStartTime ? (
        <div>
          <h4>
            You selected{" "}
            <strong>
              {formatCallDate(selectedStartTime, { date: { hideYear: true }, timeZone: { hidden: true } })}
            </strong>
          </h4>
        </div>
      ) : null}
    </>
  );
};

const PaymentOptionSelector = ({
  product,
  selection,
  onChange,
}: {
  product: Product;
  selection: PriceSelection;
  onChange: (selection: Partial<PriceSelection>) => void;
}) => {
  if (!product.installment_plan) return null;

  const fullPriceCents = selection.price.value ?? product.price_cents;

  return (
    <section>
      <h4 className="mb-2">Payment option</h4>
      <div role="radiogroup" className="radio-buttons">
        <Button
          role="radio"
          aria-checked={!selection.payInInstallments}
          onClick={() => onChange({ payInInstallments: false })}
        >
          <div>
            <strong>Pay in full</strong>
            <p>One-time payment</p>
          </div>
        </Button>

        <Button
          role="radio"
          aria-checked={selection.payInInstallments}
          onClick={() => onChange({ payInInstallments: true })}
        >
          <div>
            <strong>Pay in {product.installment_plan.number_of_installments} installments</strong>
            <p>
              {formatInstallmentPaymentSchedule(
                fullPriceCents,
                product.currency_code,
                product.installment_plan.number_of_installments,
              )}
            </p>
          </div>
        </Button>
      </div>
    </section>
  );
};

export type ConfigurationSelectorHandle = {
  focusRequiredInput: () => void;
};

export const ConfigurationSelector = React.forwardRef<
  ConfigurationSelectorHandle,
  {
    product: Product;
    selection: PriceSelection;
    setSelection?: React.Dispatch<React.SetStateAction<PriceSelection>> | undefined;
    discount: Discount | null;
    hidePrices?: boolean;
    initialSelection?: PriceSelection;
    showInstallmentPlan?: boolean;
  }
>(({ product, selection, setSelection, discount, hidePrices, initialSelection, showInstallmentPlan = false }, ref) => {
  const update = (update: Partial<PriceSelection> | ((selection: PriceSelection) => Partial<PriceSelection>)) =>
    setSelection?.((prevSelection) => ({
      ...prevSelection,
      ...(typeof update === "function" ? update(prevSelection) : update),
    }));

  const selectedOption = product.options.find(({ id }) => id === selection.optionId) ?? null;
  const {
    basePriceCents,
    discountedPriceCents,
    isPWYW,
    maxQuantity,
    hasOptions,
    hasRentOption,
    hasMultipleRecurrences,
    hasConfigurableQuantity,
  } = applySelection(product, discount, selection);
  const suggestedPriceCents = Math.max(
    (selectedOption && selection.recurrence
      ? selectedOption.recurrence_price_values?.[selection.recurrence]?.suggested_price_cents
      : product.pwyw?.suggested_price_cents) ?? 0,
    discountedPriceCents,
  );
  const usePreexistingPrice =
    initialSelection &&
    selection.recurrence === initialSelection.recurrence &&
    selection.optionId === initialSelection.optionId &&
    selection.quantity === initialSelection.quantity;

  const quantityInputUID = React.useId();

  const pwywInputRef = React.useRef<HTMLInputElement>(null);
  React.useImperativeHandle(ref, () => ({
    focusRequiredInput: () => pwywInputRef.current?.focus(),
  }));
  const pwywInput = (
    <PWYWInput
      currencyCode={product.currency_code}
      cents={usePreexistingPrice ? initialSelection.price.value : selection.price.value}
      onChange={(newPriceCents) => update({ price: { value: newPriceCents, error: false } })}
      onBlur={() => update(({ price }) => ({ price: { ...price, error: (price.value ?? 0) < discountedPriceCents } }))}
      suggestedPriceCents={suggestedPriceCents}
      hasError={selection.price.error}
      hideLabel={product.native_type === "coffee"}
      ref={pwywInputRef}
    />
  );

  if (product.native_type === "coffee") {
    if (product.options.length === 1) return pwywInput;
    return (
      <>
        <div
          role="radiogroup"
          className="radio-buttons"
          style={{ gridTemplateColumns: "repeat(auto-fit, minmax(min(6rem, 100%), 1fr))" }}
        >
          {product.options.map((option) => (
            <Button
              role="radio"
              style={{ justifyContent: "center" }}
              aria-checked={selection.optionId === option.id}
              onClick={() =>
                setSelection?.({
                  ...selection,
                  optionId: option.id,
                  price: { value: option.price_difference_cents ?? 100, error: false },
                })
              }
              key={option.id}
            >
              {formatPriceCentsWithCurrencySymbol(product.currency_code, option.price_difference_cents ?? 0, {
                symbolFormat: "short",
              })}
            </Button>
          ))}
          <Button
            role="radio"
            style={{ justifyContent: "center" }}
            aria-checked={selection.optionId === null}
            onClick={() => setSelection?.({ ...selection, optionId: null, price: { value: null, error: false } })}
          >
            Other
          </Button>
        </div>
        {selection.optionId === null ? pwywInput : null}
      </>
    );
  }

  return (
    <>
      {hasMultipleRecurrences && product.recurrences ? (
        <TypeSafeOptionSelect
          aria-label="Recurrence"
          value={selection.recurrence ?? ""}
          onChange={(recurrence) => update({ recurrence: recurrence || null, price: { value: null, error: false } })}
          options={product.recurrences.enabled.map(({ recurrence }) => ({
            id: recurrence,
            label: recurrenceNames[recurrence],
          }))}
        />
      ) : null}
      {hasRentOption && product.rental ? (
        <div
          className="radio-buttons"
          role="radiogroup"
          itemProp="offers"
          itemType="https://schema.org/AggregateOffer"
          itemScope
        >
          <OptionRadioButton
            selected={selection.rent}
            onClick={() => update({ rent: true })}
            priceCents={hasOptions ? null : product.rental.price_cents}
            name="Rent"
            description="Your rental will be available for 30 days. Once started, you’ll have 72 hours to watch it as much as you’d like!"
            currencyCode={product.currency_code}
            isPWYW={!!product.pwyw}
            discount={discount}
            product={product}
            hidePrice={hidePrices}
          />
          <OptionRadioButton
            selected={!selection.rent}
            onClick={() => update({ rent: false })}
            priceCents={hasOptions ? null : product.price_cents}
            name="Buy"
            description="Watch as many times as you want, forever."
            currencyCode={product.currency_code}
            isPWYW={!!product.pwyw}
            discount={discount}
            product={product}
            hidePrice={hidePrices}
          />
        </div>
      ) : null}
      {hasOptions && hasRentOption ? <hr /> : null}
      {hasOptions ? (
        <div
          className="radio-buttons"
          role="radiogroup"
          itemProp="offers"
          itemType="https://schema.org/AggregateOffer"
          itemScope
        >
          {product.options
            .filter((option) => !(product.hide_sold_out_variants && option.quantity_left === 0))
            .map((option) => (
              <OptionRadioButton
                key={option.id}
                disabled={
                  option.quantity_left === 0 ||
                  (product.is_tiered_membership &&
                    !!selection.recurrence &&
                    !option.recurrence_price_values?.[selection.recurrence])
                }
                selected={option.id === selection.optionId}
                onClick={() => update({ optionId: option.id, price: { value: null, error: false } })}
                priceCents={basePriceCents + computeOptionPrice(option, selection.recurrence)}
                name={option.name}
                description={option.description}
                quantityLeft={option.quantity_left}
                currencyCode={product.currency_code}
                isPWYW={product.is_tiered_membership ? option.is_pwyw : !!product.pwyw}
                status={option.status}
                discount={discount}
                recurrence={selection.recurrence}
                product={product}
                hidePrice={hidePrices}
              />
            ))}
          <div itemProp="offerCount" hidden>
            {product.options.length}
          </div>
          <div itemProp="lowPrice" hidden>
            {formatPriceCentsWithoutCurrencySymbol(
              product.currency_code,
              Math.min(
                ...product.options.map((option) => basePriceCents + computeOptionPrice(option, selection.recurrence)),
              ),
            )}
          </div>
          <div itemProp="priceCurrency" hidden>
            {product.currency_code}
          </div>
        </div>
      ) : null}
      {isPWYW ? pwywInput : null}
      {product.native_type === "call" && selectedOption ? (
        <CallDateAndTimeSelector
          product={product}
          selectedOption={selectedOption}
          selectedStartTime={selection.callStartTime}
          onChange={({ callStartTime }) =>
            update({ callStartTime: callStartTime ? callStartTime.toISOString() : null })
          }
        />
      ) : null}
      {hasConfigurableQuantity ? (
        <fieldset>
          <legend>
            <label htmlFor={quantityInputUID}>{product.is_multiseat_license ? "Seats" : "Quantity"}</label>
          </legend>
          <NumberInput onChange={(quantity) => update({ quantity: quantity ?? 0 })} value={selection.quantity}>
            {(props) => <input type="number" id={quantityInputUID} {...props} min={1} max={maxQuantity ?? undefined} />}
          </NumberInput>
        </fieldset>
      ) : null}
      {showInstallmentPlan && product.installment_plan ? (
        <PaymentOptionSelector product={product} selection={selection} onChange={update} />
      ) : null}
    </>
  );
});
ConfigurationSelector.displayName = "ConfigurationSelector";
