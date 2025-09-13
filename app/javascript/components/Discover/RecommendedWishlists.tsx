import * as React from "react";

import { fetchRecommendedWishlists } from "$app/data/wishlists";
import { assertResponseError } from "$app/utils/request";

import { showAlert } from "$app/components/server-components/Alert";
import { useRunOnce } from "$app/components/useRunOnce";
import { CardWishlist, CardGrid, Card, DummyCardGrid } from "$app/components/Wishlist/Card";

export const RecommendedWishlists = ({
  title,
  ...props
}: {
  title: string;
  curatedProductIds?: string[];
  taxonomy?: string | null;
}) => {
  const [wishlists, setWishlists] = React.useState<CardWishlist[] | null>(null);

  useRunOnce(() => {
    const loadWishlists = async () => {
      try {
        setWishlists(await fetchRecommendedWishlists(props));
      } catch (e) {
        assertResponseError(e);
        showAlert(e.message, "error");
      }
    };
    void loadWishlists();
  });

  return wishlists === null || wishlists.length > 0 ? (
    <section className="paragraphs">
      <header>
        <h2>{title}</h2>
      </header>
      {wishlists ? (
        <CardGrid>
          {wishlists.map((wishlist) => (
            // recommended wishlists are in the bottom of the page (off-screen), so we can use lazy loading
            <Card key={wishlist.id} wishlist={wishlist} eager={false} />
          ))}
        </CardGrid>
      ) : (
        <DummyCardGrid count={2} />
      )}
    </section>
  ) : null;
};
