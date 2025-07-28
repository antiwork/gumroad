import cx from "classnames";
import * as React from "react";
import { useState } from "react";
import { cast, createCast, is } from "ts-safe-cast";

import { CreateProductData, RecurringProductType, createProduct } from "$app/data/products";
import { ProductNativeType, ProductServiceType } from "$app/parsers/product";
import { CurrencyCode, currencyCodeList, findCurrencyByCode } from "$app/utils/currency";
import { RecurrenceId, recurrenceLabels, recurrenceIds } from "$app/utils/recurringPricing";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button, NavigationButton } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { showAlert } from "$app/components/server-components/Alert";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { WithTooltip } from "$app/components/WithTooltip";

const nativeTypeIcons = require.context("$assets/images/native_types/");

const defaultRecurrence: RecurrenceId = "monthly";

const NewProductPage = ({
  current_seller_currency_code,
  native_product_types,
  service_product_types,
  release_at_date,
  show_orientation_text,
  eligible_for_service_products,
}: {
  current_seller_currency_code: CurrencyCode;
  native_product_types: ProductNativeType[];
  service_product_types: ProductServiceType[];
  release_at_date: string;
  show_orientation_text: boolean;
  eligible_for_service_products: boolean;
}) => {
  const formUID = React.useId();

  const nameInputRef = React.useRef<HTMLInputElement>(null);
  const priceInputRef = React.useRef<HTMLInputElement>(null);

  const [errors, setErrors] = useState<Set<string>>(new Set());
  const [name, setName] = useState("");
  const [price, setPrice] = useState("");
  const [isSubmitting, setIsSubmitting] = React.useState(false);
  const [currencyCode, setCurrencyCode] = useState<CurrencyCode>(current_seller_currency_code);
  const [productType, setProductType] = useState<ProductNativeType>("digital");
  const [subscriptionDuration, setSubscriptionDuration] = useState<RecurrenceId | null>(null);

  const isRecurringBilling = is<RecurringProductType>(productType);

  const selectedCurrency = findCurrencyByCode(currencyCode);

  const submit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const errors = new Set<string>();

    if (name.trim() === "") {
      errors.add("name");
      nameInputRef.current?.focus();
    } else if (price.trim() === "") {
      errors.add("price");
      priceInputRef.current?.focus();
    }

    setErrors(errors);
    if (errors.size > 0) return false;

    setIsSubmitting(true);

    try {
      const requestData = {
        link: cast<CreateProductData>({
          is_physical: productType === "physical",
          is_recurring_billing: isRecurringBilling,
          name,
          native_type: productType,
          price_currency_type: currencyCode,
          price_range: price,
          release_at_date,
          release_at_time: "12PM",
          subscription_duration: isRecurringBilling ? subscriptionDuration || defaultRecurrence : null,
        }),
      };

      const responseData = await createProduct(requestData);

      if (responseData.success) {
        window.location.href = responseData.redirect_to;
      } else {
        showAlert(responseData.error_message, "error");
        setIsSubmitting(false);
      }
    } catch (e) {
      assertResponseError(e);
      showAlert("Something went wrong.", "error");
      setIsSubmitting(false);
    }
  };

  return (
    <>
      <header className="sticky-top">
        <h1>{show_orientation_text ? "Publish your first product" : "What are you creating?"}</h1>
        <div className="actions">
          <NavigationButton href={Routes.products_path()}>
            <Icon name="x-square" />
            <span>Cancel</span>
          </NavigationButton>
          <Button color="accent" type="submit" form={`new-product-form-${formUID}`} disabled={isSubmitting}>
            {isSubmitting ? "Adding..." : "Next: Customize"}
          </Button>
        </div>
      </header>
      <main>
        <div>
        <form id={`new-product-form-${formUID}`} className="row" onSubmit={(e) => void submit(e)}>
          <section>
            <header>
              <p>
                Turn your idea into a live product in minutes. No fuss, just a few quick selections and you're ready to
                start selling. Whether it's digital downloads, online courses, or memberships — see what sticks.
                <br />
                <br />
                <a data-helper-prompt="What kind of products can I sell on Gumroad?">Need help adding a product?</a>
              </p>
            </header>

            <fieldset className={cx({ danger: errors.has("name") })}>
              <legend>
                <label htmlFor={`name-${formUID}`}>Name</label>
              </legend>

              <input
                ref={nameInputRef}
                id={`name-${formUID}`}
                type="text"
                placeholder="Name of product"
                onChange={(e) => {
                  setName(e.target.value);
                  errors.delete("name");
                }}
                aria-invalid={errors.has("name")}
              />
            </fieldset>

            <fieldset>
              <legend>Products</legend>
              <ProductTypeSelector selectedType={productType} types={native_product_types} onChange={setProductType} />
            </fieldset>
            {service_product_types.length > 0 ? (
              <fieldset>
                <legend>Services</legend>
                <ProductTypeSelector
                  selectedType={productType}
                  types={service_product_types}
                  onChange={setProductType}
                  disabled={!eligible_for_service_products}
                />
              </fieldset>
            ) : null}

            <fieldset className={cx({ danger: errors.has("price") })}>
              <legend>
                <label htmlFor={`price-${formUID}`}>{productType === "coffee" ? "Suggested amount" : "Price"}</label>
              </legend>

              <div className="input">
                <label className="pill select">
                  <span>{selectedCurrency.longSymbol}</span>
                  <TypeSafeOptionSelect
                    onChange={(newCurrencyCode) => {
                      setCurrencyCode(newCurrencyCode);
                    }}
                    value={currencyCode}
                    aria-label="Currency"
                    options={currencyCodeList.map((code) => {
                      const { displayFormat } = findCurrencyByCode(code);
                      return {
                        id: code,
                        label: displayFormat,
                      };
                    })}
                  />
                </label>

                <input
                  ref={priceInputRef}
                  id={`price-${formUID}`}
                  type="text"
                  maxLength={10}
                  placeholder="Price your product"
                  value={price}
                  onChange={(e) => {
                    setPrice(e.target.value);
                    errors.delete("price");
                  }}
                  autoComplete="off"
                  aria-invalid={errors.has("price")}
                />

                {isRecurringBilling ? (
                  <label className="pill select" style={{ border: "unset" }}>
                    <span>{recurrenceLabels[subscriptionDuration || defaultRecurrence]}</span>
                    <TypeSafeOptionSelect
                      onChange={(newSubscriptionDuration) => {
                        setSubscriptionDuration(newSubscriptionDuration);
                      }}
                      value={subscriptionDuration || defaultRecurrence}
                      aria-label="Default subscription duration"
                      options={recurrenceIds.map((recurrence) => ({
                        id: recurrence,
                        label: recurrenceLabels[recurrence],
                      }))}
                    />
                  </label>
                ) : null}
              </div>
            </fieldset>
          </section>
        </form>
      </div>
      </main>
    </>
  );
};

