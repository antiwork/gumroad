import cx from "classnames";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { CustomField, updateCheckoutForm } from "$app/data/checkout_form";
import { RecommendationType } from "$app/data/recommended_products";
import { CardProduct } from "$app/parsers/product";
import { assertDefined } from "$app/utils/assert";
import { PLACEHOLDER_CARD_PRODUCT, PLACEHOLDER_CART_ITEM } from "$app/utils/cart";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { CartItem } from "$app/components/Checkout/cartState";
import { CheckoutPreview } from "$app/components/CheckoutDashboard/CheckoutPreview";
import { Layout, Page } from "$app/components/CheckoutDashboard/Layout";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Select } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
import { Toggle } from "$app/components/Toggle";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";

export type SimpleProduct = { id: string; name: string; archived: boolean };

let lastKey = 0;

const FormPage = ({
  pages,
  user: { display_offer_code_field, recommendation_type, tipping_enabled },
  cart_item,
  card_product,
  custom_fields,
  products,
}: {
  pages: Page[];
  user: { display_offer_code_field: boolean; recommendation_type: RecommendationType; tipping_enabled: boolean };
  cart_item: CartItem | null;
  card_product: CardProduct | null;
  custom_fields: CustomField[];
  products: SimpleProduct[];
}) => {
  const loggedInUser = useLoggedInUser();

  const cartItem = cart_item ?? PLACEHOLDER_CART_ITEM;
  const cardProduct = card_product ?? PLACEHOLDER_CARD_PRODUCT;

  const key = () => (--lastKey).toString();
  const addKey = (field: CustomField) => ({ ...field, key: field.id ? field.id : key() });
  const uid = React.useId();
  const [displayOfferCodeField, setDisplayOfferCodeField] = React.useState(display_offer_code_field);
  const [recommendationType, setRecommendationType] = React.useState(recommendation_type);
  const [tippingEnabled, setTippingEnabled] = React.useState(tipping_enabled);
  const [isSaving, setIsSaving] = React.useState(false);
  const [customFields, setCustomFields] = React.useState<(CustomField & { key: string })[]>(() =>
    custom_fields.map(addKey),
  );
  const updateCustomField = (index: number, value: Partial<CustomField>) => {
    const newValue = [...customFields];
    newValue[index] = { ...assertDefined(customFields[index], "Invalid index"), ...value };
    setCustomFields(newValue);
  };
  const [errors, setErrors] = React.useState<Map<string, Set<string>>>(new Map());

  const handleSave = asyncVoid(async () => {
    const errors = new Map<string, Set<string>>();
    for (const field of customFields) {
      const fieldErrors = new Set<string>();
      if (!field.name) fieldErrors.add("name");
      if (field.type === "terms") {
        try {
          new URL(field.name);
        } catch {
          fieldErrors.add("name");
        }
      }
      if (!field.global && !field.products.length) fieldErrors.add("products");
      if (fieldErrors.size) errors.set(field.key, fieldErrors);
    }
    setErrors(errors);
    if (errors.size) {
      showAlert("Please complete all required fields.", "error");
      return;
    }
    try {
      setIsSaving(true);
      const response = await updateCheckoutForm({
        user: { displayOfferCodeField, recommendationType, tippingEnabled },
        customFields,
      });
      setCustomFields(response.custom_fields.map(addKey));
      showAlert("Changes saved!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsSaving(false);
  });

  return (
    <>
      <Layout
        currentPage="form"
        pages={pages}
        actions={
          <Button
            color="accent"
            onClick={handleSave}
            disabled={!loggedInUser?.policies.checkout_form.update || isSaving}
          >
            {isSaving ? "Saving changes..." : "Save changes"}
          </Button>
        }
        hasAside
      >
        <section className="paragraphs">
          <header style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
            <h2>Custom fields</h2>
            <a data-helper-prompt="How can I add custom fields to my product page?">Learn more</a>
          </header>
          You can add custom fields in your checkout form to get more information from your customers, such as their
          name or more specific instructions.
          {customFields.length > 0 ? (
            <div className="stack">
              {customFields.map((field, i) => (
                <div key={field.key}>
                  <div className="paragraphs">
                    <fieldset>
                      <legend>
                        <label htmlFor={`${uid}-${field.key}-type`}>Type of field</label>
                      </legend>
                      <div style={{ display: "grid", gridTemplateColumns: "1fr auto", gap: "var(--spacer-2)" }}>
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
                    <fieldset className={cx({ danger: errors.get(field.key)?.has("name") })}>
                      <legend>
                        <label htmlFor={`${uid}-${field.key}-name`}>
                          {field.type === "terms" ? "Terms URL" : "Label"}
                        </label>
                      </legend>
                      <input
                        id={`${uid}-${field.key}-name`}
                        value={field.name}
                        aria-invalid={errors.get(field.key)?.has("name") ?? false}
                        onChange={(e) => updateCustomField(i, { name: e.target.value })}
                      />
                    </fieldset>
                    <fieldset className={cx({ danger: errors.get(field.key)?.has("products") })}>
                      <legend>
                        <label htmlFor={`${uid}-${field.key}-products`}>Products</label>
                      </legend>
                      <Select
                        inputId={`${uid}-${field.key}-products`}
                        instanceId={`${uid}-${field.key}-products`}
                        options={products
                          .filter((product) => !product.archived)
                          .map((product) => ({ id: product.id, label: product.name }))}
                        value={products
                          .filter((product) => field.global || field.products.includes(product.id))
                          .map((product) => ({ id: product.id, label: product.name }))}
                        aria-invalid={errors.get(field.key)?.has("products") ?? false}
                        isMulti
                        isClearable
                        onChange={(items) => updateCustomField(i, { global: false, products: items.map(({ id }) => id) })}
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
                </div>
              ))}
            </div>
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
        <section className="paragraphs">
          <header style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
            <h2>Discounts</h2>
            <a data-helper-prompt="How can I create offer codes?">Learn more</a>
          </header>
          <fieldset>
            <legend>Add discount code field to purchase form</legend>
            <label>
              <input
                type="radio"
                checked={displayOfferCodeField}
                onChange={(evt) => setDisplayOfferCodeField(evt.target.checked)}
                disabled={!loggedInUser?.policies.checkout_form.update}
              />
              Only if a discount is available
            </label>
            <label>
              <input
                type="radio"
                checked={!displayOfferCodeField}
                onChange={(evt) => setDisplayOfferCodeField(!evt.target.checked)}
                disabled={!loggedInUser?.policies.checkout_form.update}
              />
              Never
            </label>
          </fieldset>
        </section>
        <section className="paragraphs">
          <header style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
            <h2>More like this recommendations</h2>
            <a data-helper-prompt="How can I use more like this recommendations?">Learn more</a>
          </header>
          <fieldset>
            <legend>Product recommendations during checkout</legend>
            <label>
              <input
                type="radio"
                checked={recommendationType === "no_recommendations"}
                onChange={(evt) => {
                  if (evt.target.checked) setRecommendationType("no_recommendations");
                }}
              />
              Don't recommend any products
            </label>
            <label>
              <input
                type="radio"
                checked={recommendationType === "own_products"}
                onChange={(evt) => {
                  if (evt.target.checked) setRecommendationType("own_products");
                }}
              />
              Recommend my products
            </label>
            <label>
              <input
                type="radio"
                checked={recommendationType === "directly_affiliated_products"}
                onChange={(evt) => {
                  if (evt.target.checked) setRecommendationType("directly_affiliated_products");
                }}
              />
              <span>Recommend my products and products I'm an affiliate of</span>
            </label>
            <label>
              <input
                type="radio"
                checked={recommendationType === "gumroad_affiliates_products"}
                onChange={(evt) => {
                  if (evt.target.checked) setRecommendationType("gumroad_affiliates_products");
                }}
              />
              <span>
                Recommend all products and earn a commission with{" "}
                <a data-helper-prompt="How can I earn a commission with Gumroad Affiliates?">Gumroad Affiliates</a>
              </span>
            </label>
          </fieldset>
        </section>
        <section className="paragraphs">
          <header style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
            <h2>Tipping</h2>
            <a data-helper-prompt="How can I allow customers to add tips to their orders?">Learn more</a>
          </header>
          <Toggle value={tippingEnabled} onChange={setTippingEnabled}>
            Allow customers to add tips to their orders
          </Toggle>
        </section>
      </Layout>
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
    </>
  );
};

export default register({ component: FormPage, propParser: createCast() });
