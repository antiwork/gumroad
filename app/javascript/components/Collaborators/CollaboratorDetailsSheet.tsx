import * as React from "react";

import type { Collaborator } from "$app/data/collaborators";
import type { IncomingCollaborator } from "$app/data/incoming_collaborators";
import { formatAsPercent } from "$app/utils/collaboratorFormatters";

import { Alert } from "$app/components/ui/Alert";
import { Sheet, SheetHeader } from "$app/components/ui/Sheet";

type CollaboratorDetailsSheetProps = {
  collaborator: Collaborator | IncomingCollaborator;
  onClose: () => void;
  actions: React.ReactNode;
  showSetupWarning?: boolean;
};

const CollaboratorDetailsSheet = ({
  collaborator,
  onClose,
  actions,
  showSetupWarning = false,
}: CollaboratorDetailsSheetProps) => {
  const isIncoming = "seller_name" in collaborator;

  return (
    <Sheet open onOpenChange={onClose}>
      <SheetHeader>{isIncoming ? collaborator.seller_name : (collaborator.name ?? "Collaborator")}</SheetHeader>
      {showSetupWarning ? (
        <Alert variant="warning">
          Collaborators won't receive their cut until they set up a payout account in their Gumroad settings.
        </Alert>
      ) : null}

      <section className="stack">
        <h3>Email</h3>
        <div>
          <span>{isIncoming ? collaborator.seller_email : collaborator.email}</span>
        </div>
      </section>

      <section className="stack">
        <h3>Products</h3>
        {collaborator.products.map((product) => {
          const productName = product.name;

          return (
            <section key={product.id}>
              {isIncoming ? (
                <a href={"url" in product ? product.url : "#"} target="_blank" rel="noreferrer">
                  {productName}
                </a>
              ) : (
                <div>{productName}</div>
              )}
              <div>{formatAsPercent(product.percent_commission)}</div>
            </section>
          );
        })}
      </section>

      <section className="mt-auto flex gap-4">{actions}</section>
    </Sheet>
  );
};

export default CollaboratorDetailsSheet;
