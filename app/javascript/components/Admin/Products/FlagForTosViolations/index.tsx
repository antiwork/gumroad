import React from "react";
import { cast } from "ts-safe-cast";

import { useLazyFetch } from "$app/hooks/useLazyFetch";

import AdminFlagForTosViolationsForm from "$app/components/Admin/Products/FlagForTosViolations/Form";
import AdminFlagForTosViolationsContent, {
  type TosViolationFlags,
} from "$app/components/Admin/Products/FlagForTosViolations/Content";
import type { Product } from "$app/components/Admin/Products/Product";
import type { User } from "$app/components/Admin/Users/User";

export type Compliance = {
  reasons: Record<string, string>;
  default_reason: string;
};

type FlagForTosViolationsProps = {
  user: User;
  product: Product;
  compliance: Compliance;
};

const FlagForTosViolations = ({ user, product, compliance }: FlagForTosViolationsProps) => {
  const [open, setOpen] = React.useState(false);
  const [flaggedForTosViolation, setFlaggedForTosViolation] = React.useState(user.flagged_for_tos_violation);

  const {
    data: tos_violation_flags,
    isLoading,
    fetchData: fetchTosViolationFlags,
  } = useLazyFetch<TosViolationFlags[]>([], {
    fetchUnlessLoaded: open,
    url: Routes.admin_user_product_tos_violation_flags_path(user.id, product.id, { format: "json" }),
    responseParser: (data) => {
      const parsed = cast<{ tos_violation_flags: TosViolationFlags[] }>(data);
      return parsed.tos_violation_flags;
    },
  });

  const fetchIfFlagged = () => {
    if (flaggedForTosViolation) {
      void fetchTosViolationFlags();
    }
  };

  React.useEffect(() => {
    fetchIfFlagged();
  }, [flaggedForTosViolation]);

  const onToggle = (e: React.MouseEvent<HTMLDetailsElement>) => {
    setOpen(e.currentTarget.open);
    if (e.currentTarget.open) {
      fetchIfFlagged();
    }
  };

  const suspendTosSuccessMessage = `User was flagged for TOS violation and product ${product.is_tiered_membership ? "unpublished" : "deleted"}.`;
  const suspendTosConfirmMessage = `Are you sure you want to flag the user and ${product.is_tiered_membership ? "unpublish" : "delete"} the product?`;
  const shouldShowForm = !flaggedForTosViolation && product.alive && !user.suspended && !user.flagged_for_tos_violation;

  return (
    <>
      <hr />
      <details open={open} onToggle={onToggle}>
        <summary>
          <h3>Flag for TOS violation</h3>
        </summary>
        { shouldShowForm ? <AdminFlagForTosViolationsForm
          user_id={user.id}
          product_id={product.id}
          success_message={suspendTosSuccessMessage}
          confirm_message={suspendTosConfirmMessage}
          reasons={compliance.reasons}
          default_reason={compliance.default_reason}
          onSuccess={() => setFlaggedForTosViolation(true)}
        /> : null }

        <AdminFlagForTosViolationsContent
          isLoading={isLoading}
          tosViolationFlags={tos_violation_flags}
        />
      </details>
    </>
  );
};

export default FlagForTosViolations;
