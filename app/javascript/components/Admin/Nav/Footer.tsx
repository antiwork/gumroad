import { Link, usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { CurrentUser } from "$app/types/user";
import { assertResponseError } from "$app/utils/request";

import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Popover } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";

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
    <Popover
      position="top"
      trigger={
        <>
          <img className="user-avatar" src={loggedInUser?.avatarUrl} alt="Your avatar" />
          {loggedInUser?.name}
        </>
      }
    >
      <div role="menu">
        {current_user.impersonated_user ? (
          <>
            <a role="menuitem" href={Routes.root_url()}>
              <img className="user-avatar" src={current_user.impersonated_user.avatar_url} alt="Your avatar" />
              <span>{current_user.impersonated_user.name}</span>
            </a>
            <hr />
          </>
        ) : null}
        <Link role="menuitem" href={Routes.logout_url()} method="delete">
          <span className="icon icon-box-arrow-in-right-fill"></span>
          Logout
        </Link>
        {loggedInUser?.isImpersonating ? (
          <a role="menuitem" href="#" onClick={handleUnbecome}>
            <span className="icon icon-box-arrow-in-right-fill"></span>
            Unbecome
          </a>
        ) : null}
      </div>
    </Popover>
  );
};

export default AdminNavFooter;
