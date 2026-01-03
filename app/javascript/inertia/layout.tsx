import { Head, usePage } from "@inertiajs/react";
import React from "react";

import { classNames } from "$app/utils/classNames";

import { Nav } from "$app/components/client-components/Nav";
import { CurrentSellerProvider, parseCurrentSeller } from "$app/components/CurrentSeller";
import LoadingSkeleton from "$app/components/LoadingSkeleton";
import { type LoggedInUser, LoggedInUserProvider, parseLoggedInUser } from "$app/components/LoggedInUser";
import Alert from "$app/components/server-components/Alert";
import { useFlash } from "$app/components/useFlash";
import useRouteLoading from "$app/components/useRouteLoading";

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

export default function Layout({ children }: { children: React.ReactNode }) {
  const { title, logged_in_user, current_seller } = usePage<PageProps>().props;
  const flash = useFlash();
  const isRouteLoading = useRouteLoading();

  return (
    <LoggedInUserProvider value={parseLoggedInUser(logged_in_user)}>
      <CurrentSellerProvider value={parseCurrentSeller(current_seller)}>
        <Head title={title} />
        <Alert initial={flash} />
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
  const { title, logged_in_user, current_seller } = usePage<PageProps>().props;
  const flash = useFlash();

  return (
    <LoggedInUserProvider value={parseLoggedInUser(logged_in_user)}>
      <CurrentSellerProvider value={parseCurrentSeller(current_seller)}>
        <Head title={title} />
        <Alert initial={flash} />
        {children}
      </CurrentSellerProvider>
    </LoggedInUserProvider>
  );
}
