import * as React from "react";
import * as ReactDOM from "react-dom";
import {
  RouterProvider,
  createBrowserRouter,
  json,
  Link,
  redirect,
  useNavigation,
  useLoaderData,
  useRevalidator,
} from "react-router-dom";
import { cast } from "ts-safe-cast";

import {
  getCollaborators,
  getEditCollaborator,
  getNewCollaborator,
  Collaborator,
  CollaboratorsData,
  removeCollaborator,
} from "$app/data/collaborators";
import { getIncomingCollaborators } from "$app/data/incoming_collaborators";
import { assertDefined } from "$app/utils/assert";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import CollaboratorForm from "$app/components/Collaborators/Form";
import { IncomingCollaborators } from "$app/components/Collaborators/IncomingCollaborators";
import { Layout } from "$app/components/Collaborators/Layout";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { showAlert } from "$app/components/server-components/Alert";
import Placeholder from "$app/components/ui/Placeholder";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/collaborators.png";

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
    <aside className="flex! flex-col!">
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
          to={`/collaborators/${selectedCollaborator.id}/edit`}
          className="button flex-1"
          aria-label="Edit"
          inert={!loggedInUser?.policies.collaborator.update || navigation.state !== "idle"}
        >
          Edit
        </Link>
        <Button
          className="flex-1"
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
                      <div className="flex items-center gap-4">
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
          <Placeholder>
            <figure>
              <img src={placeholder} />
            </figure>
            <h2>No collaborators yet</h2>
            <h4>Share your revenue with the people who helped create your products.</h4>
            <a href="/help/article/341-collaborations" target="_blank" rel="noreferrer">
              Learn more about collaborators
            </a>
          </Placeholder>
        </section>
      )}
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
