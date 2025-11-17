import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import PasswordPage, { type PasswordPagePropsType } from "$app/components/server-components/Settings/PasswordPage";

export default function Index() {
  const props = cast<PasswordPagePropsType>(usePage().props);

  return <PasswordPage {...props} />;
}
