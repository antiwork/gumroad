import * as React from "react";

import { Icon } from "$app/components/Icons";

type BaseUser = { name?: string | null; email?: string | null };
type User = BaseUser & ({ avatarUrl: string; avatar_url?: never } | { avatar_url: string; avatarUrl?: never });

export default function AdminNavFooterTrigger({ user, open }: { user?: User | null; open: boolean }) {
  return (
    <div className="inline-flex px-6 py-4 hover:text-accent">
      <div className="flex-1">
        <img
          className="user-avatar mr-3 border border-white!"
          src={user?.avatarUrl || user?.avatar_url}
          alt="Your avatar"
        />
        {user?.name || user?.email}
      </div>
      <Icon name={open ? "outline-cheveron-up" : "outline-cheveron-down"} />
    </div>
  );
}
