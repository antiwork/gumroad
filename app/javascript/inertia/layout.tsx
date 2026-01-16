import { Head, router, usePage } from "@inertiajs/react";
import React from "react";


import { Nav } from "$app/components/client-components/Nav";
import { CurrentSellerProvider, parseCurrentSeller } from "$app/components/CurrentSeller";
import LoadingSkeleton from "$app/components/LoadingSkeleton";
import { type LoggedInUser, LoggedInUserProvider, parseLoggedInUser } from "$app/components/LoggedInUser";
import Alert, { type AlertPayload } from "$app/components/server-components/Alert";
import { useFlashMessage } from "$app/components/useFlashMessage";
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

  useFlashMessage(flash);
  React.useEffect(() => {
    return router.on("finish", () => {
      const mainContent = document.getElementById("main-content");
      if (mainContent) {
        mainContent.scrollTop = 0;
      }
    });
  }, []);

  return (
    <LoggedInUserProvider value={parseLoggedInUser(logged_in_user)}>
      <CurrentSellerProvider value={parseCurrentSeller(current_seller)}>
        <Head title={title} />
        <Alert initial={null} />
        <div id="inertia-shell" className="flex h-screen flex-col lg:flex-row">
          {logged_in_user ? <Nav title="Dashboard" /> : null}
          <main id="main-content" scroll-region className="flex-1 overflow-y-auto">
            {isRouteLoading ? <LoadingSkeleton /> : children}
          </main>
        </div>
      </CurrentSellerProvider>
    </LoggedInUserProvider>
  );
}

export function LoggedInUserLayout({ children }: { children: React.ReactNode }) {
  const { title, flash, logged_in_user, current_seller } = usePage<PageProps>().props;

  useFlashMessage(flash);

  return (
    <LoggedInUserProvider value={parseLoggedInUser(logged_in_user)}>
      <CurrentSellerProvider value={parseCurrentSeller(current_seller)}>
        <Head title={title} />
        <Alert initial={null} />
        {children}
      </CurrentSellerProvider>
    </LoggedInUserProvider>
  );
}
