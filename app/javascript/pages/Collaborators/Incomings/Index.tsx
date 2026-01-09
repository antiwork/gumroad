import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import type { CollaboratorPagesSharedProps } from "$app/data/collaborators";
import type { IncomingCollaborator } from "$app/data/incoming_collaborators";
import { classNames } from "$app/utils/classNames";
import { formatCommission, formatProductNames } from "$app/utils/collaboratorFormatters";

import { Button } from "$app/components/Button";
import CollaboratorDetailsSheet from "$app/components/Collaborators/CollaboratorDetailsSheet";
import { Layout } from "$app/components/Collaborators/Layout";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { showAlert } from "$app/components/server-components/Alert";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/collaborators.png";

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
  <TableRow key={incomingCollaborator.id} selected={isSelected} onClick={onSelect}>
    <TableCell>
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
    </TableCell>
    <TableCell>
      <span className="line-clamp-2">{formatProductNames(incomingCollaborator)}</span>
    </TableCell>
    <TableCell className="whitespace-nowrap">{formatCommission(incomingCollaborator)}</TableCell>
    <TableCell className="whitespace-nowrap">
      {incomingCollaborator.invitation_accepted ? <>Accepted</> : <>Pending</>}
    </TableCell>
    <TableCell>
      {incomingCollaborator.invitation_accepted ? null : (
        <div className="flex flex-wrap gap-3 lg:justify-end" onClick={(e) => e.stopPropagation()}>
          <Button type="submit" aria-label="Accept" onClick={onAccept} disabled={disabled}>
            <Icon name="outline-check" />
          </Button>
          <Button type="submit" color="danger" aria-label="Decline" onClick={onReject} disabled={disabled}>
            <Icon name="x" />
          </Button>
        </div>
      )}
    </TableCell>
  </TableRow>
);

const EmptyState = () => (
  <section className="p-4 md:p-8">
    <Placeholder>
      <PlaceholderImage src={placeholder} />
      <h2>No collaborations yet</h2>
      <h4>Creators who have invited you to collaborate on their products will appear here.</h4>
      <a href="/help/article/341-collaborations" target="_blank" rel="noreferrer">
        Learn more about collaborations
      </a>
    </Placeholder>
  </section>
);

const IncomingCollaboratorsTable = ({
  incomingCollaborators,
  selected,
  disabled,
  onSelect,
  onAccept,
  onReject,
  onRemove,
}: {
  incomingCollaborators: IncomingCollaborator[];
  selected: IncomingCollaborator | null;
  disabled: boolean;
  onSelect: (collaborator: IncomingCollaborator | null) => void;
  onAccept: (collaborator: IncomingCollaborator) => void;
  onReject: (collaborator: IncomingCollaborator) => void;
  onRemove: (collaborator: IncomingCollaborator) => void;
}) => (
  <section className="p-4 md:p-8">
    <Table aria-live="polite" className={classNames(disabled && "pointer-events-none opacity-50")}>
      <TableHeader>
        <TableRow>
          <TableHead>From</TableHead>
          <TableHead>Products</TableHead>
          <TableHead>Your cut</TableHead>
          <TableHead>Status</TableHead>
          <TableHead />
        </TableRow>
      </TableHeader>

      <TableBody>
        {incomingCollaborators.map((incomingCollaborator) => (
          <IncomingCollaboratorsTableRow
            key={incomingCollaborator.id}
            incomingCollaborator={incomingCollaborator}
            isSelected={incomingCollaborator.id === selected?.id}
            onSelect={() => onSelect(incomingCollaborator)}
            onAccept={() => onAccept(incomingCollaborator)}
            onReject={() => onReject(incomingCollaborator)}
            disabled={disabled}
          />
        ))}
      </TableBody>
    </Table>
    {selected ? (
      <CollaboratorDetailsSheet
        collaborator={selected}
        onClose={() => onSelect(null)}
        actions={
          selected.invitation_accepted ? (
            <Button
              className="flex-1"
              aria-label="Remove"
              color="danger"
              disabled={disabled}
              onClick={() => onRemove(selected)}
            >
              Remove
            </Button>
          ) : (
            <>
              <Button className="flex-1" aria-label="Accept" onClick={() => onAccept(selected)} disabled={disabled}>
                Accept
              </Button>
              <Button
                className="flex-1"
                color="danger"
                aria-label="Decline"
                onClick={() => onReject(selected)}
                disabled={disabled}
              >
                Decline
              </Button>
            </>
          )
        }
      />
    ) : null}
  </section>
);

type IncomingCollaboratorsPageProps = {
  collaborators: IncomingCollaborator[];
} & CollaboratorPagesSharedProps;

const IncomingCollaboratorsPage = () => {
  const loggedInUser = useLoggedInUser();

  const { collaborators: incomingCollaborators, collaborators_disabled_reason } = cast<IncomingCollaboratorsPageProps>(
    usePage().props,
  );

  const [selected, setSelected] = React.useState<IncomingCollaborator | null>(null);

  const form = useForm({});

  return (
    <Layout
      title="Collaborators"
      selectedTab="collaborations"
      showTabs
      headerActions={
        <WithTooltip position="bottom" tip={collaborators_disabled_reason}>
          <NavigationButtonInertia
            href={Routes.new_collaborator_path()}
            color="accent"
            disabled={
              !loggedInUser?.policies.collaborator.create || collaborators_disabled_reason !== null || form.processing
            }
          >
            Add collaborator
          </NavigationButtonInertia>
        </WithTooltip>
      }
    >
      {incomingCollaborators.length === 0 ? (
        <EmptyState />
      ) : (
        <IncomingCollaboratorsTable
          incomingCollaborators={incomingCollaborators}
          selected={selected}
          disabled={form.processing}
          onSelect={(collaborator) => setSelected(collaborator)}
          onAccept={(incomingCollaborator) =>
            form.post(Routes.accept_collaborators_incoming_path(incomingCollaborator.id), {
              only: ["collaborators", "flash"],
            })
          }
          onReject={(incomingCollaborator) =>
            form.post(Routes.decline_collaborators_incoming_path(incomingCollaborator.id), {
              only: ["collaborators", "flash"],
            })
          }
          onRemove={(incomingCollaborator) =>
            form.delete(Routes.collaborators_incoming_path(incomingCollaborator.id), {
              only: ["collaborators", "flash"],
              onSuccess: () => setSelected(null),
              onError: () => showAlert("Sorry, something went wrong. Please try again.", "error"),
            })
          }
        />
      )}
    </Layout>
  );
};

export default IncomingCollaboratorsPage;
