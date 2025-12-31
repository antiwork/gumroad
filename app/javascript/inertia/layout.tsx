import { Head, usePage } from "@inertiajs/react";
import React from "react";

import { classNames } from "$app/utils/classNames";

import { Nav } from "$app/components/client-components/Nav";
import { CurrentSellerProvider, parseCurrentSeller } from "$app/components/CurrentSeller";
import LoadingSkeleton from "$app/components/LoadingSkeleton";
import { type LoggedInUser, LoggedInUserProvider, parseLoggedInUser } from "$app/components/LoggedInUser";
import Alert, { showAlert, type AlertPayload } from "$app/components/server-components/Alert";
import useRouteLoading from "$app/components/useRouteLoading";

type FlashData = {
  notice?: string;
  alert?: string;
  warning?: string;
};

type PageProps = {
  title: string;
  logged_in_user: LoggedInUser;
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
  };
};

// Convert Inertia flash data to AlertPayload format
const flashToAlertPayload = (flash: FlashData): AlertPayload | null => {
  if (flash.alert) return { message: flash.alert, status: "danger" };
  if (flash.warning) return { message: flash.warning, status: "warning" };
  if (flash.notice) return { message: flash.notice, status: "success" };
  return null;
};

export default function Layout({ children }: { children: React.ReactNode }) {
  const page = usePage<PageProps>();
  const { title, logged_in_user, current_seller } = page.props;
  // Access flash from page.flash (not page.props.flash) - this data does NOT persist in history state
  const flash = (page as unknown as { flash: FlashData }).flash;
  const isRouteLoading = useRouteLoading();

  React.useEffect(() => {
    const alertPayload = flashToAlertPayload(flash || {});
    if (alertPayload) {
      showAlert(alertPayload.message, alertPayload.status === "danger" ? "error" : alertPayload.status);
    }
  }, [flash]);

  const initialAlert = flashToAlertPayload(flash || {});

  return (
    <LoggedInUserProvider value={parseLoggedInUser(logged_in_user)}>
      <CurrentSellerProvider value={parseCurrentSeller(current_seller)}>
        <Head title={title} />
        <Alert initial={initialAlert} />
        <div id="inertia-shell" className="flex h-screen flex-col lg:flex-row">
          <Nav title="Dashboard" />
          {isRouteLoading ? <LoadingSkeleton /> : null}
          <main className={classNames("flex-1 overflow-y-auto", { hidden: isRouteLoading })}>{children}</main>
        </div>
      </CurrentSellerProvider>
    </LoggedInUserProvider>
  );
}

export function LoggedInUserLayout({ children }: { children: React.ReactNode }) {
  const page = usePage<PageProps>();
  const { title, logged_in_user, current_seller } = page.props;
  // Access flash from page.flash (not page.props.flash) - this data does NOT persist in history state
  const flash = (page as unknown as { flash: FlashData }).flash;

  React.useEffect(() => {
    const alertPayload = flashToAlertPayload(flash || {});
    if (alertPayload) {
      showAlert(alertPayload.message, alertPayload.status === "danger" ? "error" : alertPayload.status);
    }
  }, [flash]);

  const initialAlert = flashToAlertPayload(flash || {});

  return (
    <LoggedInUserProvider value={parseLoggedInUser(logged_in_user)}>
      <CurrentSellerProvider value={parseCurrentSeller(current_seller)}>
        <Head title={title} />
        <Alert initial={initialAlert} />
        {children}
      </CurrentSellerProvider>
    </LoggedInUserProvider>
  );
}
