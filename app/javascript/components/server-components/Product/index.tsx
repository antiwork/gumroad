import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Layout, Props } from "$app/components/Product/Layout";

const ProductPage = (props: Props) => (
  <>
    <Layout {...props} />
    <PoweredByFooter />
  </>
);

export default register({ component: ProductPage, propParser: createCast() });
