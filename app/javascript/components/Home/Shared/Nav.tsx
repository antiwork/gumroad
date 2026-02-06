import { Link, usePage } from "@inertiajs/react";
import * as React from "react";

import { LoggedInUser } from "$app/types/user";
import { classNames } from "$app/utils/classNames";
import { request } from "$app/utils/request";

import arrowDiagonalIcon from "$assets/images/icons/arrow-diagonal-up-right.svg";
import starIcon from "$assets/images/icons/solid-star.svg";
import logoSvg from "$assets/images/logo.svg";

type PageProps = {
  current_user?: LoggedInUser;
};

type GithubStarsResponse = {
  stars?: number;
};

const NavLink = ({
  href,
  children,
  onClick,
  isActive,
  isInertia = false,
}: {
  href: string;
  children: React.ReactNode;
  onClick?: ((event: React.MouseEvent) => void) | undefined;
  isActive: boolean;
  isInertia?: boolean;
}) => {
  const className = classNames(
    "flex w-full items-center justify-center border bg-black p-4 text-lg text-white no-underline transition-all duration-200 hover:border-black lg:w-auto lg:rounded-full lg:py-2 lg:px-4 dark:text-white lg:dark:hover:border-white/35 whitespace-nowrap",
    isActive
      ? "border-black lg:bg-black lg:text-white dark:lg:bg-white dark:lg:text-black"
      : "border-transparent lg:bg-transparent lg:text-black dark:lg:text-white",
  );

  // Implemented conditional rendering for links to use standard <a> tags for non-Inertia routes.
  // This avoids the suboptimal double request (XHR failure + full reload) that occurs when an Inertia Link is used for a non-Inertia destination.
  if (isInertia) {
    return (
      <Link href={href} className={className} {...(onClick && { onClick })}>
        {children}
      </Link>
    );
  }

  return (
    <a href={href} className={className} {...(onClick && { onClick })}>
      {children}
    </a>
  );
};

const NavButton = ({
  href,
  children,
  context,
  onClick,
  external = false,
}: {
  href: string;
  children: string;
  context?: "primary" | undefined;
  onClick?: ((event: React.MouseEvent) => void) | undefined;
  external?: boolean | undefined;
}) => {
  let modifier1 = "";
  if (children === "Dashboard") {
    modifier1 = "lg:bg-black lg:text-white lg:hover:bg-pink dark:lg:bg-pink dark:lg:text-black dark:lg:hover:bg-white";
  } else if (context !== "primary") {
    modifier1 =
      "lg:border-l-black lg:bg-white lg:text-black lg:hover:bg-pink dark:lg:border-l-white/35 dark:lg:bg-black dark:lg:text-white";
  } else {
    modifier1 = "lg:bg-black lg:text-white lg:hover:bg-pink";
  }

  let modifier2 = "";
  if (context === "primary" && children !== "Dashboard") {
    modifier2 = "dark:lg:bg-pink dark:lg:text-black dark:lg:hover:bg-white";
  } else {
    modifier2 = "dark:lg:hover:bg-white dark:lg:hover:text-black";
  }

  const className = classNames(
    "flex w-full items-center justify-center h-full border-black bg-black p-4 text-lg text-white no-underline transition-colors duration-200 hover:bg-pink hover:text-black lg:w-auto lg:border-l lg:py-2 lg:px-6",
    modifier1,
    modifier2,
  );

  if (external) {
    return (
      <a href={href} className={className} {...(onClick && { onClick })}>
        {children}
      </a>
    );
  }

  return (
    <Link href={href} className={className} {...(onClick && { onClick })}>
      {children}
    </Link>
  );
};

const AuthButtons = ({
  user,
  onClick,
}: {
  user?: LoggedInUser | undefined;
  onClick?: ((event: React.MouseEvent) => void) | undefined;
}) => {
  if (user) {
    return (
      <NavButton href={Routes.dashboard_url()} context="primary" {...(onClick && { onClick })} external>
        Dashboard
      </NavButton>
    );
  }

  return (
    <>
      <NavButton href={Routes.new_user_session_path()} {...(onClick && { onClick })}>
        Log in
      </NavButton>
      <NavButton href={Routes.new_user_registration_path()} context="primary" {...(onClick && { onClick })}>
        Start selling
      </NavButton>
    </>
  );
};

