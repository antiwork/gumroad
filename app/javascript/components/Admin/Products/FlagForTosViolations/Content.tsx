import React from "react";

import type { Compliance } from "$app/components/Admin/Products/FlagForTosViolations";
import AdminFlagForTosViolationsForm from "$app/components/Admin/Products/FlagForTosViolations/Form";
import type { Product } from "$app/components/Admin/Products/Product";
import type { User } from "$app/components/Admin/Users/User";
import { LoadingSpinner } from "$app/components/LoadingSpinner";

export type TosViolationFlags = {
  id: number;
  content: string;
};

type FlagForTosViolationsContentProps = {
  user: User;
  product: Product;
  isLoading: boolean;
  flaggedForTosViolation: boolean;
  tosViolationFlags: TosViolationFlags[];
  compliance: Compliance;
  onSuccess: () => void;
};

const FlagForTosViolationsContent = ({
  user,
  product,
  isLoading,
  flaggedForTosViolation,
  tosViolationFlags,
  compliance,
  onSuccess = () => {},
}: FlagForTosViolationsContentProps) => {
  if (!flaggedForTosViolation && product.alive && !user.suspended && !user.flagged_for_tos_violation) {
    const suspendTosSuccessMessage = `User was flagged for TOS violation and product ${product.is_tiered_membership ? "unpublished" : "deleted"}.`;
    const suspendTosConfirmMessage = `Are you sure you want to flag the user and ${product.is_tiered_membership ? "unpublish" : "delete"} the product?`;

    return (
      <AdminFlagForTosViolationsForm
        user_id={user.id}
        product_id={product.id}
        success_message={suspendTosSuccessMessage}
        confirm_message={suspendTosConfirmMessage}
        reasons={compliance.reasons}
        default_reason={compliance.default_reason}
        onSuccess={onSuccess}
      />
    );
  }

  if (isLoading) {
    return <LoadingSpinner />;
  }

  if (tosViolationFlags.length === 0) {
    return <p>No TOS violation flags found</p>;
  }

  return (
    <ul>
      {tosViolationFlags.map(({ id, content }) => (
        <li key={id}>{content}</li>
      ))}
    </ul>
  );
};

export default FlagForTosViolationsContent;
