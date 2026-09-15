import * as React from "react";
import { createRoot } from "react-dom/client";

import BankAccountSection from "$app/components/Settings/PaymentsPage/BankAccountSection";
import type { BankAccount, BankAccountDetails } from "$app/components/Settings/PaymentsPage/BankAccountSection";
import type { User } from "$app/types/payments";

const bankAccountDetails: BankAccountDetails = {
  show_bank_account: true,
  show_paypal: false,
  is_a_card: false,
  routing_number: null,
  account_number_visual: null,
  card: null,
  card_data_handling_mode: null,
  bank_account: null,
};

const makeUser = (countryCode: string, supportsIban = false): User => ({
  country_supports_native_payouts: true,
  no_payout_rail_in_country: false,
  country_supports_iban: supportsIban,
  need_full_ssn: false,
  country_code: countryCode,
  payout_currency: "usd",
  is_from_europe: false,
  individual_tax_id_needed_countries: [],
  individual_tax_id_entered: false,
  individual_tax_id_last_four: null,
  individual_tax_id_is_last_four: false,
  has_outstanding_full_ssn_requirement: false,
  business_tax_id_entered: false,
  business_tax_id_last_four: null,
  requires_credit_card: false,
  is_charged_paypal_payout_fee: false,
  joined_at: "2026-01-01",
});

const Section = ({ country, label }: { country: string; label: string }) => {
  const [bankAccount, setBankAccount] = React.useState<Partial<BankAccount> | null>(null);
  return (
    <div className="border-b border-black/10 p-6">
      <h2 className="mb-4 text-lg font-bold">{label}</h2>
      <BankAccountSection
        bankAccountDetails={bankAccountDetails}
        bankAccount={bankAccount}
        updateBankAccount={(next) => setBankAccount((prev) => ({ ...prev, ...next }))}
        hasConnectedStripe={false}
        user={makeUser(country)}
        isFormDisabled={false}
        feeInfoText=""
        showNewBankAccount
        setShowNewBankAccount={() => {}}
        errorFieldNames={new Set()}
      />
    </div>
  );
};

const App = () => (
  <div>
    <Section country="BD" label="Bangladesh (BD)" />
    <Section country="NZ" label="New Zealand (NZ)" />
    <Section country="OM" label="Oman (OM)" />
    <Section country="PE" label="Peru (PE)" />
  </div>
);

const container = document.getElementById("root");
if (container) createRoot(container).render(<App />);
