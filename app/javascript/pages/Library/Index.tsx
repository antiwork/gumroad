import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import LibraryPage from "$app/components/Library/LibraryPage";

type Props = React.ComponentProps<typeof LibraryPage>;

export default function LibraryIndex() {
  const props = cast<Props>(usePage().props);

  return <LibraryPage {...props} />;
}
