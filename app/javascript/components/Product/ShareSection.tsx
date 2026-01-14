import * as React from "react";

import { Wishlist, addToWishlist, createWishlist } from "$app/data/wishlists";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { ComboBox } from "$app/components/ComboBox";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useAppDomain } from "$app/components/DomainSettings";
import { FacebookShareButton } from "$app/components/FacebookShareButton";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Popover } from "$app/components/Popover";
import { Product, WishlistForProduct } from "$app/components/Product";
import { PriceSelection } from "$app/components/Product/ConfigurationSelector";
import { showAlert } from "$app/components/server-components/Alert";
import { TwitterShareButton } from "$app/components/TwitterShareButton";
import { Alert } from "$app/components/ui/Alert";
import { WithTooltip } from "$app/components/WithTooltip";

type SuccessState = { newlyCreated: boolean; wishlist: Wishlist };

export const ShareSection = ({
  product,
  selection,
  wishlists: initialWishlists,
}: {
  product: Product;
  selection: PriceSelection;
  wishlists: WishlistForProduct[];
}) => {
  const loggedInUser = useLoggedInUser();
  const appDomain = useAppDomain();
  const [wishlists, setWishlists] = React.useState<WishlistForProduct[]>(initialWishlists);
  const [saveState, setSaveState] = React.useState<
    { type: "initial" | "saving" } | ({ type: "success" } & SuccessState)
  >({ type: "initial" });
  const [dropdownState, setDropdownState] = React.useState<
    { state: "closed" } | { state: "open" } | { state: "creating"; newWishlistName: string }
  >({ state: "closed" });

  const isSelectionInWishlist = (wishlist: WishlistForProduct) =>
    wishlist.selections_in_wishlist.some(
      ({ variant_id, recurrence, rent, quantity }) =>
        variant_id === selection.optionId &&
        recurrence === selection.recurrence &&
        rent === selection.rent &&
        quantity === selection.quantity,
    );

  const addProduct = async (resolveWishlist: Promise<SuccessState>) => {
    setSaveState({ type: "saving" });
    setDropdownState({ state: "closed" });

    try {
      const { newlyCreated, wishlist } = await resolveWishlist;
      const { optionId, recurrence, rent, quantity } = selection;

      await addToWishlist({
        wishlistId: wishlist.id,
        productId: product.id,
        optionId,
        recurrence,
        rent,
        quantity,
      });
      setWishlists((wishlists) =>
        wishlists.map((current) =>
          current.id === wishlist.id
            ? {
                ...current,
                selections_in_wishlist: [
                  ...current.selections_in_wishlist,
                  { variant_id: optionId, recurrence, rent, quantity },
                ],
              }
            : current,
        ),
      );
      setSaveState({ type: "success", newlyCreated, wishlist });
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
      setSaveState({ type: "initial" });
    }
  };

  const newWishlist = async (name: string): Promise<SuccessState> => {
    const { wishlist } = await createWishlist(name);
    setWishlists([...wishlists, { ...wishlist, selections_in_wishlist: [] }]);
    return { newlyCreated: true, wishlist };
  };

  return (
    <>
      <div className="grid grid-cols-[1fr_auto] gap-2">
        <ComboBox
          input={(props) => (
            <div
              {...props}
              className={`input ${dropdownState.state !== "closed" ? "!rounded-b-none" : ""}`}
              aria-label="Add to wishlist"
            >
              <span className="fake-input text-singleline">
                {saveState.type === "success"
                  ? saveState.wishlist.name
                  : saveState.type === "saving"
                    ? "Adding to wishlist..."
                    : "Add to wishlist"}
              </span>
              <Icon name="outline-cheveron-down" />
            </div>
          )}
          disabled={saveState.type === "saving"}
          options={[...wishlists, { id: null }]}
          option={(wishlist, props) =>
            wishlist.id ? (
              <div
                {...props}
                inert={isSelectionInWishlist(wishlist)}
                onClick={(e) => {
                  props.onClick?.(e);
                  void addProduct(Promise.resolve({ newlyCreated: false, wishlist }));
                }}
              >
                <div>
                  <Icon name="file-text" /> {wishlist.name}
                </div>
              </div>
            ) : dropdownState.state === "creating" ? (
              <form
                role={props.role}
                className="flex gap-2 p-2"
                onSubmit={(e) => {
                  e.preventDefault();
                  if (!dropdownState.newWishlistName.trim()) {
                    showAlert("Please enter a wishlist name", "error");
                    return;
                  }
                  void addProduct(newWishlist(dropdownState.newWishlistName));
                }}
              >
                <input
                  type="text"
                  autoFocus
                  placeholder="Wishlist name"
                  value={dropdownState.newWishlistName}
                  onChange={(e) => setDropdownState({ state: "creating", newWishlistName: e.target.value })}
                  className="input"
                  aria-label="Wishlist name"
                />
                <Button type="submit" aria-label="Create wishlist" color="primary">
                  <Icon name="outline-check" />
                </Button>
              </form>
            ) : (
              <div {...props} onClick={() => setDropdownState({ state: "creating", newWishlistName: "" })}>
                <div>
                  <Icon name="plus" /> New wishlist
                </div>
              </div>
            )
          }
          open={loggedInUser ? dropdownState.state !== "closed" : false}
          onToggle={(open) => {
            if (!loggedInUser) {
              window.location.href = Routes.login_url({ host: appDomain, next: product.long_url });
              return;
            }
            if (open) {
              setDropdownState({ state: "open" });
            } else {
              setDropdownState({ state: "closed" });
            }
          }}
        />

        <Popover
          aria-label="Share"
          trigger={
            <WithTooltip tip="Share" position="bottom">
              <Button aria-label="Share">
                <Icon name="share" />
              </Button>
            </WithTooltip>
          }
        >
          <div className="grid grid-cols-1 gap-4">
            <TwitterShareButton url={product.long_url} text={`Buy ${product.name} on @Gumroad`} />
            <FacebookShareButton url={product.long_url} text={product.name} />
            <CopyToClipboard text={product.long_url} copyTooltip="Copy product URL">
              <Button aria-label="Copy product URL">
                <Icon name="link" /> Copy link
              </Button>
            </CopyToClipboard>
          </div>
        </Popover>
      </div>
      {saveState.type === "success" ? (
        <Alert variant="success">
          {saveState.newlyCreated ? (
            <>
              Wishlist created! <a href={Routes.wishlists_url()}>Edit it here.</a>
            </>
          ) : (
            "Added to wishlist!"
          )}
        </Alert>
      ) : null}
    </>
  );
};
