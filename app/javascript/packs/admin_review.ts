import ReactOnRails from "react-on-rails";

import "./admin";

import AdminActionButton from "$app/components/server-components/Admin/ActionButton";
import AdminAddCommentForm from "$app/components/server-components/Admin/AddCommentForm";
import AdminAddCreditForm from "$app/components/server-components/Admin/AddCreditForm";
import AdminChangeEmailForm from "$app/components/server-components/Admin/ChangeEmailForm";
import AdminFlagForFraudForm from "$app/components/server-components/Admin/FlagForFraudForm";
import AdminManualPayoutForm from "$app/components/server-components/Admin/ManualPayoutForm";
import AdminMassTransferPurchasesForm from "$app/components/server-components/Admin/MassTransferPurchasesForm";
import AdminPausePayoutsForm from "$app/components/server-components/Admin/PausePayoutsForm";
import AdminProductAttributesAndInfo from "$app/components/server-components/Admin/ProductAttributesAndInfo";
import AdminProductPurchases from "$app/components/server-components/Admin/ProductPurchases";
import AdminProductStats from "$app/components/server-components/Admin/ProductStats";
import AdminResendReceiptForm from "$app/components/server-components/Admin/ResendReceiptForm";
import AdminSetCustomFeeForm from "$app/components/server-components/Admin/SetCustomFeeForm";
import AdminSuspendForFraudForm from "$app/components/server-components/Admin/SuspendForFraudForm";
import AdminSuspendForTosForm from "$app/components/server-components/Admin/SuspendForTosForm";
import AdminUserGuids from "$app/components/server-components/Admin/UserGuids";
import AdminUserStats from "$app/components/server-components/Admin/UserStats";

ReactOnRails.register({
  AdminActionButton,
  AdminAddCommentForm,
  AdminChangeEmailForm,
  AdminFlagForFraudForm,
  AdminManualPayoutForm,
  AdminMassTransferPurchasesForm,
  AdminPausePayoutsForm,
  AdminProductAttributesAndInfo,
  AdminProductPurchases,
  AdminProductStats,
  AdminResendReceiptForm,
  AdminSetCustomFeeForm,
  AdminSuspendForFraudForm,
  AdminSuspendForTosForm,
  AdminUserGuids,
  AdminUserStats,
  AdminAddCreditForm,
});
