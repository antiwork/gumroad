import cx from "classnames";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { useLoggedInUser } from "$app/components/LoggedInUser";
import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Layout, Props } from "$app/components/Product/Layout";

const ProductPage = (props: Props) => {
  const loggedInUser = useLoggedInUser();

  return (
    <div
      className={cx("custom-sections product", loggedInUser?.id === props.creator_profile.external_id && "has-user")}
    >
      <Layout {...props} />
      <PoweredByFooter />
    </div>
  );
};

export default register({ component: ProductPage, propParser: createCast() });
