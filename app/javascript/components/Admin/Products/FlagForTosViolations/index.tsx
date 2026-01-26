import React from "react";
import { cast } from "ts-safe-cast";

import { useLazyFetch } from "$app/hooks/useLazyFetch";

import AdminFlagForTosViolationsContent, {
  type TosViolationFlags,
} from "$app/components/Admin/Products/FlagForTosViolations/Content";
import AdminFlagForTosViolationsForm from "$app/components/Admin/Products/FlagForTosViolations/Form";
import type { Product } from "$app/components/Admin/Products/Product";

export type Compliance = {
  reasons: Record<string, string>;
  default_reason: string;
};

type FlagForTosViolationsProps = {
  product: Product;
  compliance: Compliance;
};

const FlagForTosViolations = ({ product, compliance }: FlagForTosViolationsProps) => {
  const [open, setOpen] = React.useState(false);
  const [flaggedForTosViolation, setFlaggedForTosViolation] = React.useState(product.user.flagged_for_tos_violation);

  const {
    data: tos_violation_flags,
    isLoading,
    fetchData: fetchTosViolationFlags,
  } = useLazyFetch<TosViolationFlags[]>([], {
    fetchUnlessLoaded: open,
    url: Routes.admin_user_product_tos_violation_flags_path(product.user.external_id, product.external_id, {
      format: "json",
    }),
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
  const shouldShowForm =
    !flaggedForTosViolation && product.alive && !product.user.suspended && !product.user.flagged_for_tos_violation;

  return (
    <>
      <hr />
      <details open={open} onToggle={onToggle}>
        <summary>
          <h3>Flag for TOS violation</h3>
        </summary>
        {shouldShowForm ? (
          <AdminFlagForTosViolationsForm
            user_external_id={product.user.external_id}
            product_external_id={product.external_id}
            success_message={suspendTosSuccessMessage}
            confirm_message={suspendTosConfirmMessage}
            reasons={compliance.reasons}
            default_reason={compliance.default_reason}
            onSuccess={() => setFlaggedForTosViolation(true)}
          />
        ) : null}

        <AdminFlagForTosViolationsContent isLoading={isLoading} tosViolationFlags={tos_violation_flags} />
      </details>
    </>
  );
};

export default FlagForTosViolations;
