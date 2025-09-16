import cx from "classnames";
import hands from "images/illustrations/hands.png";
import * as React from "react";
import { useState } from "react";
import { cast, createCast, is } from "ts-safe-cast";

import { CreateProductData, RecurringProductType, createProduct } from "$app/data/products";
import { ProductNativeType, ProductServiceType } from "$app/parsers/product";
import { CurrencyCode, currencyCodeList, findCurrencyByCode } from "$app/utils/currency";
import {
  RecurrenceId,
  durationInMonthsToRecurrenceId,
  recurrenceLabels,
  recurrenceIds,
} from "$app/utils/recurringPricing";
import { assertResponseError, request } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button, NavigationButton } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { PageHeader } from "$app/components/ui/PageHeader";
import { WithTooltip } from "$app/components/WithTooltip";

const nativeTypeIcons = require.context("$assets/images/native_types/");

const defaultRecurrence: RecurrenceId = "monthly";

const MIN_AI_PROMPT_LENGTH = 10;

const NewProductPage = ({
  current_seller_currency_code,
  native_product_types,
  service_product_types,
  release_at_date,
  show_orientation_text,
  eligible_for_service_products,
  ai_generation_enabled,
  ai_promo_dismissed,
}: {
  current_seller_currency_code: CurrencyCode;
  native_product_types: ProductNativeType[];
  service_product_types: ProductServiceType[];
  release_at_date: string;
  show_orientation_text: boolean;
  eligible_for_service_products: boolean;
  ai_generation_enabled: boolean;
  ai_promo_dismissed: boolean;
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

  const [aiPromoVisible, setAiPromoVisible] = useState(ai_generation_enabled && !ai_promo_dismissed);
  const [aiPopoverOpen, setAiPopoverOpen] = useState(false);
  const [aiPrompt, setAiPrompt] = useState("");
  const [isGeneratingUsingAi, setIsGeneratingUsingAi] = useState(false);
  const [description, setDescription] = useState<string | null>(null);
  const [summary, setSummary] = useState<string | null>(null);
  const [numberOfContentPages, setNumberOfContentPages] = useState<number | null>(null);

  const isRecurringBilling = is<RecurringProductType>(productType);

  const selectedCurrency = findCurrencyByCode(currencyCode);

  const dismissAiPromo = async () => {
    try {
      await request({
        method: "POST",
        url: Routes.settings_dismiss_ai_product_generation_promo_path(),
        accept: "json",
      });
      setAiPromoVisible(false);
    } catch (e) {
      assertResponseError(e);
      showAlert("Failed to dismiss promo", "error");
    }
  };

  const generateWithAi = async () => {
    if (aiPrompt.trim().length < MIN_AI_PROMPT_LENGTH) {
      showAlert(
        `Please enter a detailed prompt for your product idea with a price in mind (minimum ${MIN_AI_PROMPT_LENGTH} characters)`,
        "error",
      );
      return;
    }

    setIsGeneratingUsingAi(true);
    try {
      const response = await request({
        method: "POST",
        url: Routes.internal_ai_product_details_generations_path(),
        accept: "json",
        data: { prompt: aiPrompt.trim() },
      });

      const result = cast<
        | {
            success: true;
            data: {
              name: string;
              description: string;
              summary: string;
              price: number;
              currency_code: string;
              price_frequency_in_months: number | null;
              native_type: ProductNativeType;
              number_of_content_pages: number | null;
            };
          }
        | {
            success: false;
            error: string;
          }
      >(await response.json());

      if (result.success) {
        const data = result.data;

        setName(data.name);
        setDescription(data.description);
        setSummary(data.summary);
        setProductType(data.native_type);
        setNumberOfContentPages(data.number_of_content_pages);
        setPrice(data.price.toString());
        if (is<CurrencyCode>(data.currency_code)) {
          setCurrencyCode(data.currency_code);
        }
        if (data.native_type === "membership" && data.price_frequency_in_months) {
          const recurrenceId = durationInMonthsToRecurrenceId[data.price_frequency_in_months];
          setSubscriptionDuration(recurrenceId || defaultRecurrence);
        }

        setAiPopoverOpen(false);
        setAiPromoVisible(false);

        showAlert("All set! Review the form below and hit 'Next: customize' to continue.", "success");
      } else {
        showAlert(result.error, "error");
      }
    } catch (e) {
      assertResponseError(e);
      showAlert("Failed to generate product details", "error");
    } finally {
      setIsGeneratingUsingAi(false);
    }
  };

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
          description,
          summary,
          native_type: productType,
          price_currency_type: currencyCode,
          price_range: price,
          release_at_date,
          release_at_time: "12PM",
          subscription_duration: isRecurringBilling ? subscriptionDuration || defaultRecurrence : null,
          number_of_content_pages: numberOfContentPages,
          ai_prompt: aiPrompt.trim(),
        }),
      };

      const responseData = await createProduct(requestData);

      if (responseData.success) {
        let redirectTo = responseData.redirect_to;
        if (aiPrompt.trim().length > 0) {
          redirectTo = `${redirectTo}#ai-generated`;
        }

        window.location.href = redirectTo;
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
      <PageHeader
        className="sticky-top"
        title={show_orientation_text ? "Publish your first product" : "What are you creating?"}
        actions={
          <>
            <NavigationButton href={Routes.products_path()}>
              <Icon name="x-square" />
              <span>Cancel</span>
            </NavigationButton>
            {ai_generation_enabled ? (
              <Popover
                open={aiPopoverOpen}
                onToggle={setAiPopoverOpen}
                trigger={
                  <Button color="primary" outline aria-label="Create a product with AI">
                    <Icon name="sparkle" />
                  </Button>
                }
              >
                <div className="w-96 max-w-full">
                  <fieldset>
                    <legend>
                      <label htmlFor={`ai-prompt-${formUID}`}>Create a product with AI</label>
                    </legend>
                    <p>
                      Got an idea? Give clear instructions, and let AI create your product—quick and easy! Customize it
                      to make it yours.
                    </p>
                    <textarea
                      id={`ai-prompt-${formUID}`}
                      placeholder="e.g., a 'Coding with AI using Cursor for Designers' ebook with 5 chapters for $35'."
                      value={aiPrompt}
                      onChange={(e) => setAiPrompt(e.target.value)}
                      rows={4}
                      maxLength={500}
                      className="w-full resize-y"
                      autoFocus
                    />
                  </fieldset>
                  <div className="mt-3 flex justify-end gap-2">
                    <Button onClick={() => setAiPopoverOpen(false)} disabled={isGeneratingUsingAi}>
                      Cancel
                    </Button>
                    <Button
                      color="primary"
                      onClick={() => void generateWithAi()}
                      disabled={isGeneratingUsingAi || !aiPrompt.trim()}
                    >
                      {isGeneratingUsingAi ? "Generating..." : "Generate"}
                    </Button>
                  </div>
                </div>
              </Popover>
            ) : null}
            <Button color="accent" type="submit" form={`new-product-form-${formUID}`} disabled={isSubmitting}>
              {isSubmitting ? "Adding..." : "Next: Customize"}
            </Button>
          </>
        }
      />
      <div>
        <div>
          <form id={`new-product-form-${formUID}`} className="row" onSubmit={(e) => void submit(e)}>
            <section className="!p-4 md:!p-8">
              <header>
                <p>
                  Turn your idea into a live product in minutes. No fuss, just a few quick selections and you're ready
                  to start selling. Whether it's digital downloads, online courses, or memberships — see what sticks.
                  <br />
                  <br />
                  <a href="/help/article/64-is-gumroad-for-me" target="_blank" rel="noreferrer">
                    Need help adding a product?
                  </a>
                </p>
              </header>

              {ai_generation_enabled && aiPromoVisible ? (
                <div
                  role="status"
                  className="grid grid-cols-[auto_1fr_auto] items-start gap-4 rounded-lg !border-pink bg-pink/20 p-6"
                >
                  <img src={hands} alt="Hands" className="h-12 w-12 self-center" />
                  <div>
                    <strong>New.</strong> You can create your product using AI now. Click the sparks button in the
                    header to get started.
                    <br />
                    <a href="/help/article/149-adding-a-product" target="_blank" rel="noreferrer">
                      Learn more
                    </a>
                  </div>
                  <button className="link !col-start-3 self-center" onClick={() => void dismissAiPromo()}>
                    close
                  </button>
                </div>
              ) : null}

              <fieldset className={cx({ danger: errors.has("name") })}>
                <legend>
                  <label htmlFor={`name-${formUID}`}>Name</label>
                </legend>

                <input
                  ref={nameInputRef}
                  id={`name-${formUID}`}
                  type="text"
                  placeholder="Name of product"
                  value={name}
                  onChange={(e) => {
                    setName(e.target.value);
                    errors.delete("name");
                  }}
                  aria-invalid={errors.has("name")}
                />
              </fieldset>

              <fieldset>
                <legend>Products</legend>
                <ProductTypeSelector
                  selectedType={productType}
                  types={native_product_types}
                  onChange={setProductType}
                />
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
      </div>
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
  <div className="radio-buttons !grid-cols-1 sm:!grid-cols-2 md:!grid-cols-3 2xl:!grid-cols-5" role="radiogroup">
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
