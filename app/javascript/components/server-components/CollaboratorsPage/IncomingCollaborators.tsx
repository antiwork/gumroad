import * as React from "react";
import ReactDOM from "react-dom";
import { Link, useLoaderData, useNavigation } from "react-router-dom";
import { cast } from "ts-safe-cast";

import {
  acceptCollaboratorInvitation,
  declineCollaboratorInvitation,
  removeCollaborator,
} from "$app/data/collaborators";
import { IncomingCollaborator, IncomingCollaboratorsData } from "$app/data/incoming_collaborators";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { showAlert } from "$app/components/server-components/Alert";
import { Layout } from "$app/components/server-components/CollaboratorsPage/Layout";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/collaborators.png";

const formatProductNames = (incomingCollaborator: IncomingCollaborator) => {
  if (incomingCollaborator.products.length === 0) {
    return "None";
  } else if (incomingCollaborator.products.length === 1 && incomingCollaborator.products[0]) {
    return incomingCollaborator.products[0].name;
  }
  return `${incomingCollaborator.products.length.toLocaleString()} products`;
};

const formatAsPercent = (commission: number) => (commission / 100).toLocaleString([], { style: "percent" });

const formatCommission = (incomingCollaborator: IncomingCollaborator) => {
  const sortedCommissions = incomingCollaborator.products
    .map((product) => product.affiliate_percentage)
    .filter(Number)
    .sort((a, b) => a - b);
  const commissions = [...new Set(sortedCommissions)]; // remove duplicates

  if (commissions.length === 0) {
    return formatAsPercent(incomingCollaborator.affiliate_percentage);
  } else if (commissions.length === 1 && commissions[0] !== undefined) {
    return formatAsPercent(commissions[0]);
  } else if (commissions.length > 1) {
    const lowestCommission = commissions[0];
    const highestCommission = commissions[commissions.length - 1];
    if (lowestCommission && highestCommission) {
      return `${formatAsPercent(lowestCommission)} - ${formatAsPercent(highestCommission)}`;
    }
  }

  return formatAsPercent(incomingCollaborator.affiliate_percentage);
};

const IncomingCollaboratorDetails = ({
  selected,
  onClose,
  onAccept,
  onReject,
  onRemove,
  disabled,
}: {
  selected: IncomingCollaborator;
  onClose: () => void;
  onAccept: () => void;
  onReject: () => void;
  onRemove: () => void;
  disabled: boolean;
}) =>
  ReactDOM.createPortal(
    <aside className="flex! flex-col!">
      <header>
        <h2>{selected.seller_name}</h2>
        <button className="close" aria-label="Close" onClick={onClose} />
      </header>

      <section className="stack">
        <h3>Email</h3>
        <div>
          <span>{selected.seller_email}</span>
        </div>
      </section>

      <section className="stack">
        <h3>Products</h3>
        {selected.products.map((product) => (
          <section key={product.id}>
            <a href={product.url} target="_blank" rel="noreferrer">
              {product.name}
            </a>
            <div>{formatAsPercent(product.affiliate_percentage)}</div>
          </section>
        ))}
      </section>

      <section className="mt-auto flex gap-4">
        {selected.invitation_accepted ? (
          <Button className="flex-1" aria-label="Remove" color="danger" disabled={disabled} onClick={onRemove}>
            Remove
          </Button>
        ) : (
          <>
            <Button className="flex-1" aria-label="Accept" onClick={onAccept} disabled={disabled}>
              Accept
            </Button>
            <Button className="flex-1" color="danger" aria-label="Decline" onClick={onReject} disabled={disabled}>
              Decline
            </Button>
          </>
        )}
      </section>
    </aside>,
    document.body,
  );

