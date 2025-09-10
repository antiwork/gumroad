import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Layout, Props } from "$app/components/Product/Layout";

const ProductPage = (props: Props) => (
  <div className="custom-sections mx-auto w-full max-w-6xl">
    <Layout {...props} />
    <footer>
      Powered by <span className="logo-full" />
    </footer>
  </div>
);

export default register({ component: ProductPage, propParser: createCast() });
