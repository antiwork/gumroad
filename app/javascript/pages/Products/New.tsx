import { Link, useForm, usePage } from "@inertiajs/react";
import cx from "classnames";
import hands from "images/illustrations/hands.png";
import * as React from "react";
import { useState } from "react";
import { cast, is } from "ts-safe-cast";

import { RecurringProductType } from "$app/data/products";
import { ProductNativeType, ProductServiceType } from "$app/parsers/product";
import { CurrencyCode, currencyCodeList, findCurrencyByCode } from "$app/utils/currency";
import {
  RecurrenceId,
  durationInMonthsToRecurrenceId,
  recurrenceIds,
  recurrenceLabels,
} from "$app/utils/recurringPricing";
import { assertResponseError, request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import Errors from "$app/components/Form/Errors";
import { Icon } from "$app/components/Icons";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { Alert } from "$app/components/ui/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Pill } from "$app/components/ui/Pill";
import { WithTooltip } from "$app/components/WithTooltip";

const nativeTypeIcons = require.context("$assets/images/native_types/");

const defaultRecurrence: RecurrenceId = "monthly";

const MIN_AI_PROMPT_LENGTH = 10;

type NewProductFormData = {
  link: {
    name: string;
    price_range: string;
    price_currency_type: CurrencyCode;
    native_type: ProductNativeType;
    is_physical: boolean;
    is_recurring_billing: boolean;
    subscription_duration: RecurrenceId | null;
    description: string | null;
    custom_summary: string | null;
    ai_prompt: string;
    number_of_content_pages: number | null;
    release_at_date: string;
  };
};

type FormErrors = {
  "link.base"?: string | undefined;
  "link.name"?: string | undefined;
  "link.price_range"?: string | undefined;
};

type NewProductPageProps = {
  current_seller_currency_code: CurrencyCode;
  native_product_types: ProductNativeType[];
  service_product_types: ProductServiceType[];
  release_at_date: string;
  show_orientation_text: boolean;
  eligible_for_service_products: boolean;
  ai_generation_enabled: boolean;
  ai_promo_dismissed: boolean;
};

const NewProductPage = () => {
  const {
    current_seller_currency_code,
    native_product_types,
    service_product_types,
    release_at_date,
    show_orientation_text,
    eligible_for_service_products,
    ai_generation_enabled,
    ai_promo_dismissed,
  } = cast<NewProductPageProps>(usePage().props);

  const formUID = React.useId();

  const form = useForm<NewProductFormData>("CreateProduct", {
    link: {
      name: "",
      price_range: "",
      price_currency_type: current_seller_currency_code,
      native_type: "digital",
      is_physical: false,
      is_recurring_billing: false,
      subscription_duration: null,
      description: null,
      custom_summary: null,
      ai_prompt: "",
      number_of_content_pages: null,
      release_at_date,
    },
  });

  const errors = cast<FormErrors>(form.errors);

  const [aiPromoVisible, setAiPromoVisible] = useState(ai_generation_enabled && !ai_promo_dismissed);
  const [aiPopoverOpen, setAiPopoverOpen] = useState(false);
  const [isGeneratingUsingAi, setIsGeneratingUsingAi] = useState(false);

  const isRecurringBilling = is<RecurringProductType>(form.data.link.native_type);

  const selectedCurrency = findCurrencyByCode(form.data.link.price_currency_type);

  const handleProductTypeChange = (type: ProductNativeType) => {
    form.setData("link", {
      ...form.data.link,
      native_type: type,
      is_physical: type === "physical",
      is_recurring_billing: is<RecurringProductType>(type),
      subscription_duration: is<RecurringProductType>(type)
        ? form.data.link.subscription_duration || defaultRecurrence
        : null,
    });
  };

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
    if (form.data.link.ai_prompt.trim().length < MIN_AI_PROMPT_LENGTH) {
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
        data: { prompt: form.data.link.ai_prompt.trim() },
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
        const aiData = result.data;
        const subscriptionDuration =
          aiData.native_type === "membership" && aiData.price_frequency_in_months
            ? durationInMonthsToRecurrenceId[aiData.price_frequency_in_months] || defaultRecurrence
            : null;

        form.setData("link", {
          ...form.data.link,
          name: aiData.name,
          description: aiData.description,
          custom_summary: aiData.summary,
          native_type: aiData.native_type,
          number_of_content_pages: aiData.number_of_content_pages,
          price_range: aiData.price.toString(),
          price_currency_type: is<CurrencyCode>(aiData.currency_code)
            ? aiData.currency_code
            : form.data.link.price_currency_type,
          is_physical: aiData.native_type === "physical",
          is_recurring_billing: is<RecurringProductType>(aiData.native_type),
          subscription_duration: subscriptionDuration,
        });

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

  const nameInputRef = React.useRef<HTMLInputElement>(null);
  const priceInputRef = React.useRef<HTMLInputElement>(null);

  const saveProduct = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();

    let hasErrors = false;
    let hasFocused = false;
    if (form.data.link.name.trim() === "") {
      form.setError("link.name", "is required");
      nameInputRef.current?.focus();
      hasErrors = true;
      hasFocused = true;
    } else {
      form.clearErrors("link.name");
    }

    if (form.data.link.price_range.trim() === "") {
      form.setError("link.price_range", "is required");
      if (!hasFocused) {
        priceInputRef.current?.focus();
        hasFocused = true;
      }
      hasErrors = true;
    } else {
      form.clearErrors("link.price_range");
    }

    if (!hasErrors) {
      form.post(Routes.links_path());
    }
  };

  return (
    <>
      <PageHeader
        className="sticky-top"
        title={show_orientation_text ? "Publish your first product" : "What are you creating?"}
        actions={
          <>
            <Button asChild>
              <Link href={Routes.products_path()}>
                <Icon name="x-square" />
                <span>Cancel</span>
              </Link>
            </Button>
            {ai_generation_enabled ? (
              <Popover open={aiPopoverOpen} onOpenChange={setAiPopoverOpen}>
                <PopoverAnchor>
                  <PopoverTrigger aria-label="Create a product with AI" asChild>
                    <Button color="primary" outline>
                      <Icon name="sparkle" />
                    </Button>
                  </PopoverTrigger>
                </PopoverAnchor>
                <PopoverContent>
                  <div className="w-96 max-w-full">
                    <fieldset>
                      <legend>
                        <label htmlFor={`ai-prompt-${formUID}`}>Create a product with AI</label>
                      </legend>
                      <p>
                        Got an idea? Give clear instructions, and let AI create your product—quick and easy! Customize
                        it to make it yours.
                      </p>
                      <textarea
                        id={`ai-prompt-${formUID}`}
                        placeholder="e.g., a 'Coding with AI using Cursor for Designers' ebook with 5 chapters for $35'."
                        value={form.data.link.ai_prompt}
                        onChange={(e) => form.setData("link.ai_prompt", e.target.value)}
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
                        disabled={isGeneratingUsingAi || !form.data.link.ai_prompt.trim()}
                      >
                        {isGeneratingUsingAi ? "Generating..." : "Generate"}
                      </Button>
                    </div>
                  </div>
                </PopoverContent>
              </Popover>
            ) : null}
            <Button color="accent" type="submit" form={`new-product-form-${formUID}`} disabled={form.processing}>
              {form.processing ? "Adding..." : "Next: Customize"}
            </Button>
          </>
        }
      />
      <div>
        <div>
          <form id={`new-product-form-${formUID}`} className="row" onSubmit={saveProduct}>
            <section className="p-4! md:p-8!">
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
                <Alert className="gap-4 p-6" role="status" variant="accent">
                  <div className="flex items-center gap-4">
                    <img src={hands} alt="Hands" className="size-12" />
                    <div className="flex-1">
                      <strong>New.</strong> You can create your product using AI now. Click the sparks button in the
                      header to get started.
                      <br />
                      <a href="/help/article/149-adding-a-product" target="_blank" rel="noreferrer">
                        Learn more
                      </a>
                    </div>
                    <button className="underline" onClick={() => void dismissAiPromo()}>
                      close
                    </button>
                  </div>
                </Alert>
              ) : null}

              <fieldset className={cx({ danger: !!errors["link.name"] })}>
                <legend>
                  <label htmlFor={`name-${formUID}`}>Name</label>
                </legend>

                <input
                  id={`name-${formUID}`}
                  type="text"
                  placeholder="Name of product"
                  value={form.data.link.name}
                  onChange={(e) => form.setData("link.name", e.target.value)}
                  aria-invalid={!!errors["link.name"]}
                  ref={nameInputRef}
                />
                <Errors errors={errors["link.name"]} label="Name" />
              </fieldset>

              <fieldset>
                <legend>Products</legend>
                <ProductTypeSelector
                  selectedType={form.data.link.native_type}
                  types={native_product_types}
                  onChange={handleProductTypeChange}
                />
              </fieldset>
              {service_product_types.length > 0 ? (
                <fieldset>
                  <legend>Services</legend>
                  <ProductTypeSelector
                    selectedType={form.data.link.native_type}
                    types={service_product_types}
                    onChange={handleProductTypeChange}
                    disabled={!eligible_for_service_products}
                  />
                </fieldset>
              ) : null}

              <fieldset className={cx({ danger: !!errors["link.price_range"] || !!errors["link.base"] })}>
                <legend>
                  <label htmlFor={`price-${formUID}`}>
                    {form.data.link.native_type === "coffee" ? "Suggested amount" : "Price"}
                  </label>
                </legend>

                <div className="input">
                  <Pill asChild className="relative -ml-2 shrink-0 cursor-pointer">
                    <label>
                      <span>{selectedCurrency.longSymbol}</span>
                      <TypeSafeOptionSelect
                        onChange={(newCurrencyCode) => {
                          form.setData("link.price_currency_type", newCurrencyCode);
                        }}
                        value={form.data.link.price_currency_type}
                        aria-label="Currency"
                        options={currencyCodeList.map((code) => {
                          const { displayFormat } = findCurrencyByCode(code);
                          return {
                            id: code,
                            label: displayFormat,
                          };
                        })}
                        className="absolute inset-0 z-1 m-0! cursor-pointer opacity-0"
                      />
                      <Icon name="outline-cheveron-down" className="ml-auto" />
                    </label>
                  </Pill>

                  <input
                    id={`price-${formUID}`}
                    type="text"
                    inputMode="decimal"
                    maxLength={10}
                    placeholder="Price your product"
                    value={form.data.link.price_range}
                    onChange={(e) => {
                      let newValue = e.target.value;
                      newValue = newValue.replace(/[.,]+/gu, ".");
                      newValue = newValue.replace(/[^0-9.]/gu, "");
                      form.setData("link.price_range", newValue);
                      form.clearErrors("link.price_range");
                    }}
                    autoComplete="off"
                    aria-invalid={!!errors["link.price_range"] || !!errors["link.base"]}
                    ref={priceInputRef}
                  />

                  {isRecurringBilling ? (
                    <Pill asChild className="relative -mr-2 shrink-0 cursor-pointer">
                      <label>
                        <span>{recurrenceLabels[form.data.link.subscription_duration || defaultRecurrence]}</span>
                        <TypeSafeOptionSelect
                          onChange={(newSubscriptionDuration) => {
                            form.setData("link.subscription_duration", newSubscriptionDuration);
                          }}
                          value={form.data.link.subscription_duration || defaultRecurrence}
                          aria-label="Default subscription duration"
                          options={recurrenceIds.map((recurrence) => ({
                            id: recurrence,
                            label: recurrenceLabels[recurrence],
                          }))}
                          className="absolute inset-0 z-1 m-0! cursor-pointer opacity-0"
                        />
                        <Icon name="outline-cheveron-down" className="ml-auto" />
                      </label>
                    </Pill>
                  ) : null}
                </div>
                <Errors errors={errors["link.price_range"]} label="Price" />
                <Errors errors={errors["link.base"]} label="" />
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
  <div className="radio-buttons grid-cols-1! sm:grid-cols-2! md:grid-cols-3! 2xl:grid-cols-5!" role="radiogroup">
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

export default NewProductPage;