export const HomeNav = () => {
  const [mobileMenuOpen, setMobileMenuOpen] = React.useState(false);
  const [stars, setStars] = React.useState<string | null>(null);
  const { url, props } = usePage<PageProps>();
  const user = props.current_user;

  const toggleMobileMenu = () => setMobileMenuOpen((prev) => !prev);
  const closeMobileMenu = () => setMobileMenuOpen(false);

  React.useEffect(() => {
    void request({ method: "GET", accept: "json", url: "/github_stars" })
      .then((response) => response.json())
      .then((data: GithubStarsResponse) => {
        if (typeof data.stars === "number") {
          setStars(
            new Intl.NumberFormat("en-US", {
              notation: "compact",
            }).format(data.stars),
          );
        }
      })
      .catch((error: unknown) => {
        console.error('Error fetching GitHub stars:', error); // eslint-disable-line
      });
  }, []);

  const isCurrentPage = (path: string): boolean => {
    if (path === Routes.gumroad_blog_root_path()) {
      return url.startsWith(path);
    }
    return url === path;
  };

  const LINKS = [
    { href: Routes.discover_path(), label: "Discover" },
    { href: Routes.gumroad_blog_root_path(), label: "Blog", isInertia: true },
    { href: Routes.pricing_path(), label: "Pricing" },
    { href: Routes.features_path(), label: "Features" },
    { href: Routes.about_path(), label: "About" },
  ];

  return (
    <>
      <div className="sticky top-0 right-0 left-0 z-50 flex h-20 justify-between border-b border-black bg-white pr-4 pl-4 lg:pr-0 lg:pl-8 dark:border-b-white/35 dark:bg-black">
        <div className="flex items-center gap-2">
          <Link href={Routes.root_path()} className="flex items-center">
            <img src={logoSvg} loading="lazy" alt="" className="h-7 lg:h-8 dark:invert" />
          </Link>

          <a
            href="https://github.com/antiwork/gumroad"
            target="_blank"
            rel="noopener noreferrer"
            className="flex gap-1.5 rounded-full border border-black p-1.5 text-black no-underline transition-all duration-100 hover:-translate-x-[2px] hover:-translate-y-[2px] hover:bg-gray-100 hover:shadow-[2px_2px_0_0_rgba(0,0,0,1)] dark:border-white/35 dark:text-white dark:hover:bg-gray-700 dark:hover:shadow-[2px_2px_0_0_rgba(255,255,255,0.35)]"
            aria-label="Visit Gumroad on GitHub"
            data-github-stars
          >
            <svg width="20" height="20" viewBox="0 0 98 96" xmlns="http://www.w3.org/2000/svg" className="fill-current">
              <path
                fillRule="evenodd"
                clipRule="evenodd"
                d="M48.854 0C21.839 0 0 22 0 49.217c0 21.756 13.993 40.172 33.405 46.69 2.427.49 3.316-1.059 3.316-2.362 0-1.141-.08-5.052-.08-9.127-13.59 2.934-16.42-5.867-16.42-5.867-2.184-5.704-5.42-7.17-5.42-7.17-4.448-3.015.324-3.015.324-3.015 4.934.326 7.523 5.052 7.523 5.052 4.367 7.496 11.404 5.378 14.235 4.074.404-3.178 1.699-5.378 3.074-6.6-10.839-1.141-22.243-5.378-22.243-24.283 0-5.378 1.94-9.778 5.014-13.2-.485-1.222-2.184-6.275.486-13.038 0 0 4.125-1.304 13.426 5.052a46.97 46.97 0 0 1 12.214-1.63c4.125 0 8.33.571 12.213 1.63 9.302-6.356 13.427-5.052 13.427-5.052 2.67 6.763.97 11.816.485 13.038 3.155 3.422 5.015 7.822 5.015 13.2 0 18.905-11.404 23.06-22.324 24.283 1.78 1.548 3.316 4.481 3.316 9.126 0 6.6-.08 11.897-.08 13.526 0 1.304.89 2.853 3.316 2.364 19.412-6.52 33.405-24.935 33.405-46.691C97.707 22 75.788 0 48.854 0z"
                fill="currentColor"
              />
            </svg>
            {stars ? (
              <div data-github-stars-count className="flex items-center gap-1.5 whitespace-nowrap">
                <span className="text-base leading-none font-medium" data-github-stars-count-value>
                  {stars}
                </span>
                <img src={starIcon} className="dark:invert" width="18" height="18" alt="" />
              </div>
            ) : (
              <div data-github-stars-arrow className="flex items-center gap-1.5">
                <span className="text-base leading-none font-medium">GitHub</span>
                <img src={arrowDiagonalIcon} className="dark:invert" width="14" height="14" alt="" />
              </div>
            )}
          </a>
        </div>

        <div className="override hidden lg:flex lg:items-center">
          <div className="flex flex-col items-center justify-center lg:flex-row lg:gap-1 lg:px-6">
            {LINKS.map(({ href, label, isInertia }) => (
              <NavLink key={href} href={href} isActive={isCurrentPage(href)} isInertia={!!isInertia}>
                {label}
              </NavLink>
            ))}
          </div>
          <div className="flex flex-col lg:h-full lg:flex-row">
            <AuthButtons user={user} />
          </div>
        </div>

        <div className="flex items-center lg:hidden">
          <button
            className="relative flex h-8 w-8 flex-col items-center justify-center all-unset focus:outline-hidden"
            onClick={toggleMobileMenu}
            aria-label="Toggle navigation menu"
          >
            <div
              className={classNames(
                "mb-1 h-0.5 w-8 origin-center bg-black transition-transform duration-200 dark:bg-white",
                { "translate-y-1.5 rotate-45": mobileMenuOpen },
              )}
            />
            <div
              className={classNames(
                "mt-1 h-0.5 w-8 origin-center bg-black transition-transform duration-200 dark:bg-white",
                { "-translate-y-1.5 -rotate-45": mobileMenuOpen },
              )}
            />
          </button>
        </div>
      </div>

      {mobileMenuOpen ? (
        <div
          className="override fixed top-20 right-0 left-0 z-50 flex flex-col justify-between border-b border-black bg-black dark:border-white/35"
          id="mobile-menu"
        >
          <div className="flex flex-col items-center justify-center lg:flex-row lg:gap-1 lg:px-6">
            {LINKS.map(({ href, label, isInertia }) => (
              <NavLink
                key={href}
                href={href}
                onClick={closeMobileMenu}
                isActive={isCurrentPage(href)}
                isInertia={!!isInertia}
              >
                {label}
              </NavLink>
            ))}
          </div>
          <div className="flex flex-col lg:h-full lg:flex-row">
            <AuthButtons user={user} onClick={closeMobileMenu} />
          </div>
        </div>
      ) : null}
    </>
  );
};