const PRODUCT_TYPES = {
  audiobook: {
    description: "Let customers listen to your audio content.",
    title: "Audiobook",
  },
  bundle: {
    description: "Sell two or more existing products for a new price",
    title: "Bundle",
  },
  call: {
    description: "Offer scheduled calls with your customers.",
    title: "Call",
  },
  coffee: {
    description: "Boost your support and accept tips from customers.",
    title: "Coffee",
  },
  commission: {
    description: "Sell custom services with 50% deposit upfront, 50% upon completion.",
    title: "Commission",
  },
  course: {
    description: "Sell a single lesson or teach a whole cohort of students.",
    title: "Course or tutorial",
  },
  digital: {
    description: "Any set of files to download or stream.",
    title: "Digital product",
  },
  ebook: {
    description: "Offer a book or comic in PDF, ePub, and Mobi formats.",
    title: "E-book",
  },
  membership: {
    description: "Start a membership business around your fans.",
    title: "Membership",
  },
  newsletter: {
    description: "Deliver recurring content through email.",
    title: "Newsletter",
  },
  physical: {
    description: "Sell anything that requires shipping something.",
    title: "Physical good",
  },
  podcast: {
    description: "Make episodes available for streaming and direct downloads.",
    title: "Podcast",
  },
};

const ProductTypeSelector = ({
  selectedType,
  types,
  onChange,
  disabled,
}: {
  selectedType: ProductNativeType;
  types: ProductNativeType[];
  onChange: (type: ProductNativeType) => void;
  disabled?: boolean;
}) => (
  <div
    className="radio-buttons"
    role="radiogroup"
    style={{ gridTemplateColumns: "repeat(auto-fit, minmax(13rem, 1fr)" }}
  >
    {types.map((type) => {
      const typeButton = (
        <Button
          key={type}
          className="vertical"
          role="radio"
          aria-checked={type === selectedType}
          data-type={type}
          onClick={() => onChange(type)}
          disabled={disabled}
        >
          <img
            src={cast<string>(nativeTypeIcons(`./${type}.png`))}
            alt={PRODUCT_TYPES[type].title}
            width="40"
            height="40"
          />
          <div>
            <h4>{PRODUCT_TYPES[type].title}</h4>
            {PRODUCT_TYPES[type].description}
          </div>
        </Button>
      );
      return disabled ? (
        <WithTooltip tip="Service products are disabled until your account is 30 days old." key={type}>
          {typeButton}
        </WithTooltip>
      ) : (
        typeButton
      );
    })}
    {types.length < 2 ? <div /> : null}
    {types.length < 3 ? <div /> : null}
  </div>
);

export default register({ component: NewProductPage, propParser: createCast() });
