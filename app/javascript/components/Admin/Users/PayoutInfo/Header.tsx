import React from "react";

import { NoIcon } from "$app/components/Admin/Icons";

import { type ActiveBankAccountProps } from "./PayoutInfo";

type HeaderProps = {
  active_bank_account: ActiveBankAccountProps | null;
  payment_address: string | null;
};

const Header = ({ active_bank_account, payment_address }: HeaderProps) => {
  if (active_bank_account) {
    return (
      <div>
        {active_bank_account.type} / {active_bank_account.account_holder_full_name} /{" "}
        {active_bank_account.formatted_account}
      </div>
    );
  }
  if (payment_address) {
    return <div>PayPal / {payment_address}</div>;
  }
  return (
    <div>
      <NoIcon /> This user has no payout method
    </div>
  );
};

export default Header;
