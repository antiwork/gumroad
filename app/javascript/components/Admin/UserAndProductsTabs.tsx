import { Link } from "@inertiajs/react";
import React from "react";

import Tab from "$app/components/Admin/Tabs/Tab";
import TabList from "$app/components/Admin/Tabs/TabList";

type Props = {
  selectedTab: string;
  userId: number;
};

const AdminUserAndProductsTabs = ({ selectedTab, userId }: Props) => (
  <TabList>
    <Tab isSelected={selectedTab === "users"} asChild>
      <Link href={Routes.admin_user_path(userId)} className="block p-3 no-underline">
        Profile
      </Link>
    </Tab>
    <Tab isSelected={selectedTab === "products"} asChild>
      <Link href={Routes.admin_user_products_path(userId)} prefetch className="block p-3 no-underline">
        Products
      </Link>
    </Tab>
  </TabList>
);

export default AdminUserAndProductsTabs;
