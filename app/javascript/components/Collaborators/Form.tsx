import { useForm } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";

import type { CollaboratorFormProduct, CollaboratorFormData } from "$app/data/collaborators";
import { isValidEmail } from "$app/utils/email";

import { Button } from "$app/components/Button";
import { Layout } from "$app/components/Collaborators/Layout";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { NumberInput } from "$app/components/NumberInput";
import { Pill } from "$app/components/ui/Pill";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { WithTooltip } from "$app/components/WithTooltip";

const DEFAULT_PERCENT_COMMISSION = 50;
const MIN_PERCENT_COMMISSION = 1;
const MAX_PERCENT_COMMISSION = 50;
const MAX_PRODUCTS_WITH_AFFILIATES_TO_SHOW = 10;

const validCommission = (percentCommission: number | null) =>
  percentCommission !== null &&
  percentCommission >= MIN_PERCENT_COMMISSION &&
  percentCommission <= MAX_PERCENT_COMMISSION;

type CollaboratorProduct = CollaboratorFormProduct;

const CollaboratorForm = ({ formData }: { formData: CollaboratorFormData }) => {
  const isEditing = "id" in formData;
  const emailInputRef = React.useRef<HTMLInputElement>(null);

  const initialApplyToAllProducts = isEditing ? formData.apply_to_all_products : true;
  const initialDefaultPercentCommission = isEditing
    ? formData.percent_commission || DEFAULT_PERCENT_COMMISSION
    : DEFAULT_PERCENT_COMMISSION;
  const initialDontShowAsCoCreator = isEditing ? formData.dont_show_as_co_creator : false;

  const hasEnabledUnpublishedOrIneligibleProducts =
    isEditing &&
    formData.products.some((product) => product.enabled && (!product.published || product.has_another_collaborator));

  const [showIneligibleProducts, setShowIneligibleProducts] = React.useState(hasEnabledUnpublishedOrIneligibleProducts);
  const [isConfirmationModalOpen, setIsConfirmationModalOpen] = React.useState(false);
  const [isConfirmed, setIsConfirmed] = React.useState(false);

  const shouldEnableProduct = (product: CollaboratorFormProduct) => {
    if (product.has_another_collaborator) return false;
    return showIneligibleProducts || product.published;
  };

  const shouldShowProduct = (product: CollaboratorFormProduct) => {
    if (showIneligibleProducts) return true;
    return !product.has_another_collaborator && product.published;
  };

  const form = useForm<{
    email: string;
    apply_to_all_products: boolean;
    percent_commission: number | null;
    dont_show_as_co_creator: boolean;
    products: CollaboratorProduct[];
  }>({
    email: isEditing ? formData.email : "",
    apply_to_all_products: initialApplyToAllProducts,
    percent_commission: initialDefaultPercentCommission,
    dont_show_as_co_creator: initialDontShowAsCoCreator,
    products: formData.products.map((product): CollaboratorProduct => {
      if (isEditing) {
        return {
          ...product,
          percent_commission: product.percent_commission || initialDefaultPercentCommission,
          dont_show_as_co_creator: initialApplyToAllProducts
            ? initialDontShowAsCoCreator
            : product.dont_show_as_co_creator,
        };
      }
      return {
        ...product,
        enabled: shouldEnableProduct(product),
        percent_commission: initialDefaultPercentCommission,
        dont_show_as_co_creator: false,
      };
    }),
  });

  const productsWithAffiliates = form.data.products.filter((product) => product.enabled && product.has_affiliates);
  const listedProductsWithAffiliatesCount =
    productsWithAffiliates.length <= MAX_PRODUCTS_WITH_AFFILIATES_TO_SHOW + 1
      ? productsWithAffiliates.length
      : MAX_PRODUCTS_WITH_AFFILIATES_TO_SHOW;

  const handleProductChange = (id: string, attrs: Partial<CollaboratorProduct>) => {
    form.clearErrors();
    form.setData(
      "products",
      form.data.products.map((item) => (item.id === id ? { ...item, ...attrs } : item)),
    );
  };

  const handleDefaultCommissionChange = (value: number | null) => {
    form.clearErrors();
    form.setData((prevData) => ({
      ...prevData,
      percent_commission: value,
      products: prevData.products.map((item) => ({ ...item, percent_commission: value })),
    }));
  };

  const submitForm = () => {
    form.clearErrors();

    // Validate default commission
    if (form.data.apply_to_all_products && !validCommission(form.data.percent_commission)) {
      form.setError("percent_commission", "Collaborator cut must be 50% or less");
      return;
    }

    // Validate per-product commissions
    const hasInvalidProductCommission = form.data.products.some(
      (product) => product.enabled && !form.data.apply_to_all_products && !validCommission(product.percent_commission),
    );
    if (hasInvalidProductCommission) {
      form.setError("products", "Collaborator cut must be 50% or less");
      return;
    }

    // Validate email for new collaborators
    if (!isEditing) {
      if (form.data.email.length === 0) {
        form.setError("email", "Collaborator email must be provided");
        emailInputRef.current?.focus();
        return;
      } else if (!isValidEmail(form.data.email)) {
        form.setError("email", "Please enter a valid email");
        emailInputRef.current?.focus();
        return;
      }
    }

    // Validate at least one product enabled
    const enabledCount = form.data.products.filter((p) => p.enabled).length;
    if (enabledCount === 0) {
      form.setError("products", "At least one product must be selected");
      return;
    }

    // Show confirmation modal for products with affiliates
    if (productsWithAffiliates.length > 0 && !isConfirmed) {
      setIsConfirmationModalOpen(true);
      return;
    }

    form.transform((currentData) => {
      const enabledProducts = currentData.products.flatMap(
        ({ id, enabled, percent_commission, dont_show_as_co_creator }: CollaboratorProduct) =>
          enabled ? { id, percent_commission, dont_show_as_co_creator } : [],
      );

      return {
        collaborator: {
          apply_to_all_products: currentData.apply_to_all_products,
          percent_commission: currentData.percent_commission,
          dont_show_as_co_creator: currentData.dont_show_as_co_creator,
          products: enabledProducts,
          ...(!isEditing && { email: currentData.email }),
        },
      };
    });

    if (isEditing) {
      form.patch(Routes.collaborator_path(formData.id));
    } else {
      form.post(Routes.collaborators_path());
    }
  };

  React.useEffect(() => {
    if (!isConfirmed) return;
    submitForm();
  }, [isConfirmed]);

  return (
    <Layout
      title={isEditing ? formData.name : "New collaborator"}
      headerActions={
        <>
          <NavigationButtonInertia href={Routes.collaborators_path()}>
            <Icon name="x-square" />
            Cancel
          </NavigationButtonInertia>
          <WithTooltip position="bottom" tip={formData.collaborators_disabled_reason}>
            <Button
              color="accent"
              onClick={submitForm}
              disabled={formData.collaborators_disabled_reason !== null || form.processing}
            >
              {form.processing ? "Saving..." : isEditing ? "Save changes" : "Add collaborator"}
            </Button>
          </WithTooltip>
        </>
      }
    >
      <form>
        <section className="p-8!">
          <header>
            {isEditing ? <h2>Products</h2> : null}
            <div>Collaborators will receive a cut from the revenue generated by the selected products.</div>
            <a href="/help/article/341-collaborations" target="_blank" rel="noreferrer">
              Learn more
            </a>
          </header>
          {!isEditing ? (
            <fieldset className={cx({ danger: form.errors.email })}>
              <legend>
                <label htmlFor="email">Email</label>
              </legend>

              <div className="input">
                <input
                  ref={emailInputRef}
                  id="email"
                  type="email"
                  value={form.data.email}
                  placeholder="Collaborator's Gumroad account email"
                  onChange={(e) => form.setData("email", e.target.value.trim())}
                />
              </div>
              {form.errors.email ? <p className="message">{form.errors.email}</p> : null}
            </fieldset>
          ) : null}
          <fieldset className={cx({ danger: form.errors.products })}>
            {form.errors.products ? <p className="message">{form.errors.products}</p> : null}
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Enable</TableHead>
                  <TableHead>Product</TableHead>
                  <TableHead>Cut</TableHead>
                  <TableHead />
                </TableRow>
              </TableHeader>
              <TableBody>
                <TableRow>
                  <TableCell>
                    <input
                      id="all-products-cut"
                      type="checkbox"
                      role="switch"
                      checked={form.data.apply_to_all_products}
                      onChange={(evt) => {
                        const enabled = evt.target.checked;
                        form.setData((prev) => ({
                          ...prev,
                          apply_to_all_products: enabled,
                          products: prev.products.map((item) =>
                            shouldEnableProduct(item) ? { ...item, enabled } : item,
                          ),
                        }));
                      }}
                      aria-label="All products"
                    />
                  </TableCell>
                  <TableCell>
                    <label htmlFor="all-products-cut">All products</label>
                  </TableCell>
                  <TableCell>
                    <fieldset className={cx({ danger: form.errors.percent_commission })}>
                      <NumberInput value={form.data.percent_commission} onChange={handleDefaultCommissionChange}>
                        {(inputProps) => (
                          <div className={cx("input", { disabled: !form.data.apply_to_all_products })}>
                            <input
                              type="text"
                              disabled={!form.data.apply_to_all_products}
                              placeholder={`${form.data.percent_commission || DEFAULT_PERCENT_COMMISSION}`}
                              aria-label="Percentage"
                              {...inputProps}
                            />
                            <Pill className="-mr-2 shrink-0">%</Pill>
                          </div>
                        )}
                      </NumberInput>
                      {form.errors.percent_commission ? <p className="message">{form.errors.percent_commission}</p> : null}
                    </fieldset>
                  </TableCell>
                  <TableCell>
                    <label>
                      <input
                        type="checkbox"
                        checked={!form.data.dont_show_as_co_creator}
                        onChange={(evt) => {
                          const value = !evt.target.checked;
                          form.setData((prev) => ({
                            ...prev,
                            dont_show_as_co_creator: value,
                            products: prev.products.map((item) => ({
                              ...item,
                              dont_show_as_co_creator: value,
                            })),
                          }));
                        }}
                        disabled={!form.data.apply_to_all_products}
                      />
                      Show as co-creator
                    </label>
                  </TableCell>
                </TableRow>
                {form.data.products.map((product) => {
                  const disabled = form.data.apply_to_all_products || !product.enabled;

                  return shouldShowProduct(product) ? (
                    <TableRow key={product.id}>
                      <TableCell>
                        <input
                          id={`enable-product-${product.id}`}
                          type="checkbox"
                          role="switch"
                          disabled={product.has_another_collaborator}
                          checked={product.enabled}
                          onChange={(evt) => handleProductChange(product.id, { enabled: evt.target.checked })}
                          aria-label="Enable all products"
                        />
                      </TableCell>
                      <TableCell>
                        <label htmlFor={`enable-product-${product.id}`}>{product.name}</label>
                        {product.has_another_collaborator || product.has_affiliates ? (
                          <small>
                            {product.has_another_collaborator
                              ? "Already has a collaborator"
                              : "Selecting this product will remove all its affiliates."}
                          </small>
                        ) : null}
                      </TableCell>
                      <TableCell>
                        <fieldset className={cx({ danger: form.errors.products && !form.data.apply_to_all_products })}>
                          <NumberInput
                            value={product.percent_commission}
                            onChange={(value) => handleProductChange(product.id, { percent_commission: value })}
                          >
                            {(inputProps) => (
                              <div className={cx("input", { disabled })}>
                                <input
                                  disabled={disabled}
                                  type="text"
                                  placeholder={`${form.data.percent_commission || DEFAULT_PERCENT_COMMISSION}`}
                                  aria-label="Percentage"
                                  {...inputProps}
                                />
                                <Pill className="-mr-2 shrink-0">%</Pill>
                              </div>
                            )}
                          </NumberInput>
                        </fieldset>
                      </TableCell>
                      <TableCell>
                        <label>
                          <input
                            type="checkbox"
                            checked={!product.dont_show_as_co_creator}
                            onChange={(evt) =>
                              handleProductChange(product.id, { dont_show_as_co_creator: !evt.target.checked })
                            }
                            disabled={disabled}
                          />
                          Show as co-creator
                        </label>
                      </TableCell>
                    </TableRow>
                  ) : null;
                })}
              </TableBody>
            </Table>
          </fieldset>
          <label>
            <input
              type="checkbox"
              checked={showIneligibleProducts}
              onChange={(evt) => {
                const enabled = evt.target.checked;
                setShowIneligibleProducts(enabled);
                if (form.data.apply_to_all_products) {
                  form.setData((prev) => ({
                    ...prev,
                    products: prev.products.map((item) =>
                      !item.has_another_collaborator && enabled && !item.published ? { ...item, enabled } : item,
                    ),
                  }));
                }
              }}
            />
            Show unpublished and ineligible products
          </label>
        </section>
        <Modal
          open={isConfirmationModalOpen}
          title="Remove affiliates?"
          onClose={() => setIsConfirmationModalOpen(false)}
        >
          <h4 className="mb-3">
            Affiliates will be removed from the following products:
            <ul>
              {productsWithAffiliates.slice(0, listedProductsWithAffiliatesCount).map((product) => (
                <li key={product.id}>{product.name}</li>
              ))}
            </ul>
            {listedProductsWithAffiliatesCount < productsWithAffiliates.length ? (
              <span>{`and ${productsWithAffiliates.length - listedProductsWithAffiliatesCount} others.`}</span>
            ) : null}
          </h4>
          <div className="flex justify-between gap-3">
            <Button className="grow" onClick={() => setIsConfirmationModalOpen(false)}>
              No, cancel
            </Button>
            <Button
              color="primary"
              className="grow"
              onClick={() => {
                setIsConfirmationModalOpen(false);
                setIsConfirmed(true);
              }}
            >
              Yes, continue
            </Button>
          </div>
        </Modal>
      </form>
    </Layout>
  );
};

export default CollaboratorForm;
