import { Head, usePage } from "@inertiajs/react";
import React from "react";

import { classNames } from "$app/utils/classNames";

import { Nav } from "$app/components/client-components/Nav";
import { CurrentSellerProvider, parseCurrentSeller } from "$app/components/CurrentSeller";
import LoadingSkeleton from "$app/components/LoadingSkeleton";
import { type LoggedInUser, LoggedInUserProvider, parseLoggedInUser } from "$app/components/LoggedInUser";
import Alert, { showAlert, type AlertPayload } from "$app/components/server-components/Alert";
import useRouteLoading from "$app/components/useRouteLoading";

type PageProps = {
  title: string;
  flash?: AlertPayload;
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
  };
};

export default function Layout({ children }: { children: React.ReactNode }) {
  const { title, flash, logged_in_user, current_seller } = usePage<PageProps>().props;
  const isRouteLoading = useRouteLoading();

  React.useEffect(() => {
    if (flash?.message) {
      showAlert(flash.message, flash.status === "danger" ? "error" : flash.status);
    }
  }, [flash]);

  return (
    <LoggedInUserProvider value={parseLoggedInUser(logged_in_user)}>
      <CurrentSellerProvider value={parseCurrentSeller(current_seller)}>
        <Head title={title} />
        <Alert initial={flash ?? null} />
        <div id="inertia-shell" className="flex h-screen flex-col lg:flex-row">
          {logged_in_user ? <Nav title="Dashboard" /> : null}
          {isRouteLoading ? <LoadingSkeleton /> : null}
          <main className={classNames("flex-1 overflow-y-auto", { hidden: isRouteLoading })}>{children}</main>
        </div>
      </CurrentSellerProvider>
    </LoggedInUserProvider>
  );
}

export function LoggedInUserLayout({ children }: { children: React.ReactNode }) {
  const { title, flash, logged_in_user, current_seller } = usePage<PageProps>().props;

  React.useEffect(() => {
    if (flash?.message) {
      showAlert(flash.message, flash.status === "danger" ? "error" : flash.status);
    }
  }, [flash]);

  return (
    <LoggedInUserProvider value={parseLoggedInUser(logged_in_user)}>
      <CurrentSellerProvider value={parseCurrentSeller(current_seller)}>
        <Head title={title} />
        <Alert initial={flash ?? null} />
        {children}
      </CurrentSellerProvider>
    </LoggedInUserProvider>
  );
}
