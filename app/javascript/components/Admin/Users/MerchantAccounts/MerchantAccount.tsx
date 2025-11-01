import { Link } from "@inertiajs/react";
import React from "react";

import { YesIcon, NoIcon } from "$app/components/Icons";

export type MerchantAccountProps = {
  id: number;
  charge_processor_id: string;
  alive: boolean;
  charge_processor_alive: boolean;
};

const MerchantAccount = ({ id, charge_processor_id, alive, charge_processor_alive }: MerchantAccountProps) => (
  <li>
    <Link href={Routes.admin_merchant_account_path(id)}>
      {id} - {charge_processor_id}
    </Link>
    {alive && charge_processor_alive ? <YesIcon /> : <NoIcon />}
  </li>
);

export default MerchantAccount;
