import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import MainPage, { type MainPagePropsType } from "$app/components/server-components/Settings/MainPage";

export default function Index() {
  const props = cast<MainPagePropsType>(usePage().props);

  return <MainPage {...props} />;
}
