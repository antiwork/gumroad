import { useForm } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";

import type { CollaboratorFormProduct, EditPageProps, NewPageProps } from "$app/data/collaborators";
import { isValidEmail } from "$app/utils/email";

import { Button } from "$app/components/Button";
import { Layout } from "$app/components/Collaborators/Layout";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { NumberInput } from "$app/components/NumberInput";
import { showAlert } from "$app/components/server-components/Alert";
import { Pill } from "$app/components/ui/Pill";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { WithTooltip } from "$app/components/WithTooltip";

const WITH_CONFIRMED_ACKNOWLEDGEMENT = "withConfirmedAcknowledgement";

const validCommission = (
  percentCommission: number | null,
  minPercentCommission: number,
  maxPercentCommission: number,
) =>
  percentCommission !== null && percentCommission >= minPercentCommission && percentCommission <= maxPercentCommission;

const CollaboratorForm = ({
  form_data: formData,
  collaborators_disabled_reason: collaboratorsDisabledReason,
  page_metadata: pageMetadata,
}: NewPageProps | EditPageProps) => {
  const [isConfirmationModalOpen, setIsConfirmationModalOpen] = React.useState(false);
  const form = useForm(formData);
  const emailInputRef = React.useRef<HTMLInputElement>(null);
  const isEditPage = "id" in formData;

  const [showUnpublishedOrIneligibleProducts, setShowUnpublishedOrIneligibleProducts] = React.useState(
    () =>
      isEditPage &&
      formData.products.some((product) => product.enabled && (!product.published || product.has_another_collaborator)),
  );

  const shouldEnableProduct = (product: CollaboratorFormProduct) => {
    if (product.has_another_collaborator) return false;
    return showUnpublishedOrIneligibleProducts || product.published;
  };

  const shouldShowProduct = (product: CollaboratorFormProduct) => {
    if (showUnpublishedOrIneligibleProducts) return true;
    return !product.has_another_collaborator && product.published;
  };

  const productsWithAffiliates = form.data.products.filter((product) => product.enabled && product.has_affiliates);
  const listedProductsWithAffiliatesCount =
    productsWithAffiliates.length <= pageMetadata.max_products_with_affiliates_to_show + 1
      ? productsWithAffiliates.length
      : pageMetadata.max_products_with_affiliates_to_show;

  const submitForm = (acknowledgement?: typeof WITH_CONFIRMED_ACKNOWLEDGEMENT) => {
    let commissionErrorMessage: string | null = null;
    if (
      form.data.apply_to_all_products &&
      !validCommission(
        form.data.percent_commission,
        pageMetadata.min_percent_commission,
        pageMetadata.max_percent_commission,
      )
    ) {
      commissionErrorMessage = `Collaborator cut must be ${pageMetadata.max_percent_commission}% or less`;
      form.setError("percent_commission", commissionErrorMessage);
    } else form.clearErrors("percent_commission");

    form.data.products.forEach((product, index) => {
      if (
        product.enabled &&
        !form.data.apply_to_all_products &&
        !validCommission(
          product.percent_commission,
          pageMetadata.min_percent_commission,
          pageMetadata.max_percent_commission,
        )
      ) {
        commissionErrorMessage = `Collaborator cut must be ${pageMetadata.max_percent_commission}% or less`;
        form.setError(`products.${index}.percent_commission`, commissionErrorMessage);
      } else form.clearErrors(`products.${index}.percent_commission`);
    });

    if (!isEditPage) {
      const emailError =
        form.data.email?.length === 0
          ? "Collaborator email must be provided"
          : !isValidEmail(form.data.email ?? "")
            ? "Please enter a valid email"
            : null;
      if (emailError) {
        form.setError("email", emailError);
        showAlert(emailError, "error");
        emailInputRef.current?.focus();
        return;
      }

      form.clearErrors("email");
    }

    const enabledProducts = form.data.products.flatMap(
      ({ id, enabled, percent_commission, dont_show_as_co_creator }) =>
        enabled ? { id, percent_commission, dont_show_as_co_creator } : [],
    );

    if (enabledProducts.length === 0) {
      showAlert("At least one product must be selected", "error");
      return;
    }

    if (commissionErrorMessage) {
      showAlert(commissionErrorMessage, "error");
      return;
    }

    if (
      acknowledgement !== WITH_CONFIRMED_ACKNOWLEDGEMENT &&
      form.data.products.some((product) => product.enabled && product.has_affiliates) &&
      !isConfirmationModalOpen
    ) {
      setIsConfirmationModalOpen(true);
      return;
    }

    form.clearErrors();

    form.transform((data) => ({
      collaborator: {
        ...data,
        products: enabledProducts,
      },
    }));

    if (isEditPage) {
      form.patch(Routes.collaborator_path(formData.id), {
        only: ["errors", "flash"],
      });
    } else {
      form.post(Routes.collaborators_path(), {
        only: ["errors", "flash"],
      });
    }
  };

  return (
    <Layout
      title={pageMetadata.title}
      headerActions={
        <>
          <NavigationButtonInertia disabled={form.processing} href={Routes.collaborators_path()}>
            <Icon name="x-square" />
            Cancel
          </NavigationButtonInertia>
          <WithTooltip position="bottom" tip={collaboratorsDisabledReason}>
            <Button
              color="accent"
              onClick={() => submitForm()}
              disabled={collaboratorsDisabledReason !== null || form.processing}
            >
              {form.processing ? "Saving..." : isEditPage ? "Save changes" : "Add collaborator"}
            </Button>
          </WithTooltip>
        </>
      }
    >
      <form>
        <section className="p-8!">
          <header>
            {isEditPage ? <h2>Products</h2> : null}
            <div>Collaborators will receive a cut from the revenue generated by the selected products.</div>
            <a href="/help/article/341-collaborations" target="_blank" rel="noreferrer">
              Learn more
            </a>
          </header>
          {!isEditPage ? (
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
                  onChange={(evt) => {
                    form.setData("email", evt.target.value.trim());
                    form.clearErrors("email");
                  }}
                />
              </div>
            </fieldset>
          ) : null}
          <fieldset>
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
                        form.setData("apply_to_all_products", enabled);
                        form.data.products.forEach((item, index) => {
                          if (shouldEnableProduct(item)) form.setData(`products.${index}.enabled`, enabled);
                        });
                      }}
                      aria-label="All products"
                    />
                  </TableCell>
                  <TableCell>
                    <label htmlFor="all-products-cut">All products</label>
                  </TableCell>
                  <TableCell>
                    <fieldset className={cx({ danger: form.errors.percent_commission })}>
                      <NumberInput
                        value={form.data.percent_commission}
                        onChange={(percentCommissionValue) => {
                          form.setData("percent_commission", percentCommissionValue);
                          form.clearErrors("percent_commission");
                          form.data.products.forEach((_, index) => {
                            form.setData(`products.${index}.percent_commission`, percentCommissionValue);
                            form.clearErrors(`products.${index}.percent_commission`);
                          });
                        }}
                      >
                        {(inputProps) => (
                          <div className={cx("input", { disabled: !form.data.apply_to_all_products })}>
                            <input
                              type="text"
                              disabled={!form.data.apply_to_all_products}
                              placeholder={`${form.data.percent_commission || pageMetadata.default_percent_commission}`}
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
                        checked={!form.data.dont_show_as_co_creator}
                        onChange={(evt) => {
                          const value = !evt.target.checked;
                          form.setData("dont_show_as_co_creator", value);
                          form.data.products.forEach((_, index) => {
                            form.setData(`products.${index}.dont_show_as_co_creator`, value);
                            form.clearErrors(`products.${index}.percent_commission`);
                          });
                        }}
                        disabled={!form.data.apply_to_all_products}
                      />
                      Show as co-creator
                    </label>
                  </TableCell>
                </TableRow>
                {form.data.products.map((product, index) => {
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
                          onChange={(evt) => {
                            form.setData(`products.${index}.enabled`, evt.target.checked);
                            form.clearErrors(`products.${index}.enabled`);
                          }}
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
                        <fieldset className={cx({ danger: form.errors[`products.${index}.percent_commission`] })}>
                          <NumberInput
                            value={product.percent_commission}
                            onChange={(value) => {
                              form.setData(`products.${index}.percent_commission`, value);
                              form.clearErrors(`products.${index}.percent_commission`);
                            }}
                          >
                            {(inputProps) => (
                              <div className={cx("input", { disabled })}>
                                <input
                                  disabled={disabled}
                                  type="text"
                                  placeholder={`${product.percent_commission || pageMetadata.default_percent_commission}`}
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
                            onChange={(evt) => {
                              form.setData(`products.${index}.dont_show_as_co_creator`, !evt.target.checked);
                              form.clearErrors(`products.${index}.percent_commission`);
                            }}
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
              checked={showUnpublishedOrIneligibleProducts}
              onChange={(evt) => {
                const enabled = evt.target.checked;
                setShowUnpublishedOrIneligibleProducts(enabled);
                if (form.data.apply_to_all_products) {
                  form.data.products.forEach((item, index) => {
                    if (!item.has_another_collaborator && enabled && !item.published) {
                      form.setData(`products.${index}.enabled`, enabled);
                    }
                  });
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
                submitForm(WITH_CONFIRMED_ACKNOWLEDGEMENT);
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
