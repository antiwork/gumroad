import * as React from "react";
import { useState } from "react";

import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useAppDomain, useDiscoverUrl } from "$app/components/DomainSettings";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

import logo from "$assets/images/logo.svg";

const NavLink = ({
  text,
  href,
  category,
  context,
}: {
  text: string;
  href: string;
  category?: "button";
  context?: "primary";
}) => {
  const currentLocation = useOriginalLocation();
  const isCurrent = new URL(href, currentLocation).pathname === new URL(currentLocation).pathname;

  if (category === "button") {
    return (
      <a
        href={href}
        className={`flex w-full items-center justify-center whitespace-nowrap ${
          text === "Dashboard"
            ? "lg:bg-black lg:text-white lg:hover:bg-pink dark:lg:bg-pink dark:lg:text-black dark:lg:hover:bg-white"
            : context !== "primary"
              ? "lg:border-l-black lg:bg-white lg:text-black lg:hover:bg-pink dark:lg:border-l-white/[.35] dark:lg:bg-black dark:lg:text-white"
              : "lg:bg-black lg:text-white lg:hover:bg-pink"
        } border-black bg-black p-4 text-lg text-white no-underline transition-colors duration-200 hover:bg-pink hover:text-black lg:w-auto lg:border-l lg:px-8 xl:px-12 ${
          context === "primary" && text !== "Dashboard"
            ? "dark:lg:bg-pink dark:lg:text-black dark:lg:hover:bg-white"
            : "dark:lg:hover:bg-white dark:lg:hover:text-black"
        }`}
      >
        {text}
      </a>
    );
  }

  return (
    <a
      href={href}
      className={`flex w-full items-center justify-center whitespace-nowrap border ${isCurrent ? "border-black" : "border-transparent"} ${
        isCurrent
          ? "lg:bg-black lg:text-white dark:lg:bg-white dark:lg:text-black"
          : "lg:bg-transparent lg:text-black dark:lg:text-white"
      } bg-black p-4 text-lg text-white no-underline transition-all duration-200 hover:border-black lg:w-auto lg:rounded-full lg:px-4 lg:py-2 lg:text-black dark:text-white lg:dark:hover:border-white/[.35]`}
    >
      {text}
    </a>
  );
};

export const Nav = () => {
  const [isMobileMenuOpen, setIsMobileMenuOpen] = useState(false);
  const currentSeller = useCurrentSeller();
  const appDomain = useAppDomain();
  const discoverUrl = useDiscoverUrl();

  const navLinks = (
    <>
      <NavLink text="Discover" href={discoverUrl} />
      <NavLink text="About" href={Routes.about_url()} />
      <NavLink text="Features" href={Routes.features_url()} />
      <NavLink text="Pricing" href={Routes.pricing_url()} />
    </>
  );

  const authLinks = currentSeller ? (
    <NavLink text="Dashboard" href={Routes.dashboard_url({ host: appDomain })} category="button" />
  ) : (
    <>
      <NavLink text="Log in" href={Routes.login_url()} category="button" />
      <NavLink text="Start selling" href={Routes.signup_url()} category="button" context="primary" />
    </>
  );

  return (
    <section role="navigation">
      <div className="sticky left-0 right-0 top-0 z-50 flex h-20 justify-between border-b border-black bg-white pl-4 pr-4 lg:pl-8 lg:pr-0 dark:border-b-white/[.35] dark:bg-black">
        <a href={Routes.root_url()} className="flex items-center">
          <img src={logo} alt="Gumroad" className="h-8 dark:invert" />
        </a>
        <div className="override hidden lg:flex lg:flex-1 lg:items-center lg:justify-center lg:gap-4">
          <div className="flex flex-col items-center justify-center lg:flex-row lg:gap-2 lg:px-8">{navLinks}</div>
        </div>
        <div className="override hidden lg:flex">
          <div className="flex flex-col lg:flex-row">{authLinks}</div>
        </div>
        <div className="flex items-center lg:hidden">
          <button
            className="relative flex h-8 w-8 flex-col items-center justify-center focus:outline-none"
            onClick={() => setIsMobileMenuOpen(!isMobileMenuOpen)}
          >
            <div className="mb-1 h-0.5 w-8 origin-center bg-black transition-transform duration-200 dark:bg-white" />
            <div className="mt-1 h-0.5 w-8 origin-center bg-black transition-transform duration-200 dark:bg-white" />
          </button>
        </div>
      </div>
      <div
        className={`override sticky left-0 right-0 top-20 z-50 flex-col justify-between border-b border-black bg-black dark:border-white/[.35] ${isMobileMenuOpen ? "flex" : "hidden"} `}
      >
        <div className="flex flex-col items-center justify-center lg:flex-row lg:gap-2 lg:px-8">
          {navLinks}
          {authLinks}
        </div>
      </div>
    </section>
  );
};
