import { useForm } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";

import { RecommendationType } from "$app/data/recommended_products";
import { CardProduct } from "$app/parsers/product";
import { assertDefined } from "$app/utils/assert";
import { PLACEHOLDER_CARD_PRODUCT, PLACEHOLDER_CART_ITEM } from "$app/utils/cart";

import { Button } from "$app/components/Button";
import { CartItem } from "$app/components/Checkout/cartState";
import { CheckoutPreview } from "$app/components/CheckoutDashboard/CheckoutPreview";
import { Layout, Page } from "$app/components/CheckoutDashboard/Layout";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { WithPreviewSidebar } from "$app/components/PreviewSidebar";
import { Select } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { Card, CardContent } from "$app/components/ui/Card";
import { Switch } from "$app/components/ui/Switch";

export type SimpleProduct = { id: string; name: string; archived: boolean };

type CustomField = {
  id: string | null;
  type: "text" | "checkbox" | "terms";
  name: string;
  required: boolean;
  global: boolean;
  collect_per_product: boolean;
  products: string[];
};

type CustomFieldWithKey = CustomField & { key: string };

type FormData = {
  user: {
    display_offer_code_field: boolean;
    recommendation_type: RecommendationType;
    tipping_enabled: boolean;
  };
  custom_fields: CustomFieldWithKey[];
};

let lastKey = 0;

export type FormPageProps = {
  pages: Page[];
  user: { display_offer_code_field: boolean; recommendation_type: RecommendationType; tipping_enabled: boolean };
  cart_item: CartItem | null;
  card_product: CardProduct | null;
  custom_fields: CustomField[];
  products: SimpleProduct[];
};

