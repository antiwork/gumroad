import React from "react";

import FlipbookCarousel, { type FlipbookCarouselSlide } from "$app/components/FlipbookCarousel/FlipbookCarousel";

export const HomeIdeasExplainer = ({ slides }: { slides: FlipbookCarouselSlide[] }) => (
  <section className="relative bg-gray py-24 lg:py-32">
    <div className="px-8 lg:px-[4vw]">
      <div className="mx-auto mb-14 max-w-4xl text-center text-4xl leading-tight lg:mb-20 lg:text-5xl">
        Gumroad Gets You Selling
      </div>
    </div>
    <div className="mx-auto max-w-7xl px-4">
      <FlipbookCarousel slides={slides} ariaLabel="Gumroad feature cards" />
    </div>
  </section>
);
