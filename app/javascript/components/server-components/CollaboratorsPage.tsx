import cx from "classnames";
import * as React from "react";
import * as ReactDOM from "react-dom";
import {
  RouterProvider,
  createBrowserRouter,
  json,
  Link,
  redirect,
  useNavigation,
  useNavigate,
  useLoaderData,
  useRevalidator,
} from "react-router-dom";
import { cast } from "ts-safe-cast";

import {
  addCollaborator,
  getCollaborators,
  getEditCollaborator,
  getNewCollaborator,
  updateCollaborator,
  Collaborator,
  CollaboratorsData,
  CollaboratorFormProduct,
  CollaboratorFormData,
  removeCollaborator,
} from "$app/data/collaborators";
import { getIncomingCollaborators } from "$app/data/incoming_collaborators";
import { assertDefined } from "$app/utils/assert";
import { isValidEmail } from "$app/utils/email";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Modal } from "$app/components/Modal";
import { NumberInput } from "$app/components/NumberInput";
import { showAlert } from "$app/components/server-components/Alert";
import { IncomingCollaborators } from "$app/components/server-components/CollaboratorsPage/IncomingCollaborators";
import { Layout } from "$app/components/server-components/CollaboratorsPage/Layout";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/collaborators.png";

const DEFAULT_PERCENT_COMMISSION = 50;
const MIN_PERCENT_COMMISSION = 1;
const MAX_PERCENT_COMMISSION = 50;
const MAX_PRODUCTS_WITH_AFFILIATES_TO_SHOW = 10;

const validCommission = (percentCommission: number | null) =>
  percentCommission !== null &&
  percentCommission >= MIN_PERCENT_COMMISSION &&
  percentCommission <= MAX_PERCENT_COMMISSION;

const formatProductNames = (collaborator: Collaborator) => {
  if (collaborator.products.length === 0) {
    return "None";
  } else if (collaborator.products.length === 1 && collaborator.products[0]) {
    return collaborator.products[0].name;
  }
  const count = collaborator.products.length;
  return count === 1 ? "1 product" : `${count.toLocaleString()} products`;
};

const formatAsPercent = (commission: number) => (commission / 100).toLocaleString([], { style: "percent" });

const formatCommission = (collaborator: Collaborator) => {
  if (collaborator.products.length > 0) {
    const sortedCommissions = collaborator.products
      .map((product) => product.percent_commission)
      .filter(Number)
      .sort((a, b) => (a === null || b === null ? -1 : a - b));
    const commissions = [...new Set(sortedCommissions)]; // remove duplicates
    if (commissions.length === 0 && collaborator.percent_commission !== null) {
      return formatAsPercent(collaborator.percent_commission);
    } else if (commissions.length === 1 && commissions[0]) {
      return formatAsPercent(commissions[0]);
    } else if (commissions.length > 1) {
      const lowestCommission = commissions[0];
      const highestCommission = commissions[commissions.length - 1];
      if (lowestCommission && highestCommission) {
        return `${formatAsPercent(lowestCommission)} - ${formatAsPercent(highestCommission)}`;
      }
    }
  }
  return collaborator.percent_commission !== null ? formatAsPercent(collaborator.percent_commission) : "";
};

const CollaboratorDetails = ({
  selectedCollaborator,
  onClose,
  onRemove,
}: {
  selectedCollaborator: Collaborator;
  onClose: () => void;
  onRemove: (id: string) => void;
}) => {
  const loggedInUser = useLoggedInUser();
  const navigation = useNavigation();

  return ReactDOM.createPortal(
    <aside className="!flex !flex-col">
      <header>
        <h2>{selectedCollaborator.name}</h2>
        <button className="close" aria-label="Close" onClick={onClose} />
      </header>

      {selectedCollaborator.setup_incomplete ? (
        <div role="alert" className="warning">
          Collaborators won't receive their cut until they set up a payout account in their Gumroad settings.
        </div>
      ) : null}

      <section className="stack">
        <h3>Email</h3>
        <div>
          <span>{selectedCollaborator.email}</span>
        </div>
      </section>

      <section className="stack">
        <h3>Products</h3>
        {selectedCollaborator.products.map((product) => (
          <section key={product.id}>
            <div>{product.name}</div>
            <div>{formatAsPercent(product.percent_commission || selectedCollaborator.percent_commission || 0)}</div>
          </section>
        ))}
      </section>

      <section className="mt-auto flex gap-4">
        <Link
          style={{ flex: 1 }}
          to={`/collaborators/${selectedCollaborator.id}/edit`}
          className="button"
          aria-label="Edit"
          inert={!loggedInUser?.policies.collaborator.update || navigation.state !== "idle"}
        >
          Edit
        </Link>
        <Button
          style={{ flex: 1 }}
          color="danger"
          aria-label="Delete"
          onClick={() => onRemove(selectedCollaborator.id)}
          disabled={!loggedInUser?.policies.collaborator.update || navigation.state !== "idle"}
        >
          {navigation.state === "submitting" ? "Removing..." : "Remove"}
        </Button>
      </section>
    </aside>,
    document.body,
  );
};

