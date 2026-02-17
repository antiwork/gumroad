import * as React from "react";

import { CardWishlist, CardGrid, Card, DummyCardGrid } from "$app/components/Wishlist/Card";

export const RecommendedWishlists = ({ title, wishlists }: { title: string; wishlists?: CardWishlist[] | null }) => {
  if (wishlists === undefined || wishlists === null) {
    return (
      <section className="flex flex-col gap-4">
        <header>
          <h2>{title}</h2>
        </header>
        <DummyCardGrid count={2} />
      </section>
    );
  }

  if (!wishlists.length) return null;

  return (
    <section className="flex flex-col gap-4">
      <header>
        <h2>{title}</h2>
      </header>
      <CardGrid>
        {wishlists.map((wishlist) => (
          // recommended wishlists are in the bottom of the page (off-screen), so we can use lazy loading
          <Card key={wishlist.id} wishlist={wishlist} eager={false} />
        ))}
      </CardGrid>
    </section>
  );
};
