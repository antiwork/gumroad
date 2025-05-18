import ReactOnRails from "react-on-rails";

import "./admin";

import AdminActionButton from "$app/components/server-components/Admin/ActionButton";
import AdminAddCommentForm from "$app/components/server-components/Admin/AddCommentForm";
import AdminProductAttributesAndInfo from "$app/components/server-components/Admin/ProductAttributesAndInfo";
import AdminProductPurchases from "$app/components/server-components/Admin/ProductPurchases";
import AdminProductStats from "$app/components/server-components/Admin/ProductStats";
import AdminUserGuids from "$app/components/server-components/Admin/UserGuids";
import AdminUserStats from "$app/components/server-components/Admin/UserStats";

ReactOnRails.register({
  AdminActionButton,
  AdminAddCommentForm,
  AdminProductAttributesAndInfo,
  AdminProductPurchases,
  AdminProductStats,
  AdminUserGuids,
  AdminUserStats,
});
