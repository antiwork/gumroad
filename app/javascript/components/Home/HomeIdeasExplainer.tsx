import React from "react";

import FlipbookCarousel, { type FlipbookCarouselSlide } from "$app/components/FlipbookCarousel/FlipbookCarousel";

export const HomeIdeasExplainer = ({ slides }: { slides: FlipbookCarouselSlide[] }) => (
  <section className="relative bg-gray py-24 lg:py-32">
    <div className="px-8 lg:px-[4vw]">
      <div className="mx-auto mb-14 text-center text-5xl leading-none md:text-6xl lg:mb-20 lg:text-7xl">
        Our Features Get You Selling
      </div>
    </div>
    <div className="mx-auto max-w-7xl px-4">
      <FlipbookCarousel slides={slides} ariaLabel="Gumroad feature cards" />
    </div>
  </section>
);
