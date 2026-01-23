import { usePage } from "@inertiajs/react";
import * as React from "react";

import { CheckoutPageContent, type Props as CheckoutProps } from "$app/components/Checkout/CheckoutPageContent";
import { CurrentSellerProvider, parseCurrentSeller } from "$app/components/CurrentSeller";
import { LoggedInUserProvider, parseLoggedInUser, type LoggedInUser } from "$app/components/LoggedInUser";
import Alert from "$app/components/server-components/Alert";
import { useFlashMessage } from "$app/components/useFlashMessage";

type PageProps = CheckoutProps & {
  logged_in_user: LoggedInUser | null;
  current_seller: {
    id: number;
    email: string;
    name: string;
    avatar_url: string;
    has_published_products: boolean;
    subdomain: string;
    is_buyer: boolean;
    time_zone: {
      name: string;
      offset: number;
    };
  } | null;
  flash?: { message: string; status: "success" | "warning" | "danger" } | null;
};

function CheckoutPage() {
  const { logged_in_user, current_seller, flash, ...checkoutProps } = usePage<PageProps>().props;

  useFlashMessage(flash);

  return (
    <LoggedInUserProvider value={parseLoggedInUser(logged_in_user)}>
      <CurrentSellerProvider value={parseCurrentSeller(current_seller)}>
        <Alert initial={null} />
        <CheckoutPageContent {...checkoutProps} />
      </CurrentSellerProvider>
    </LoggedInUserProvider>
  );
}

CheckoutPage.disableLayout = true;
export default CheckoutPage;
