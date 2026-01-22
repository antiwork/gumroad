import React from "react";

export type ProductPurchase = {
  email: string;
  created: string;
  external_id: string;
  amount: number;
  displayed_price: string;
  formatted_gumroad_tax_amount: string;
  is_preorder_authorization: boolean;
  stripe_refunded: boolean | null;
  is_chargedback: boolean;
  is_chargeback_reversed: boolean;
  refunded_by: { external_id: string; email: string }[];
  error_code: string | null;
  purchase_state: string;
  gumroad_responsible_for_tax: boolean;
  className?: string;
};

const AdminProductPurchase = ({
  purchase: {
    external_id,
    displayed_price,
    gumroad_responsible_for_tax,
    formatted_gumroad_tax_amount,
    purchase_state,
    error_code,
    is_preorder_authorization,
    stripe_refunded,
    refunded_by,
    is_chargedback,
    is_chargeback_reversed,
    email,
    created,
    className,
  },
  isSelected,
  onToggleSelection,
}: {
  purchase: ProductPurchase;
  isSelected: boolean;
  onToggleSelection: (purchaseId: string, selected: boolean) => void;
}) => {
  const isSelectable = stripe_refunded !== true;

  return (
    <div className={className}>
      <div className="flex grow items-start gap-2">
        <input
          type="checkbox"
          aria-label={`Select purchase ${external_id}`}
          checked={isSelected}
          onChange={(event) => onToggleSelection(external_id, event.target.checked)}
          disabled={!isSelectable}
          title={isSelectable ? undefined : "Already refunded"}
        />
        <div>
          <h5>
            <a href={Routes.admin_purchase_path(external_id)}>{displayed_price}</a>
            {gumroad_responsible_for_tax ? ` + ${formatted_gumroad_tax_amount} VAT` : null}
          </h5>
          <small>
            <ul className="inline">
              <li>{purchase_state}</li>
              {error_code ? <li>{error_code}</li> : null}
              {is_preorder_authorization ? <li>(pre-order auth)</li> : null}
              {stripe_refunded ? (
                <li>
                  (refunded
                  {refunded_by.map((refunder) => (
                    <React.Fragment key={refunder.external_id}>
                      {" "}
                      by <a href={Routes.admin_user_path(refunder.external_id)}>{refunder.email}</a>
                    </React.Fragment>
                  ))}
                  )
                </li>
              ) : null}
              {is_chargedback ? <li>(chargeback)</li> : null}
              {is_chargeback_reversed ? <li>(chargeback_reversed)</li> : null}
            </ul>
          </small>
        </div>
      </div>
      <div className="text-right">
        <a href={Routes.admin_search_purchases_path({ query: email })}>{email}</a>
        <small>{created}</small>
      </div>
    </div>
  );
};

export default AdminProductPurchase;