const FormPage = ({
  pages,
  user: { display_offer_code_field, recommendation_type, tipping_enabled },
  cart_item,
  card_product,
  custom_fields,
  products,
}: FormPageProps) => {
  const loggedInUser = useLoggedInUser();

  const cartItem = cart_item ?? PLACEHOLDER_CART_ITEM;
  const cardProduct = card_product ?? PLACEHOLDER_CARD_PRODUCT;

  const key = () => (--lastKey).toString();
  const addKey = (field: CustomField): CustomFieldWithKey => ({ ...field, key: field.id ? field.id : key() });
  const uid = React.useId();
  const [invalidFields, setInvalidFields] = React.useState<Set<string>>(() => new Set());

  const form = useForm<FormData>({
    user: {
      display_offer_code_field,
      recommendation_type,
      tipping_enabled,
    },
    custom_fields: custom_fields.map(addKey),
  });

  const customFields = form.data.custom_fields;

  const setCustomFields = (fields: CustomFieldWithKey[]) => form.setData("custom_fields", fields);

  const updateCustomField = (index: number, value: Partial<CustomField>) => {
    const fieldKey = customFields[index]?.key;
    setInvalidFields((prev) => {
      const next = new Set(prev);
      if (fieldKey) {
        if ("name" in value) next.delete(`custom_fields.${fieldKey}.name`);
        if ("products" in value || "global" in value) next.delete(`custom_fields.${fieldKey}.products`);
      }
      return next;
    });

    const newValue = [...customFields];
    newValue[index] = { ...assertDefined(customFields[index], "Invalid index"), ...value };
    setCustomFields(newValue);
  };

  const updateUserData = (update: Partial<FormData["user"]>) => form.setData("user", { ...form.data.user, ...update });

  const submitForm = () => {
    const newInvalidFields = new Set<string>();

    customFields.forEach((field) => {
      if (!field.name) {
        newInvalidFields.add(`custom_fields.${field.key}.name`);
      }
      if (field.type === "terms") {
        try {
          new URL(field.name);
        } catch {
          newInvalidFields.add(`custom_fields.${field.key}.name`);
        }
      }
      if (!field.global && !field.products.length) {
        newInvalidFields.add(`custom_fields.${field.key}.products`);
      }
    });

    setInvalidFields(newInvalidFields);

    if (newInvalidFields.size > 0) {
      showAlert("Please complete all required fields.", "error");
      return;
    }

    form.transform((data) => ({
      user: data.user,
      custom_fields: data.custom_fields.map(({ key, ...field }) => field),
    }));

    form.put(Routes.checkout_form_path(), {
      preserveScroll: true,
      onError: (errors: Record<string, string | string[]>) => {
        const baseError = errors.base;
        const message = (Array.isArray(baseError) ? baseError[0] : baseError) ?? "Failed to save changes";
        showAlert(message, "error");
      },
    });
  };

  const displayOfferCodeField = form.data.user.display_offer_code_field;
  const recommendationType = form.data.user.recommendation_type;
  const tippingEnabled = form.data.user.tipping_enabled;

  const productOptions = React.useMemo(
    () => products.filter((product) => !product.archived).map((product) => ({ id: product.id, label: product.name })),
    [products],
  );

  return (
    <Layout
      currentPage="form"
      pages={pages}
      actions={
        <Button
          color="accent"
          onClick={submitForm}
          disabled={!loggedInUser?.policies.checkout_form.update || form.processing}
        >
          {form.processing ? "Saving changes..." : "Save changes"}
        </Button>
      }
    >
      <WithPreviewSidebar className="flex-1">
        <div>
          <section className="space-y-4 border-b border-border p-4 md:p-8">
            <header className="flex items-center justify-between">
              <h2>Custom fields</h2>
              <a href="/help/article/101-designing-your-product-page" target="_blank" rel="noreferrer">
                Learn more
              </a>
            </header>
            <div>
              You can add custom fields in your checkout form to get more information from your customers, such as their
              name or more specific instructions.
            </div>
            {customFields.length > 0 ? (
              <Card>
                {customFields.map((field, i) => (
                  <CardContent key={field.key}>
                    <div className="flex grow flex-col gap-4">
                      <fieldset>
                        <legend>
                          <label htmlFor={`${uid}-${field.key}-type`}>Type of field</label>
                        </legend>
                        <div className="flex gap-2">
                          <TypeSafeOptionSelect
                            id={`${uid}-${field.key}-type`}
                            value={field.type}
                            onChange={(type) => updateCustomField(i, { type })}
                            options={[
                              { id: "text", label: "Text" },
                              { id: "checkbox", label: "Checkbox" },
                              { id: "terms", label: "Terms" },
                            ]}
                          />
                          <Button
                            onClick={() => setCustomFields(customFields.filter((_, index) => index !== i))}
                            color="danger"
                            outline
                            aria-label="Remove"
                          >
                            <Icon name="trash2" />
                          </Button>
                        </div>
                        {field.type !== "terms" ? (
                          <label>
                            <input
                              type="checkbox"
                              role="switch"
                              checked={field.required}
                              onChange={(e) => updateCustomField(i, { required: e.target.checked })}
                            />
                            Required
                          </label>
                        ) : null}
                      </fieldset>
                      <fieldset className={cx({ danger: invalidFields.has(`custom_fields.${field.key}.name`) })}>
                        <legend>
                          <label htmlFor={`${uid}-${field.key}-name`}>
                            {field.type === "terms" ? "Terms URL" : "Label"}
                          </label>
                        </legend>
                        <input
                          id={`${uid}-${field.key}-name`}
                          value={field.name}
                          aria-invalid={invalidFields.has(`custom_fields.${field.key}.name`)}
                          onChange={(e) => updateCustomField(i, { name: e.target.value })}
                        />
                      </fieldset>
                      <fieldset className={cx({ danger: invalidFields.has(`custom_fields.${field.key}.products`) })}>
                        <legend>
                          <label htmlFor={`${uid}-${field.key}-products`}>Products</label>
                        </legend>
                        <Select
                          inputId={`${uid}-${field.key}-products`}
                          instanceId={`${uid}-${field.key}-products`}
                          options={productOptions}
                          value={products
                            .filter((product) => field.global || field.products.includes(product.id))
                            .map((product) => ({ id: product.id, label: product.name }))}
                          aria-invalid={invalidFields.has(`custom_fields.${field.key}.products`)}
                          isMulti
                          isClearable
                          onChange={(items) =>
                            updateCustomField(i, { global: false, products: items.map(({ id }) => id) })
                          }
                        />
                        <label>
                          <input
                            type="checkbox"
                            checked={field.global}
                            onChange={(e) =>
                              updateCustomField(
                                i,
                                e.target.checked
                                  ? { global: true, products: products.map(({ id }) => id) }
                                  : { global: false },
                              )
                            }
                          />{" "}
                          All products
                        </label>
                        {field.global || field.products.length > 1 ? (
                          <label>
                            <input
                              type="checkbox"
                              checked={field.collect_per_product}
                              onChange={(e) => updateCustomField(i, { collect_per_product: e.target.checked })}
                            />{" "}
                            Collect separately for each product on checkout
                          </label>
                        ) : null}
                      </fieldset>
                    </div>
                  </CardContent>
                ))}
              </Card>
            ) : null}
            <div>
              <Button
                color="primary"
                onClick={() =>
                  setCustomFields([
                    ...customFields,
                    {
                      id: null,
                      products: [],
                      name: "",
                      required: false,
                      type: "text",
                      global: false,
                      collect_per_product: false,
                      key: key(),
                    },
                  ])
                }
              >
                <Icon name="plus" />
                Add custom field
              </Button>
            </div>
          </section>
          <section className="space-y-4 border-b border-border p-4 md:p-8">
            <header className="flex items-center justify-between">
              <h2>Discounts</h2>
              <a href="/help/article/128-discount-codes" target="_blank" rel="noreferrer">
                Learn more
              </a>
            </header>
            <fieldset>
              <legend>Add discount code field to purchase form</legend>
              <label>
                <input
                  type="radio"
                  checked={displayOfferCodeField}
                  onChange={(evt) => updateUserData({ display_offer_code_field: evt.target.checked })}
                  disabled={!loggedInUser?.policies.checkout_form.update}
                />
                Only if a discount is available
              </label>
              <label>
                <input
                  type="radio"
                  checked={!displayOfferCodeField}
                  onChange={(evt) => updateUserData({ display_offer_code_field: !evt.target.checked })}
                  disabled={!loggedInUser?.policies.checkout_form.update}
                />
                Never
              </label>
            </fieldset>
          </section>
          <section className="space-y-4 border-b border-border p-4 md:p-8">
            <header className="flex items-center justify-between">
              <h2>More like this recommendations</h2>
              <a href="/help/article/334-more-like-this" target="_blank" rel="noreferrer">
                Learn more
              </a>
            </header>
            <fieldset>
              <legend>Product recommendations during checkout</legend>
              <label>
                <input
                  type="radio"
                  checked={recommendationType === "no_recommendations"}
                  onChange={(evt) => {
                    if (evt.target.checked) updateUserData({ recommendation_type: "no_recommendations" });
                  }}
                />
                Don't recommend any products
              </label>
              <label>
                <input
                  type="radio"
                  checked={recommendationType === "own_products"}
                  onChange={(evt) => {
                    if (evt.target.checked) updateUserData({ recommendation_type: "own_products" });
                  }}
                />
                Recommend my products
              </label>
              <label>
                <input
                  type="radio"
                  checked={recommendationType === "directly_affiliated_products"}
                  onChange={(evt) => {
                    if (evt.target.checked) updateUserData({ recommendation_type: "directly_affiliated_products" });
                  }}
                />
                <span>Recommend my products and products I'm an affiliate of</span>
              </label>
              <label>
                <input
                  type="radio"
                  checked={recommendationType === "gumroad_affiliates_products"}
                  onChange={(evt) => {
                    if (evt.target.checked) updateUserData({ recommendation_type: "gumroad_affiliates_products" });
                  }}
                />
                <span>
                  Recommend all products and earn a commission with{" "}
                  <a href="/help/article/249-affiliate-faq" target="_blank" rel="noreferrer">
                    Gumroad Affiliates
                  </a>
                </span>
              </label>
            </fieldset>
          </section>
          <section className="space-y-4 border-b border-border p-4 md:p-8">
            <header className="flex items-center justify-between">
              <h2>Tipping</h2>
              <a href="/help/article/345-tipping" target="_blank" rel="noreferrer">
                Learn more
              </a>
            </header>
            <Switch
              checked={tippingEnabled}
              onChange={(e) => updateUserData({ tipping_enabled: e.target.checked })}
              label="Allow customers to add tips to their orders"
            />
          </section>
        </div>
        <CheckoutPreview
          cartItem={{
            ...cartItem,
            product: {
              ...cartItem.product,
              has_offer_codes: displayOfferCodeField,
              custom_fields: customFields.map(({ key, ...field }) => ({ ...field, id: key })),
              has_tipping_enabled: tippingEnabled,
            },
          }}
          recommendedProduct={recommendationType !== "no_recommendations" ? cardProduct : undefined}
        />
      </WithPreviewSidebar>
    </Layout>
  );
};

export default FormPage;