const IncomingCollaboratorsTableRow = ({
  incomingCollaborator,
  isSelected,
  onSelect,
  onAccept,
  onReject,
  disabled,
}: {
  incomingCollaborator: IncomingCollaborator;
  isSelected: boolean;
  onSelect: () => void;
  onAccept: () => void;
  onReject: () => void;
  disabled: boolean;
}) => (
  <tr key={incomingCollaborator.id} aria-selected={isSelected} onClick={onSelect}>
    <td data-label="Name">
      <div className="flex items-center gap-4">
        <img
          className="user-avatar w-8!"
          src={incomingCollaborator.seller_avatar_url}
          alt={`Avatar of ${incomingCollaborator.seller_name || "Collaborator"}`}
        />
        <div>
          <span className="whitespace-nowrap">{incomingCollaborator.seller_name || "Collaborator"}</span>
          <small className="line-clamp-1">{incomingCollaborator.seller_email}</small>
        </div>
      </div>
    </td>
    <td data-label="Products">
      <span className="line-clamp-2">{formatProductNames(incomingCollaborator)}</span>
    </td>
    <td data-label="Cut" className="whitespace-nowrap">
      {formatCommission(incomingCollaborator)}
    </td>
    <td data-label="Status" className="whitespace-nowrap">
      {incomingCollaborator.invitation_accepted ? <>Accepted</> : <>Pending</>}
    </td>
    <td>
      {incomingCollaborator.invitation_accepted ? null : (
        <div className="actions" onClick={(e) => e.stopPropagation()}>
          <Button type="submit" aria-label="Accept" onClick={onAccept} disabled={disabled}>
            <Icon name="outline-check" />
          </Button>
          <Button type="submit" color="danger" aria-label="Decline" onClick={onReject} disabled={disabled}>
            <Icon name="x" />
          </Button>
        </div>
      )}
    </td>
  </tr>
);

const TableRowLoadingSpinner = () => (
  <tr>
    <td colSpan={4}>
      <div className="flex items-center justify-center py-4">
        <LoadingSpinner width="2em" />
      </div>
    </td>
  </tr>
);

const EmptyState = () => (
  <section className="p-4 md:p-8">
    <div className="placeholder">
      <figure>
        <img src={placeholder} />
      </figure>
      <h2>No collaborations yet</h2>
      <h4>Creators who have invited you to collaborate on their products will appear here.</h4>
      <a href="/help/article/341-collaborations" target="_blank" rel="noreferrer">
        Learn more about collaborations
      </a>
    </div>
  </section>
);

const IncomingCollaboratorsTable = ({
  incomingCollaborators,
  selected,
  processing,
  loading,
  disabled,
  onSelect,
  onAccept,
  onReject,
  onRemove,
}: {
  incomingCollaborators: IncomingCollaborator[];
  selected: IncomingCollaborator | null;
  processing: Set<string>;
  loading: boolean;
  disabled: boolean;
  onSelect: (collaborator: IncomingCollaborator | null) => void;
  onAccept: (collaborator: IncomingCollaborator) => void;
  onReject: (collaborator: IncomingCollaborator) => void;
  onRemove: (collaborator: IncomingCollaborator) => void;
}) => (
  <section className="p-4 md:p-8">
    <table aria-busy={loading || disabled}>
      <thead>
        <tr>
          <th>From</th>
          <th>Products</th>
          <th>Your cut</th>
          <th>Status</th>
          <th />
        </tr>
      </thead>

      <tbody>
        {loading ? (
          <TableRowLoadingSpinner />
        ) : (
          incomingCollaborators.map((incomingCollaborator) => (
            <IncomingCollaboratorsTableRow
              key={incomingCollaborator.id}
              incomingCollaborator={incomingCollaborator}
              isSelected={incomingCollaborator.id === selected?.id}
              onSelect={() => onSelect(incomingCollaborator)}
              onAccept={() => onAccept(incomingCollaborator)}
              onReject={() => onReject(incomingCollaborator)}
              disabled={processing.has(incomingCollaborator.id) || disabled}
            />
          ))
        )}
      </tbody>
    </table>
    {selected ? (
      <IncomingCollaboratorDetails
        selected={selected}
        onClose={() => onSelect(null)}
        onAccept={() => onAccept(selected)}
        onReject={() => onReject(selected)}
        onRemove={() => onRemove(selected)}
        disabled={processing.has(selected.id) || disabled}
      />
    ) : null}
  </section>
);

