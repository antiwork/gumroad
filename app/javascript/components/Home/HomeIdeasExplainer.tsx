import React from "react";

import FlipbookCarousel, { type FlipbookCarouselSlide } from "$app/components/FlipbookCarousel/FlipbookCarousel";

export const HomeIdeasExplainer = ({ slides }: { slides: FlipbookCarouselSlide[] }) => (
  <section className="relative bg-gray py-24 lg:py-32">
    <div className="px-8 lg:px-[4vw]">
      <div className="mx-auto mb-14 max-w-4xl text-center text-4xl leading-tight lg:mb-20 lg:text-5xl">
        You know all those great ideas you have?
      </div>
    </div>
    <div className="mx-auto max-w-7xl px-4">
      <FlipbookCarousel slides={slides} ariaLabel="Gumroad feature cards" />
    </div>
    <div className="mx-auto mt-14 flex max-w-4xl flex-col gap-4 px-8 text-center lg:mt-20">
      <h2 className="text-4xl leading-tight lg:text-5xl">We make them easier to sell.</h2>
      <p className="mx-auto max-w-2xl text-xl">
        You do not have to be a tech expert or even understand how to start a business. Take what you know, package it
        up, and Gumroad handles the rest.
      </p>
    </div>
  </section>
);
