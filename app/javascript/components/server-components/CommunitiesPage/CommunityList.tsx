import cx from "classnames";
import * as React from "react";
import { Link } from "react-router-dom";

import { Community } from "$app/data/communities";

import { scrollTo } from "./CommunityView";

export const CommunityList = ({
  communities,
  selectedCommunity,
  isAboveBreakpoint,
  setSidebarOpen,
}: {
  communities: Community[];
  selectedCommunity: Community | null;
  isAboveBreakpoint: boolean;
  setSidebarOpen: (open: boolean) => void;
}) => (
  <section role="navigation" aria-label="Community list" className="flex flex-col overflow-y-auto py-2">
    {communities.map((community) => {
      const isCommunitySelected = community.id === selectedCommunity?.id;

      return (
        <Link
          key={community.id}
          to={`/communities/${community.seller.id}/${community.id}`}
          aria-selected={isCommunitySelected}
          onClick={(e) => {
            if (isCommunitySelected) {
              e.preventDefault();
              scrollTo({ target: community.unread_count > 0 ? "unread-separator" : "bottom" });
            }
            if (!isAboveBreakpoint) setSidebarOpen(false);
          }}
          className={cx("flex items-center gap-2 p-2 no-underline", {
            "bg-black text-white": isCommunitySelected,
            "hover:bg-black/5 hover:text-black dark:hover:bg-white/5 dark:hover:text-white": !isCommunitySelected,
          })}
        >
          <figure className="shrink-0">
            <img
              className="flex h-8 w-8 items-center justify-center rounded-sm border border-black object-cover"
              src={community.thumbnail_url}
            />
          </figure>
          <span className="flex-1 truncate">{community.name}</span>
          {community.unread_count > 0 ? (
            <span
              className="rounded-xl border border-black bg-pink px-2 text-sm text-black"
              aria-label="Unread message count"
            >
              {community.unread_count}
            </span>
          ) : null}
        </Link>
      );
    })}
  </section>
);
