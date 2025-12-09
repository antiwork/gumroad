import * as React from "react";

import { setPurchaseArchived } from "$app/data/library";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";

type Props = { purchase_id: string; initial_is_archived: boolean };

export const PurchaseArchiveButton = ({ purchase_id, initial_is_archived }: Props) => {
  const [isArchived, setIsArchived] = React.useState<boolean>(initial_is_archived);
  const [processing, setProcessing] = React.useState<boolean>(false);

  const toggleArchive = asyncVoid(async () => {
    const shouldBeArchived = !isArchived;

    setProcessing(true);

    try {
      await setPurchaseArchived({ is_archived: shouldBeArchived, purchase_id });
      setIsArchived(shouldBeArchived);
      showAlert(shouldBeArchived ? "Product archived!" : "Product unarchived!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert("Something went wrong.", "error");
    }
    setProcessing(false);
  });

  return (
    <Button onClick={toggleArchive} disabled={processing}>
      {isArchived ? "Unarchive from library" : "Archive from library"}
    </Button>
  );
};
