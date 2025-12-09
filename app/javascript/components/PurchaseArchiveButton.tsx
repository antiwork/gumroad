import { useForm } from "@inertiajs/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";

type Props = { purchase_id: string; initial_is_archived: boolean };

export const PurchaseArchiveButton = ({ purchase_id, initial_is_archived }: Props) => {
  const [isArchived, setIsArchived] = React.useState<boolean>(initial_is_archived);
  const { processing, patch } = useForm({});

  const toggleArchive = () => {
    const shouldBeArchived = !isArchived;

    patch(shouldBeArchived ? Routes.library_archive_path(purchase_id) : Routes.library_unarchive_path(purchase_id), {
      only: ["results", "creators", "bundles", "flash"],
      preserveScroll: true,
      onSuccess: () => {
        setIsArchived(shouldBeArchived);
      },
      onError: () => {
        showAlert("Sorry, something went wrong. Please try again.", "error");
      },
    });
  };

  return (
    <Button onClick={toggleArchive} disabled={processing}>
      {isArchived ? "Unarchive from library" : "Archive from library"}
    </Button>
  );
};
