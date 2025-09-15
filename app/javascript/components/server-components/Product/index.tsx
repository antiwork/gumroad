import cx from "classnames";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Layout, Props } from "$app/components/Product/Layout";

const ProductPage = (props: Props) => {
  const loggedInUser = useLoggedInUser();

  return (
    <main className={cx("custom-sections", loggedInUser?.id === props.creator_profile.external_id && "has-user")}>
      <Layout {...props} />
      <footer>
        Powered by <span className="logo-full" />
      </footer>
    </main>
  );
};

export default register({ component: ProductPage, propParser: createCast() });
