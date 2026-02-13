import { usePage } from "@inertiajs/react";
import React from "react";

import MetaTags, { type MetaTag } from "$app/layouts/components/MetaTags";

import { Nav } from "$app/components/client-components/Nav";
import { CurrentSellerProvider, parseCurrentSeller } from "$app/components/CurrentSeller";
import { type LoggedInUser, LoggedInUserProvider, parseLoggedInUser } from "$app/components/LoggedInUser";
import Alert, { type AlertPayload } from "$app/components/server-components/Alert";
import { useFlashMessage } from "$app/components/useFlashMessage";

type PageProps = {
  _inertia_meta?: MetaTag[];
  flash?: AlertPayload | null;
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
  const { flash, logged_in_user, current_seller } = usePage<PageProps>().props;
  useFlashMessage(flash);

  return (
    <LoggedInUserProvider value={parseLoggedInUser(logged_in_user)}>
      <CurrentSellerProvider value={parseCurrentSeller(current_seller)}>
        <MetaTags />
        <Alert initial={null} />
        <div id="inertia-shell" className="flex h-screen flex-col lg:flex-row">
          {logged_in_user ? <Nav title="Dashboard" /> : null}
          <main className="flex-1 overflow-y-auto">{children}</main>
        </div>
      </CurrentSellerProvider>
    </LoggedInUserProvider>
  );
}

export function PublicLayout({ children }: { children: React.ReactNode }) {
  const { flash } = usePage<PageProps>().props;

  useFlashMessage(flash);

  return (
    <div>
      <MetaTags />
      <Alert initial={null} />
      {children}
    </div>
  );
}

export function LoggedInUserLayout({ children }: { children: React.ReactNode }) {
  const { flash, logged_in_user, current_seller } = usePage<PageProps>().props;

  useFlashMessage(flash);

  return (
    <LoggedInUserProvider value={parseLoggedInUser(logged_in_user)}>
      <CurrentSellerProvider value={parseCurrentSeller(current_seller)}>
        <MetaTags />
        <Alert initial={null} />
        {children}
      </CurrentSellerProvider>
    </LoggedInUserProvider>
  );
}

export function StandaloneLayout({ children }: { children: React.ReactNode }) {
  const { flash, logged_in_user, current_seller } = usePage<PageProps>().props;

  useFlashMessage(flash);

  return (
    <LoggedInUserProvider value={parseLoggedInUser(logged_in_user)}>
      <CurrentSellerProvider value={parseCurrentSeller(current_seller)}>
        <MetaTags />
        <Alert initial={null} />
        <div className="flex min-h-screen flex-col lg:flex-row">
          <main className="flex-1">{children}</main>
        </div>
      </CurrentSellerProvider>
    </LoggedInUserProvider>
  );
}
