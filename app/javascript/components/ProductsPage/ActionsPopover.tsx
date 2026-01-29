import { router } from "@inertiajs/react";
import * as React from "react";

import { duplicateProduct, unarchiveProduct } from "$app/data/product_dashboard";
import { Membership, Product } from "$app/data/products";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";

const ActionsPopover = ({
  product,
  onDuplicate,
  onArchive,
  onUnarchive,
}: {
  product: Product | Membership;
  onDuplicate: () => void;
  onArchive: () => void;
  onUnarchive: (hasRemainingArchivedProducts: boolean) => void;
}) => {
  const [open, setOpen] = React.useState(false);
  const [isDuplicating, setIsDuplicating] = React.useState(false);
  const [isDeleting, setIsDeleting] = React.useState(false);
  const [confirmingDelete, setConfirmingDelete] = React.useState(false);
  const [isArchiving, setIsArchiving] = React.useState(false);
  const [isUnarchiving, setIsUnarchiving] = React.useState(false);

  const handleDuplicate = async () => {
    setIsDuplicating(true);
    showAlert("Duplicating the product. You will be notified once it's ready.", "info");
    try {
      await duplicateProduct(product.permalink, product.name);
      showAlert(`${product.name} is duplicated`, "success");
      onDuplicate();
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setOpen(false);
    setIsDuplicating(false);
  };

  const handleDelete = () => {
    router.delete(Routes.link_path(product.permalink), {
      preserveScroll: true,
      onStart: () => setIsDeleting(true),
      onError: () => {
        showAlert("Failed to delete product. Please try again.", "error");
      },
      onFinish: () => {
        setConfirmingDelete(false);
        setIsDeleting(false);
      },
    });
  };

  const handleArchive = () => {
    router.post(
      Routes.products_archived_index_path(),
      { id: product.permalink },
      {
        preserveScroll: true,
        onStart: () => setIsArchiving(true),
        onSuccess: () => onArchive(),
        onError: () => {
          showAlert("Failed to archive product. Please try again.", "error");
        },
        onFinish: () => setIsArchiving(false),
      }
    );
  };

  const handleUnarchive = async () => {
    setIsUnarchiving(true);
    try {
      const archivedProductsCount = await unarchiveProduct(product.permalink);
      showAlert("Product was unarchived successfully", "success");
      onUnarchive(archivedProductsCount > 0);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsUnarchiving(false);
  };

  return (
    <>
      <Popover open={open} onOpenChange={setOpen}>
        <PopoverTrigger aria-label="Open product action menu" className="cursor-pointer all-unset">
          <Icon name="three-dots" />
        </PopoverTrigger>
        <PopoverContent className="border-0 p-0 shadow-none">
          <div role="menu">
            <div role="menuitem" inert={!product.can_duplicate || isDuplicating} onClick={() => void handleDuplicate()}>
              <Icon name="outline-duplicate" />
              &ensp;{isDuplicating ? "Duplicating..." : "Duplicate"}
            </div>
            {product.can_unarchive ? (
              <div role="menuitem" inert={isUnarchiving} onClick={() => void handleUnarchive()}>
                <Icon name="archive" />
                &ensp;{isUnarchiving ? "Unarchiving..." : "Unarchive"}
              </div>
            ) : null}
            {product.can_archive ? (
              <div role="menuitem" inert={isArchiving} onClick={() => void handleArchive()}>
                <Icon name="archive" />
                &ensp;{isArchiving ? "Archiving..." : "Archive"}
              </div>
            ) : null}
            <div
              className="danger"
              inert={!product.can_destroy || isDeleting}
              role="menuitem"
              onClick={() => setConfirmingDelete(true)}
            >
              <Icon name="trash2" />
              &ensp;{isDeleting ? "Deleting..." : "Delete permanently"}
            </div>
          </div>
        </PopoverContent>
      </Popover>
      {confirmingDelete ? (
        <Modal
          open
          onClose={() => setConfirmingDelete(false)}
          title="Delete Product"
          footer={
            <>
              <Button onClick={() => setConfirmingDelete(false)} disabled={isDeleting}>
                Cancel
              </Button>
              <Button color="danger" onClick={() => void handleDelete()} disabled={isDeleting}>
                {isDeleting ? "Deleting..." : "Confirm"}
              </Button>
            </>
          }
        >
          <h4>Are you sure you want to delete {product.name}?</h4>
        </Modal>
      ) : null}
    </>
  );
};

export default ActionsPopover;
