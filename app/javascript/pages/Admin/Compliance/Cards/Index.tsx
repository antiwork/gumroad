import { usePage } from "@inertiajs/react";
import React from "react";

import CardsPage from "$app/components/Admin/Compliance/CardsPage";
import { type Purchase } from "$app/components/Admin/Purchase";

const AdminComplianceCardsIndex = () => {
  const { purchases } = usePage<{ purchases: Purchase[] }>().props;

  return <CardsPage purchases={purchases} />;
};

export default AdminComplianceCardsIndex;