const Collaborators = () => {
  const loggedInUser = useLoggedInUser();
  const navigation = useNavigation();
  const revalidator = useRevalidator();

  const { collaborators, collaborators_disabled_reason, has_incoming_collaborators } =
    cast<CollaboratorsData>(useLoaderData());
  const [selectedCollaborator, setSelectedCollaborator] = React.useState<Collaborator | null>(null);

  const remove = asyncVoid(async (collaboratorId: string) => {
    try {
      await removeCollaborator(collaboratorId);
      setSelectedCollaborator(null);
      revalidator.revalidate();
      showAlert("The collaborator was removed successfully.", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert("Failed to remove the collaborator.", "error");
    }
  });

  return (
    <Layout
      title="Collaborators"
      selectedTab="collaborators"
      showTabs={has_incoming_collaborators}
      headerActions={
        <WithTooltip position="bottom" tip={collaborators_disabled_reason}>
          <Link
            to="/collaborators/new"
            className="button accent"
            inert={
              !loggedInUser?.policies.collaborator.create ||
              navigation.state !== "idle" ||
              collaborators_disabled_reason !== null
            }
          >
            Add collaborator
          </Link>
        </WithTooltip>
      }
    >
      {collaborators.length > 0 ? (
        <>
          <section className="p-4 md:p-8">
            <table>
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Products</th>
                  <th>Cut</th>
                  <th>Status</th>
                  <th />
                </tr>
              </thead>

              <tbody>
                {collaborators.map((collaborator) => (
                  <tr
                    key={collaborator.id}
                    aria-selected={collaborator.id === selectedCollaborator?.id}
                    onClick={() => setSelectedCollaborator(collaborator)}
                  >
                    <td data-label="Name">
                      <div style={{ display: "flex", alignItems: "center", gap: "var(--spacer-4)" }}>
                        <img
                          className="user-avatar"
                          src={collaborator.avatar_url}
                          style={{ width: "var(--spacer-6)" }}
                          alt={`Avatar of ${collaborator.name || "Collaborator"}`}
                        />
                        <div>
                          <span className="whitespace-nowrap">{collaborator.name || "Collaborator"}</span>
                          <small className="line-clamp-1">{collaborator.email}</small>
                        </div>
                        {collaborator.setup_incomplete ? (
                          <WithTooltip tip="Not receiving payouts" position="top">
                            <Icon
                              name="solid-shield-exclamation"
                              style={{ color: "rgb(var(--warning))" }}
                              aria-label="Not receiving payouts"
                            />
                          </WithTooltip>
                        ) : null}
                      </div>
                    </td>
                    <td data-label="Products">
                      <span className="line-clamp-2">{formatProductNames(collaborator)}</span>
                    </td>
                    <td data-label="Cut" className="whitespace-nowrap">
                      {formatCommission(collaborator)}
                    </td>
                    <td data-label="Status" className="whitespace-nowrap">
                      {collaborator.invitation_accepted ? <>Accepted</> : <>Pending</>}
                    </td>
                    <td>
                      <div className="actions" onClick={(e) => e.stopPropagation()}>
                        <Link
                          to={`/collaborators/${collaborator.id}/edit`}
                          className="button"
                          aria-label="Edit"
                          inert={!loggedInUser?.policies.collaborator.update || navigation.state !== "idle"}
                        >
                          <Icon name="pencil" />
                        </Link>

                        <Button
                          type="submit"
                          color="danger"
                          onClick={() => remove(collaborator.id)}
                          aria-label="Delete"
                          disabled={!loggedInUser?.policies.collaborator.update || navigation.state !== "idle"}
                        >
                          <Icon name="trash2" />
                        </Button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </section>
          {selectedCollaborator ? (
            <CollaboratorDetails
              selectedCollaborator={selectedCollaborator}
              onClose={() => setSelectedCollaborator(null)}
              onRemove={remove}
            />
          ) : null}
        </>
      ) : (
        <section className="p-4 md:p-8">
          <div className="placeholder">
            <figure>
              <img src={placeholder} />
            </figure>
            <h2>No collaborators yet</h2>
            <h4>Share your revenue with the people who helped create your products.</h4>
            <a href="/help/article/341-collaborations" target="_blank" rel="noreferrer">
              Learn more about collaborators
            </a>
          </div>
        </section>
      )}
    </Layout>
  );
};

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
        <section className="!p-8">
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
          <h4 style={{ marginBottom: "var(--spacer-3)" }}>
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
          <div style={{ display: "flex", justifyContent: "space-between", gap: "var(--spacer-3)" }}>
            <Button style={{ flexGrow: 1 }} onClick={() => setIsConfirmationModalOpen(false)}>
              No, cancel
            </Button>
            <Button
              color="primary"
              style={{ flexGrow: 1 }}
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

const CollaboratorsPage = () => {
  const router = createBrowserRouter([
    {
      path: "/collaborators",
      element: <Collaborators />,
      loader: async () => json(await getCollaborators(), { status: 200 }),
    },
    {
      path: "/collaborators/new",
      element: <CollaboratorForm />,
      loader: async () => json(await getNewCollaborator(), { status: 200 }),
    },
    {
      path: "/collaborators/:collaboratorId/edit",
      element: <CollaboratorForm />,
      loader: async ({ params }) => {
        const collaborator = await getEditCollaborator(
          assertDefined(params.collaboratorId, "Collaborator ID is required"),
        );
        if (!collaborator) return redirect("/collaborators");
        return json(collaborator, { status: 200 });
      },
    },
    {
      path: Routes.collaborators_incomings_path(),
      element: <IncomingCollaborators />,
      loader: async () => json(await getIncomingCollaborators(), { status: 200 }),
    },
  ]);

  return <RouterProvider router={router} />;
};

export default CollaboratorsPage;
