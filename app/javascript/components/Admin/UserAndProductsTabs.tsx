import { Link } from "@inertiajs/react";
import React from "react";

import { Tab, Tabs } from "$app/components/ui/Tabs";

type Props = {
  selectedTab: string;
  userId: number;
};

const AdminUserAndProductsTabs = ({ selectedTab, userId }: Props) => (
  <Tabs variant="buttons">
    <Tab isSelected={selectedTab === "users"} variant="buttons" asChild>
      <Link href={Routes.admin_user_path(userId)}>Profile</Link>
    </Tab>
    <Tab isSelected={selectedTab === "products"} variant="buttons" asChild>
      <Link href={Routes.admin_user_products_path(userId)} prefetch>
        Products
      </Link>
    </Tab>
  </Tabs>
);

export default AdminUserAndProductsTabs;
