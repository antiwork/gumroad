import { sortBy } from "lodash-es";
import * as React from "react";
import { ReactSortable as Sortable } from "react-sortablejs";

import { WishlistsSection } from "$app/data/profile_settings";
import { fetchWishlists } from "$app/data/wishlists";
import { assertResponseError } from "$app/utils/request";

import { useReducer, EditorSubmenu, SectionLayout, ProductList } from "$app/components/Profile/EditSections";
import { WishlistsView } from "$app/components/Profile/Sections";
import { showAlert } from "$app/components/server-components/Alert";
import { Row, RowActions, RowContent, RowDragHandle } from "$app/components/ui/Rows";
import { CardWishlist, DummyCardGrid } from "$app/components/Wishlist/Card";

export const WishlistsSectionView = ({ section }: { section: WishlistsSection }) => {
  const [state, dispatch] = useReducer();
  const uid = React.useId();
  const selectedWishlistsCount = state.wishlist_options.filter((wishlist) =>
    section.shown_wishlists.includes(wishlist.id),
  ).length;
  const [wishlists, setWishlists] = React.useState<{ id: string; name: string; chosen?: boolean }[]>(
    sortBy(state.wishlist_options, (wishlist) => {
      const index = section.shown_wishlists.indexOf(wishlist.id);
      return index < 0 ? Infinity : index;
    }),
  );

  const updateSection = (updated: Partial<WishlistsSection>) =>
    dispatch({ type: "update-section", updated: { ...section, ...updated } });

  const wishlistIds = wishlists.map((wishlist) => wishlist.id);
  React.useEffect(
    () =>
      updateSection({
        shown_wishlists: sortBy(section.shown_wishlists, (id) => wishlistIds.indexOf(id)),
      }),
    [wishlistIds.join()],
  );

  const [loadedWishlists, setLoadedWishlists] = React.useState<CardWishlist[] | null>(null);
  React.useEffect(() => {
    const loadWishlists = async () => {
      setLoadedWishlists(null);
      try {
        setLoadedWishlists(section.shown_wishlists.length > 0 ? await fetchWishlists(section.shown_wishlists) : []);
      } catch (e) {
        assertResponseError(e);
        showAlert(e.message, "error");
      }
    };
    void loadWishlists();
  }, [section.shown_wishlists]);

  return (
    <SectionLayout
      section={section}
      menuItems={[
        <EditorSubmenu
          key="0"
          heading="Wishlists"
          text={`${selectedWishlistsCount} ${selectedWishlistsCount === 1 ? "wishlist" : "wishlists"}`}
        >
          <div className="flex flex-col gap-4 overflow-auto" style={{ maxHeight: "min(100vh, 500px)" }}>
            {wishlists.length > 0 ? (
              <Sortable list={wishlists} setList={setWishlists} tag={ProductList} handle="[aria-grabbed]">
                {wishlists.map((wishlist) => (
                  <Row asChild key={wishlist.id}>
                    <label role="listitem">
                      <RowContent>
                        <RowDragHandle aria-grabbed={wishlist.chosen} />
                        <span className="text-singleline">{wishlist.name}</span>
                      </RowContent>
                      <RowActions>
                        <input
                          id={`${uid}-productVisibility-${wishlist.id}`}
                          type="checkbox"
                          checked={section.shown_wishlists.includes(wishlist.id)}
                          onChange={() => {
                            updateSection({
                              shown_wishlists: section.shown_wishlists.includes(wishlist.id)
                                ? section.shown_wishlists.filter((id) => id !== wishlist.id)
                                : wishlists.flatMap(({ id }) =>
                                    wishlist.id === id || section.shown_wishlists.includes(id) ? id : [],
                                  ),
                            });
                          }}
                        />
                      </RowActions>
                    </label>
                  </Row>
                ))}
              </Sortable>
            ) : null}
          </div>
        </EditorSubmenu>,
      ]}
    >
      {section.shown_wishlists.length > 0 && !loadedWishlists ? (
        <DummyCardGrid count={section.shown_wishlists.length} />
      ) : (
        <WishlistsView
          wishlists={loadedWishlists ? sortBy(loadedWishlists, (wishlist) => wishlistIds.indexOf(wishlist.id)) : []}
        />
      )}
    </SectionLayout>
  );
};
