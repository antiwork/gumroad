import cx from "classnames";
import * as React from "react";
import { Link, useNavigation, useNavigate, useLoaderData } from "react-router-dom";
import { cast } from "ts-safe-cast";

import {
  addCollaborator,
  updateCollaborator,
  CollaboratorFormProduct,
  CollaboratorFormData,
} from "$app/data/collaborators";
import { isValidEmail } from "$app/utils/email";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Layout } from "$app/components/Collaborators/Layout";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { NumberInput } from "$app/components/NumberInput";
import { showAlert } from "$app/components/server-components/Alert";
import { WithTooltip } from "$app/components/WithTooltip";

const DEFAULT_PERCENT_COMMISSION = 50;
const MIN_PERCENT_COMMISSION = 1;
const MAX_PERCENT_COMMISSION = 50;
const MAX_PRODUCTS_WITH_AFFILIATES_TO_SHOW = 10;

const validCommission = (percentCommission: number | null) =>
  percentCommission !== null &&
  percentCommission >= MIN_PERCENT_COMMISSION &&
  percentCommission <= MAX_PERCENT_COMMISSION;

type CollaboratorProduct = CollaboratorFormProduct & {
  has_error: boolean;
};

const CollaboratorForm = () => {
  const navigate = useNavigate();
  const navigation = useNavigation();

  const [isConfirmationModalOpen, setIsConfirmationModalOpen] = React.useState(false);
  const [isConfirmed, setIsConfirmed] = React.useState(false);
  const [isSaving, setIsSaving] = React.useState(false);
  const formData = cast<CollaboratorFormData>(useLoaderData());
  const emailInputRef = React.useRef<HTMLInputElement>(null);
  const isEditing = "id" in formData;

  const hasEnabledUnpublishedOrIneligibleProducts =
    isEditing &&
    formData.products.some((product) => product.enabled && (!product.published || product.has_another_collaborator));

  const [showIneligibleProducts, setShowIneligibleProducts] = React.useState(hasEnabledUnpublishedOrIneligibleProducts);
  const [collaboratorEmail, setCollaboratorEmail] = React.useState<{ value: string; error?: string }>({
    value: "",
  });

  const [applyToAllProducts, setApplyToAllProducts] = React.useState(isEditing ? formData.apply_to_all_products : true);
  const [defaultPercentCommission, setDefaultPercentCommission] = React.useState<{
    value: number | null;
    hasError: boolean;
  }>({
    value: isEditing ? formData.percent_commission || DEFAULT_PERCENT_COMMISSION : DEFAULT_PERCENT_COMMISSION,
    hasError: false,
  });
  const [dontShowAsCoCreator, setDontShowAsCoCreator] = React.useState(
    isEditing ? formData.dont_show_as_co_creator : false,
  );

  const shouldEnableProduct = (product: CollaboratorFormProduct) => {
    if (product.has_another_collaborator) return false;
    return showIneligibleProducts || product.published;
  };

  const shouldShowProduct = (product: CollaboratorFormProduct) => {
    if (showIneligibleProducts) return true;
    return !product.has_another_collaborator && product.published;
  };

  const [products, setProducts] = React.useState<CollaboratorProduct[]>(() =>
    formData.products.map((product) =>
      isEditing
        ? {
            ...product,
            percent_commission: product.percent_commission || defaultPercentCommission.value,
            dont_show_as_co_creator: applyToAllProducts ? dontShowAsCoCreator : product.dont_show_as_co_creator,
            has_error: false,
          }
        : {
            ...product,
            enabled: shouldEnableProduct(product),
            percent_commission: defaultPercentCommission.value,
            has_error: false,
          },
    ),
  );

  const productsWithAffiliates = products.filter((product) => product.enabled && product.has_affiliates);
  const listedProductsWithAffiliatesCount =
    productsWithAffiliates.length <= MAX_PRODUCTS_WITH_AFFILIATES_TO_SHOW + 1
      ? productsWithAffiliates.length
      : MAX_PRODUCTS_WITH_AFFILIATES_TO_SHOW;

  const handleProductChange = (id: string, attrs: Partial<CollaboratorProduct>) => {
    setProducts((prevProducts) =>
      prevProducts.map((item) => (item.id === id ? { ...item, ...attrs, has_error: false } : item)),
    );
  };

  const handleDefaultCommissionChange = (percent_commission: number | null) => {
    setDefaultPercentCommission({ value: percent_commission, hasError: false });
    setProducts((prevProducts) => prevProducts.map((item) => ({ ...item, percent_commission, has_error: false })));
  };

  const handleSubmit = asyncVoid(async () => {
    setProducts((prevProducts) =>
      prevProducts.map((product) => ({
        ...product,
        has_error: product.enabled && !applyToAllProducts && !validCommission(product.percent_commission),
      })),
    );
    setDefaultPercentCommission({
      ...defaultPercentCommission,
      hasError: applyToAllProducts && !validCommission(defaultPercentCommission.value),
    });

    if (!isEditing) {
      const emailError =
        collaboratorEmail.value.length === 0
          ? "Collaborator email must be provided"
          : !isValidEmail(collaboratorEmail.value)
            ? "Please enter a valid email"
            : null;
      setCollaboratorEmail(
        emailError ? { value: collaboratorEmail.value, error: emailError } : { value: collaboratorEmail.value },
      );
      if (emailError) {
        showAlert(emailError, "error");
        emailInputRef.current?.focus();
        return;
      }
    }

    const enabledProducts = products.flatMap(({ id, enabled, percent_commission, dont_show_as_co_creator }) =>
      enabled ? { id, percent_commission, dont_show_as_co_creator } : [],
    );

    if (enabledProducts.length === 0) {
      showAlert("At least one product must be selected", "error");
      return;
    }

    if (
      defaultPercentCommission.hasError ||
      enabledProducts.some((product) => !validCommission(product.percent_commission))
    ) {
      showAlert("Collaborator cut must be 50% or less", "error");
      return;
    }

    if (products.some((product) => product.enabled && product.has_affiliates) && !isConfirmed) {
      setIsConfirmationModalOpen(true);
      return;
    }
    setIsSaving(true);
    const data = {
      apply_to_all_products: applyToAllProducts,
      percent_commission: defaultPercentCommission.value,
      products: enabledProducts,
      dont_show_as_co_creator: dontShowAsCoCreator,
    };
    try {
      await ("id" in formData
        ? updateCollaborator({
            ...data,
            id: formData.id,
          })
        : addCollaborator({
            ...data,
            email: collaboratorEmail.value,
          }));
      showAlert("Changes saved!", "success");
      navigate("/collaborators");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setIsSaving(false);
    }
  });
  React.useEffect(() => {
    if (!isConfirmed) return;
    handleSubmit();
  }, [isConfirmed]);

  return (
    <Layout
      title={isEditing ? formData.name : "New collaborator"}
      headerActions={
        <>
          <Link to="/collaborators" className="button" inert={navigation.state !== "idle"}>
            <Icon name="x-square" />
            Cancel
          </Link>
          <WithTooltip position="bottom" tip={formData.collaborators_disabled_reason}>
            <Button
              color="accent"
              onClick={handleSubmit}
              disabled={formData.collaborators_disabled_reason !== null || isSaving}
            >
              {isSaving ? "Saving..." : isEditing ? "Save changes" : "Add collaborator"}
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
            <fieldset className={cx({ danger: collaboratorEmail.error })}>
              <legend>
                <label htmlFor="email">Email</label>
              </legend>

              <div className="input">
                <input
                  ref={emailInputRef}
                  id="email"
                  type="email"
                  value={collaboratorEmail.value}
                  placeholder="Collaborator's Gumroad account email"
                  onChange={(e) => setCollaboratorEmail({ value: e.target.value.trim() })}
                />
              </div>
            </fieldset>
          ) : null}
          <fieldset>
            <table>
              <thead>
                <tr>
                  <th>Enable</th>
                  <th>Product</th>
                  <th>Cut</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td data-label="All products">
                    <input
                      id="all-products-cut"
                      type="checkbox"
                      role="switch"
                      checked={applyToAllProducts}
                      onChange={(evt) => {
                        const enabled = evt.target.checked;
                        setApplyToAllProducts(enabled);
                        setProducts((prevProducts) =>
                          prevProducts.map((item) => (shouldEnableProduct(item) ? { ...item, enabled } : item)),
                        );
                      }}
                      aria-label="All products"
                    />
                  </td>
                  <td data-label="Product">
                    <label htmlFor="all-products-cut">All products</label>
                  </td>
                  <td data-label="Cut">
                    <fieldset className={cx({ danger: defaultPercentCommission.hasError })}>
                      <NumberInput value={defaultPercentCommission.value} onChange={handleDefaultCommissionChange}>
                        {(inputProps) => (
                          <div className={cx("input", { disabled: !applyToAllProducts })}>
                            <input
                              type="text"
                              disabled={!applyToAllProducts}
                              placeholder={`${defaultPercentCommission.value || DEFAULT_PERCENT_COMMISSION}`}
                              aria-label="Percentage"
                              {...inputProps}
                            />
                            <div className="pill">%</div>
                          </div>
                        )}
                      </NumberInput>
                    </fieldset>
                  </td>
                  <td>
                    <label>
                      <input
                        type="checkbox"
                        checked={!dontShowAsCoCreator}
                        onChange={(evt) => {
                          const value = !evt.target.checked;
                          setDontShowAsCoCreator(value);
                          setProducts((prevProducts) =>
                            prevProducts.map((item) => ({ ...item, dont_show_as_co_creator: value, has_error: false })),
                          );
                        }}
                        disabled={!applyToAllProducts}
                      />
                      Show as co-creator
                    </label>
                  </td>
                </tr>
                {products.map((product) => {
                  const disabled = applyToAllProducts || !product.enabled;

                  return shouldShowProduct(product) ? (
                    <tr key={product.id}>
                      <td data-label="Enable for product">
                        <input
                          id={`enable-product-${product.id}`}
                          type="checkbox"
                          role="switch"
                          disabled={product.has_another_collaborator}
                          checked={product.enabled}
                          onChange={(evt) => handleProductChange(product.id, { enabled: evt.target.checked })}
                          aria-label="Enable all products"
                        />
                      </td>
                      <td data-label="Enable for product">
                        <label htmlFor={`enable-product-${product.id}`}>{product.name}</label>
                        {product.has_another_collaborator || product.has_affiliates ? (
                          <small>
                            {product.has_another_collaborator
                              ? "Already has a collaborator"
                              : "Selecting this product will remove all its affiliates."}
                          </small>
                        ) : null}
                      </td>
                      <td data-label="Cut">
                        <fieldset className={cx({ danger: product.has_error })}>
                          <NumberInput
                            value={product.percent_commission}
                            onChange={(value) => handleProductChange(product.id, { percent_commission: value })}
                          >
                            {(inputProps) => (
                              <div className={cx("input", { disabled })}>
                                <input
                                  disabled={disabled}
                                  type="text"
                                  placeholder={`${defaultPercentCommission.value || DEFAULT_PERCENT_COMMISSION}`}
                                  aria-label="Percentage"
                                  {...inputProps}
                                />
                                <div className="pill">%</div>
                              </div>
                            )}
                          </NumberInput>
                        </fieldset>
                      </td>
                      <td>
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
                      </td>
                    </tr>
                  ) : null;
                })}
              </tbody>
            </table>
          </fieldset>
          <label>
            <input
              type="checkbox"
              checked={showIneligibleProducts}
              onChange={(evt) => {
                const enabled = evt.target.checked;
                setShowIneligibleProducts(enabled);
                if (applyToAllProducts) {
                  setProducts((prevProducts) =>
                    prevProducts.map((item) =>
                      !item.has_another_collaborator && enabled && !item.published ? { ...item, enabled } : item,
                    ),
                  );
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
