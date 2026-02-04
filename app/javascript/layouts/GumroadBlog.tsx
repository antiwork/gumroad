import * as React from "react";

import { HomeSharedFooter } from "$app/components/Home/Shared/Footer";
import { HomeSharedNav } from "$app/components/Home/Shared/Nav";

export function GumroadBlogLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex min-h-screen flex-1 flex-col overflow-hidden bg-white text-black">
      <HomeSharedNav />
      <div className="flex flex-1 flex-col bg-white font-['ABC_Favorit'] text-base font-normal leading-relaxed tracking-tight text-black">
        {children}
      </div>
      <HomeSharedFooter />
    </div>
  );
}
