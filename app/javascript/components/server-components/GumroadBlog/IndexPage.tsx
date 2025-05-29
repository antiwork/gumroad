import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

const IndexPage = ({ hi = "hi" }: { hi?: string }) => <div>IndexPage {hi}</div>;

export default register({ component: IndexPage, propParser: createCast() });