const pendingCollaboratorsFirst = (a: IncomingCollaborator, b: IncomingCollaborator) => {
  const aPriority = a.invitation_accepted ? 0 : 1;
  const bPriority = b.invitation_accepted ? 0 : 1;
  if (aPriority !== bPriority) {
    return bPriority - aPriority;
  }
  return 0;
};

export const IncomingCollaborators = () => {
  const loggedInUser = useLoggedInUser();
  const navigation = useNavigation();

  const { collaborators: initialCollaborators, collaborators_disabled_reason } =
    cast<IncomingCollaboratorsData>(useLoaderData());

  const [incomingCollaborators, setIncomingCollaborators] = React.useState<IncomingCollaborator[]>(
    initialCollaborators.sort(pendingCollaboratorsFirst),
  );
  const [processing, setProcessing] = React.useState<Set<string>>(new Set());
  const [selected, setSelected] = React.useState<IncomingCollaborator | null>(null);
  const [loading, _] = React.useState(false);

  const startProcessing = (incomingCollaborator: IncomingCollaborator) => {
    setProcessing((prev) => {
      const newSet = new Set(prev);
      newSet.add(incomingCollaborator.id);
      return newSet;
    });
  };

  const finishProcessing = (incomingCollaborator: IncomingCollaborator) => {
    setProcessing((prev) => {
      const newSet = new Set(prev);
      newSet.delete(incomingCollaborator.id);
      return newSet;
    });
  };

  const removeIncomingCollaboratorFromList = (incomingCollaborator: IncomingCollaborator) => {
    if (selected?.id === incomingCollaborator.id) {
      setSelected(null);
    }
    setIncomingCollaborators((prev) => prev.filter((i) => i.id !== incomingCollaborator.id));
  };

  const acceptInvitation = async (incomingCollaborator: IncomingCollaborator) => {
    try {
      startProcessing(incomingCollaborator);

      await acceptCollaboratorInvitation(incomingCollaborator.id);
      setIncomingCollaborators((prev) =>
        prev.map((i) => (i.id === incomingCollaborator.id ? { ...i, invitation_accepted: true } : i)),
      );
      // Close the details panel. It's easy to click on "Remove" after
      // accepting as they'll be in the same position.
      setSelected(null);

      showAlert("Invitation accepted", "success");
    } catch (error) {
      assertResponseError(error);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    } finally {
      finishProcessing(incomingCollaborator);
    }
  };

  const declineInvitation = async (incomingCollaborator: IncomingCollaborator) => {
    try {
      startProcessing(incomingCollaborator);
      await declineCollaboratorInvitation(incomingCollaborator.id);
      removeIncomingCollaboratorFromList(incomingCollaborator);
      showAlert("Invitation declined", "success");
    } catch (error) {
      assertResponseError(error);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    } finally {
      finishProcessing(incomingCollaborator);
    }
  };

  const removeIncomingCollaborator = async (incomingCollaborator: IncomingCollaborator) => {
    try {
      startProcessing(incomingCollaborator);
      await removeCollaborator(incomingCollaborator.id);
      removeIncomingCollaboratorFromList(incomingCollaborator);
      showAlert("Collaborator removed", "success");
    } catch (error) {
      assertResponseError(error);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    } finally {
      finishProcessing(incomingCollaborator);
    }
  };

  return (
    <Layout
      title="Collaborators"
      selectedTab="collaborations"
      showTabs
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
      {incomingCollaborators.length === 0 ? (
        <EmptyState />
      ) : (
        <IncomingCollaboratorsTable
          incomingCollaborators={incomingCollaborators}
          selected={selected}
          processing={processing}
          loading={loading}
          disabled={navigation.state !== "idle"}
          onSelect={(collaborator) => setSelected(collaborator)}
          onAccept={(collaborator) => void acceptInvitation(collaborator)}
          onReject={(collaborator) => void declineInvitation(collaborator)}
          onRemove={(collaborator) => void removeIncomingCollaborator(collaborator)}
        />
      )}
    </Layout>
  );
};
