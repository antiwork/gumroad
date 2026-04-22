import React from "react";

import { Card, CardContent } from "$app/components/ui/Card";

const SCOPES = [
  {
    name: "account",
    description: "full access to all API endpoints.",
  },
  {
    name: "view_profile",
    description: "read-only access to the user's public information and products.",
  },
  {
    name: "edit_products",
    description:
      "read/write access to the user's products and their variants, offer codes, custom fields, and files.",
  },
  {
    name: "view_sales",
    description:
      "read access to the user's products' sales information, including sales counts. This scope is also required in order to subscribe to the user's sales.",
  },
  {
    name: "view_payouts",
    description: "read access to the user's payouts information.",
  },
  {
    name: "view_tax_data",
    description: "read access to the user's tax forms (1099-K, 1099-MISC) and annual earnings summary.",
  },
  {
    name: "mark_sales_as_shipped",
    description: "write access to mark the user's products' sales as shipped.",
  },
  {
    name: "edit_sales",
    description: "write access to refund the user's products' sales and resend purchase receipts to customers.",
  },
];

export const Scopes = () => (
  <Card id="api-scopes">
    <CardContent>
      <h2 className="grow">Scopes</h2>
    </CardContent>
    <CardContent>
      <div className="flex grow flex-col gap-4">
        <p>We've provided the following scopes that you may request when the user authorizes your application.</p>
        <div className="api-list">
          {SCOPES.map((scope) => (
            <React.Fragment key={scope.name}>
              <strong>{scope.name}:</strong> {scope.description}
              <br />
            </React.Fragment>
          ))}
        </div>
      </div>
    </CardContent>
  </Card>
);
