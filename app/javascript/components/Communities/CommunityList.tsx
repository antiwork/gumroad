import { router } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";

import { Community } from "$app/data/communities";

import { scrollTo } from "./CommunityView";

export const CommunityList = ({
  communities,
  selectedCommunity,
  isAboveBreakpoint,
  setSidebarOpen,
  onSelectCommunity,
}: {
  communities: Community[];
  selectedCommunity: Community | null;
  isAboveBreakpoint: boolean;
  setSidebarOpen: (open: boolean) => void;
  onSelectCommunity: (communityId: string) => void;
}) => (
  <section role="navigation" aria-label="Community list" className="flex flex-col overflow-y-auto py-2">
    {communities.map((community) => {
      const isCommunitySelected = community.id === selectedCommunity?.id;

      const handleCommunityClick = (e: React.MouseEvent) => {
        e.preventDefault();
        if (isCommunitySelected) {
          scrollTo({ target: community.unread_count > 0 ? "unread-separator" : "bottom" });
        } else {
          router.get(`/communities/${community.seller.id}/${community.id}`, {}, { preserveState: true });
          onSelectCommunity(community.id);
        }
        if (!isAboveBreakpoint) setSidebarOpen(false);
      };

      return (
        <a
          key={community.id}
          href={`/communities/${community.seller.id}/${community.id}`}
          aria-selected={isCommunitySelected}
          onClick={handleCommunityClick}
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
        </a>
      );
    })}
  </section>
);
