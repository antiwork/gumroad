import React from "react";

import DeleteAction from "$app/components/Admin/Products/Actions/DeleteAction";
import JoinDiscordAction from "$app/components/Admin/Products/Actions/JoinDiscordAction";
import MakeAdultAction from "$app/components/Admin/Products/Actions/MakeAdultAction";
import MarkAsStaffPickedAction from "$app/components/Admin/Products/Actions/MarkAsStaffPickedAction";
import PublishAction from "$app/components/Admin/Products/Actions/PublishAction";
import UnmarkAsStaffPickedAction from "$app/components/Admin/Products/Actions/UnmarkAsStaffPickedAction";
import { type Product } from "$app/components/Admin/Products/Product";

type AdminProductActionsProps = {
  product: Product;
};

const AdminProductActions = ({ product }: AdminProductActionsProps) => (
  <>
    <hr />
    <div className="button-group">
      <PublishAction product={product} />
      <DeleteAction product={product} />
      <MakeAdultAction product={product} />
      <MarkAsStaffPickedAction product={product} />
      <UnmarkAsStaffPickedAction product={product} />
      <JoinDiscordAction product={product} />
    </div>
  </>
);

export default AdminProductActions;
