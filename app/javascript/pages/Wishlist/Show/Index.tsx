import { usePage } from "@inertiajs/react";
import React from "react";

import { WishlistProps } from "$app/components/Wishlist";
import { default as WishlistPage } from "$app/components/WishlistPage";

function WishlistPageIndex() {
  const {
    id,
    name,
    description,
    url,
    user,
    following,
    can_follow,
    can_edit,
    discover_opted_out,
    checkout_enabled,
    items,
    isDiscover,
    pagination,
  } = usePage<WishlistProps>().props;

  return (
    <WishlistPage
      id={id}
      name={name}
      description={description}
      url={url}
      user={user}
      following={following}
      can_follow={can_follow}
      can_edit={can_edit}
      discover_opted_out={discover_opted_out}
      checkout_enabled={checkout_enabled}
      items={items}
      isDiscover={isDiscover}
      pagination={pagination}
    />
  );
}

export default WishlistPageIndex;
