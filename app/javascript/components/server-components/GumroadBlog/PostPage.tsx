import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

const PostPage = ({ hi = "hi" }: { hi?: string }) => <div>PostPage {hi}</div>;

export default register({ component: PostPage, propParser: createCast() });
