import * as React from "react";

import { TaxesCollectionModal } from "$app/components/server-components/TaxesCollectionModal";
import { Alert } from "$app/components/ui/Alert";

export type AusBacktaxDetails = {
  total_amount_to_au: string;
  au_backtax_amount: string;
  credit_creation_date: string;
  opt_in_date: string | null;
  opted_in_to_au_backtax: boolean;
  legal_entity_name: string | null;
  are_au_backtaxes_paid: boolean;
  au_backtaxes_paid_date: string | null;
};

const AusBackTaxesSection = ({
  total_amount_to_au,
  au_backtax_amount,
  credit_creation_date,
  opt_in_date,
  opted_in_to_au_backtax,
  legal_entity_name,
  are_au_backtaxes_paid,
  au_backtaxes_paid_date,
}: AusBacktaxDetails) => (
  <section>
    <header>
      <h2>Backtaxes collection</h2>
    </header>
    <div>
      {opted_in_to_au_backtax ? (
        <div className="flex flex-col gap-4">
          <Alert variant="success">You've opted in to backtaxes collection.</Alert>
          <p>
            From 2018 to 2022, you made {total_amount_to_au} in sales to customers located in Australia. Taxes on these
            sales were not collected at the time.{" "}
            <b>
              The Australian government is requiring that we go back to collect and remit these back taxes. Going
              forward, we will collect and remit these taxes on your behalf.
            </b>
          </p>
          {are_au_backtaxes_paid ? (
            <p>
              A negative credit in the amount of {au_backtax_amount} was applied to your account on{" "}
              {au_backtaxes_paid_date || ""}. You opted in on {opt_in_date || ""}. <b>No further action is required.</b>
            </p>
          ) : (
            <p>
              A negative credit in the amount of {au_backtax_amount} will be applied to your account on{" "}
              {credit_creation_date}. You opted in on {opt_in_date || ""}. <b>No further action is required.</b>
            </p>
          )}
        </div>
      ) : (
        <div className="flex flex-col gap-4">
          <Alert variant="warning">
            The Australian government is claiming taxes for your sales between 2018 to 2022.
          </Alert>
          <p>
            From 2018 to 2022, you made {total_amount_to_au} in sales to customers located in Australia. Taxes on these
            sales were not collected at the time.{" "}
            <b>
              The Australian government is requiring that we go back to collect and remit these back taxes. Going
              forward, we will collect and remit these taxes on your behalf.
            </b>
          </p>
          <p>For your sales, the total amount of back taxes owed is {au_backtax_amount}.</p>
          <TaxesCollectionModal
            taxesOwed={au_backtax_amount}
            creditCreationDate={credit_creation_date}
            name={legal_entity_name}
          />
        </div>
      )}
    </div>
  </section>
);
export default AusBackTaxesSection;
