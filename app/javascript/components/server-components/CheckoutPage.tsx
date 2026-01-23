import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import {
  CheckoutPageContent,
  CrossSellModal,
  UpsellModal,
  type Props,
  type Result,
} from "$app/components/Checkout/CheckoutPageContent";

export type { Props, Result };
export { CrossSellModal, UpsellModal };

export const CheckoutPage = (props: Props) => <CheckoutPageContent {...props} />;

export default register({ component: CheckoutPage, propParser: createCast() });
