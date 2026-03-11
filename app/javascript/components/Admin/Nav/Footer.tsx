import { ArrowRight } from "@boxicons/react";
import { Link, usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { CurrentUser } from "$app/types/user";
import { assertResponseError } from "$app/utils/request";

import { useLoggedInUser } from "$app/components/LoggedInUser";
import { DashboardNavProfilePopover } from "$app/components/ProfilePopover";
import { showAlert } from "$app/components/server-components/Alert";
import { Avatar } from "$app/components/ui/Avatar";

type ResponseData = {
  redirect_to: string;
};

type PageProps = {
  current_user: CurrentUser;
  authenticity_token: string;
};

const AdminNavFooter = () => {
  const { current_user, authenticity_token: authenticityToken } = cast<PageProps>(usePage().props);
  const loggedInUser = useLoggedInUser();

  const handleUnbecome = (ev: React.MouseEvent<HTMLAnchorElement>) => {
    ev.preventDefault();

    void (async () => {
      try {
        const response = await fetch(Routes.admin_unimpersonate_path(), {
          method: "DELETE",
          headers: {
            Accept: "application/json",
            "Content-Type": "application/json",
            "X-CSRF-Token": authenticityToken,
          },
        });

        if (response.ok) {
          const data: ResponseData = cast<ResponseData>(await response.json());
          window.location.href = data.redirect_to;
        }
      } catch (error) {
        assertResponseError(error);
        showAlert(error.message, "error");
      }
    })();
  };

  return (
    <DashboardNavProfilePopover user={loggedInUser}>
      <div role="menu" className="flex flex-col border-0! shadow-none! dark:border!">
        {current_user.impersonated_user ? (
          <>
            <a role="menuitem" href={Routes.root_url()}>
              <Avatar src={current_user.impersonated_user.avatar_url} alt="Your avatar" />
              <span>{current_user.impersonated_user.name}</span>
            </a>
            <hr className="my-2" />
          </>
        ) : null}
        <Link role="menuitem" href={Routes.logout_url()} method="delete" className="all-unset">
          <ArrowRight pack="filled" className="mr-3 ml-1 size-5" />
          Logout
        </Link>
        {loggedInUser?.isImpersonating ? (
          <a role="menuitem" href="#" onClick={handleUnbecome} className="w-full">
            <ArrowRight pack="filled" className="mr-3 ml-1 size-5" />
            Unbecome
          </a>
        ) : null}
      </div>
    </DashboardNavProfilePopover>
  );
};

export default AdminNavFooter;
