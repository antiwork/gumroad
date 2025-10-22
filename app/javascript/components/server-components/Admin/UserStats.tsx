import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import AdminUserStats from "$app/components/Admin/Users/Stats";

export default register({ component: AdminUserStats, propParser: createCast() });
