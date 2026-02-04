import { Link, usePage } from "@inertiajs/react";
import * as React from "react";

import { request } from "$app/utils/request";

import { useDomains } from "$app/components/DomainSettings";
import { useLoggedInUser } from "$app/components/LoggedInUser";

import arrowDiagonalUpRight from "$assets/images/icons/arrow-diagonal-up-right.svg";
import solidStar from "$assets/images/icons/solid-star.svg";
import logo from "$assets/images/logo.svg";

export const HomeSharedNav = () => {
  const loggedInUser = useLoggedInUser();
  const { appDomain } = useDomains();
  const { url } = usePage();
  const [mobileMenuOpen, setMobileMenuOpen] = React.useState(false);
  const [githubStars, setGithubStars] = React.useState<string | null>(null);

  React.useEffect(() => {
    request({ method: "GET", accept: "json", url: "/github_stars" })
      .then((response) => response.json())
      .then((data: { stars?: number }) => {
        if (data.stars != null) {
          setGithubStars(new Intl.NumberFormat("en-US", { notation: "compact" }).format(data.stars));
        }
      })
      .catch((error) => {
        console.error("Error fetching GitHub stars:", error);
      });
  }, []);

  const currentPath = url.split("?")[0];
  const isBlogPage = currentPath.startsWith(Routes.gumroad_blog_root_path());
  const dashboardUrl = Routes.dashboard_url({ host: appDomain });

  return (
    <>
      <div className="sticky top-0 right-0 left-0 z-50 flex h-20 justify-between border-b border-black bg-white pr-4 pl-4 lg:pr-0 lg:pl-8 dark:border-b-white/35 dark:bg-black">
        <div className="flex items-center gap-2">
          <a href={Routes.root_path()} className="flex items-center">
            <img src={logo} alt="" loading="lazy" className="h-7 lg:h-8 dark:invert" />
          </a>

          <a
            href="https://github.com/antiwork/gumroad"
            target="_blank"
            rel="noopener noreferrer"
            className="flex gap-1.5 rounded-full border border-black p-1.5 text-black no-underline transition-all duration-100 hover:-translate-x-[2px] hover:-translate-y-[2px] hover:bg-gray-100 hover:shadow-[2px_2px_0_0_rgba(0,0,0,1)] dark:border-white/35 dark:text-white dark:hover:bg-gray-700 dark:hover:shadow-[2px_2px_0_0_rgba(255,255,255,0.35)]"
            aria-label="Visit Gumroad on GitHub"
          >
            <svg width="20" height="20" viewBox="0 0 98 96" xmlns="http://www.w3.org/2000/svg" className="fill-current">
              <path
                fillRule="evenodd"
                clipRule="evenodd"
                d="M48.854 0C21.839 0 0 22 0 49.217c0 21.756 13.993 40.172 33.405 46.69 2.427.49 3.316-1.059 3.316-2.362 0-1.141-.08-5.052-.08-9.127-13.59 2.934-16.42-5.867-16.42-5.867-2.184-5.704-5.42-7.17-5.42-7.17-4.448-3.015.324-3.015.324-3.015 4.934.326 7.523 5.052 7.523 5.052 4.367 7.496 11.404 5.378 14.235 4.074.404-3.178 1.699-5.378 3.074-6.6-10.839-1.141-22.243-5.378-22.243-24.283 0-5.378 1.94-9.778 5.014-13.2-.485-1.222-2.184-6.275.486-13.038 0 0 4.125-1.304 13.426 5.052a46.97 46.97 0 0 1 12.214-1.63c4.125 0 8.33.571 12.213 1.63 9.302-6.356 13.427-5.052 13.427-5.052 2.67 6.763.97 11.816.485 13.038 3.155 3.422 5.015 7.822 5.015 13.2 0 18.905-11.404 23.06-22.324 24.283 1.78 1.548 3.316 4.481 3.316 9.126 0 6.6-.08 11.897-.08 13.526 0 1.304.89 2.853 3.316 2.364 19.412-6.52 33.405-24.935 33.405-46.691C97.707 22 75.788 0 48.854 0z"
                fill="currentColor"
              />
            </svg>
            {githubStars ? (
              <div className="flex items-center gap-1.5 whitespace-nowrap">
                <span className="text-base leading-none font-medium">{githubStars}</span>
                <img src={solidStar} className="dark:invert" width="18" height="18" alt="" />
              </div>
            ) : (
              <div className="flex items-center gap-1.5">
                <span className="text-base leading-none font-medium">GitHub</span>
                <img src={arrowDiagonalUpRight} className="dark:invert" width="14" height="14" alt="" />
              </div>
            )}
          </a>
        </div>

        <div className="override hidden lg:flex lg:items-center">
          <div className="flex flex-col items-center justify-center lg:flex-row lg:gap-1 lg:px-6">
            <NavLink href={Routes.discover_path()} current={currentPath === Routes.discover_path()} inertia={false}>
              Discover
            </NavLink>
            <NavLink href={Routes.gumroad_blog_root_path()} current={isBlogPage} inertia>
              Blog
            </NavLink>
            <NavLink href={Routes.pricing_path()} current={currentPath === Routes.pricing_path()} inertia={false}>
              Pricing
            </NavLink>
            <NavLink href={Routes.features_path()} current={currentPath === Routes.features_path()} inertia={false}>
              Features
            </NavLink>
            <NavLink
              href={Routes.about_path()}
              current={currentPath === Routes.root_path() || currentPath === Routes.about_path()}
              inertia={false}
            >
              About
            </NavLink>
          </div>
          <div className="flex flex-col lg:h-full lg:flex-row">
            {loggedInUser ? (
              <a
                href={dashboardUrl}
                className="flex h-full w-full items-center justify-center border-black bg-black p-4 text-lg text-white no-underline transition-colors duration-200 hover:bg-pink hover:text-black lg:w-auto lg:border-l lg:bg-black lg:px-6 lg:py-2 lg:text-white lg:hover:bg-pink dark:lg:bg-pink dark:lg:text-black dark:lg:hover:bg-white"
              >
                Dashboard
              </a>
            ) : (
              <>
                <a
                  href={Routes.login_path()}
                  className="flex h-full w-full items-center justify-center border-black bg-black p-4 text-lg text-white no-underline transition-colors duration-200 hover:bg-pink hover:text-black lg:w-auto lg:border-l lg:bg-white lg:px-6 lg:py-2 lg:text-black lg:hover:bg-pink dark:lg:border-l-white/35 dark:lg:bg-black dark:lg:text-white dark:lg:hover:bg-white dark:lg:hover:text-black"
                >
                  Log in
                </a>
                <a
                  href={Routes.signup_path()}
                  className="flex h-full w-full items-center justify-center border-black bg-black p-4 text-lg text-white no-underline transition-colors duration-200 hover:bg-pink hover:text-black lg:w-auto lg:border-l lg:bg-black lg:px-6 lg:py-2 lg:text-white lg:hover:bg-pink dark:lg:bg-pink dark:lg:text-black dark:lg:hover:bg-white"
                >
                  Start selling
                </a>
              </>
            )}
          </div>
        </div>

        <div className="flex items-center lg:hidden">
          <button
            className="relative flex h-8 w-8 flex-col items-center justify-center all-unset focus:outline-hidden"
            onClick={() => setMobileMenuOpen(!mobileMenuOpen)}
          >
            <div
              className={`mb-1 h-0.5 w-8 origin-center bg-black transition-transform duration-200 dark:bg-white ${
                mobileMenuOpen ? "translate-y-1.5 rotate-45" : ""
              }`}
            />
            <div
              className={`mt-1 h-0.5 w-8 origin-center bg-black transition-transform duration-200 dark:bg-white ${
                mobileMenuOpen ? "-translate-y-1.5 -rotate-45" : ""
              }`}
            />
          </button>
        </div>
      </div>

      {mobileMenuOpen ? (
        <div className="override fixed top-20 right-0 left-0 z-50 flex flex-col justify-between border-b border-black bg-black lg:hidden dark:border-white/35">
          <div className="flex flex-col items-center justify-center">
            <MobileNavLink href={Routes.discover_path()}>Discover</MobileNavLink>
            <MobileNavLink href={Routes.gumroad_blog_root_path()} inertia>
              Blog
            </MobileNavLink>
            <MobileNavLink href={Routes.pricing_path()}>Pricing</MobileNavLink>
            <MobileNavLink href={Routes.features_path()}>Features</MobileNavLink>
            <MobileNavLink href={Routes.about_path()}>About</MobileNavLink>
          </div>
          <div className="flex flex-col">
            {loggedInUser ? (
              <a
                href={dashboardUrl}
                className="flex w-full items-center justify-center border-black bg-black p-4 text-lg text-white no-underline transition-colors duration-200 hover:bg-pink hover:text-black"
              >
                Dashboard
              </a>
            ) : (
              <>
                <a
                  href={Routes.login_path()}
                  className="flex w-full items-center justify-center border-black bg-black p-4 text-lg text-white no-underline transition-colors duration-200 hover:bg-pink hover:text-black"
                >
                  Log in
                </a>
                <a
                  href={Routes.signup_path()}
                  className="flex w-full items-center justify-center border-black bg-black p-4 text-lg text-white no-underline transition-colors duration-200 hover:bg-pink hover:text-black"
                >
                  Start selling
                </a>
              </>
            )}
          </div>
        </div>
      ) : null}
    </>
  );
};

const navLinkClasses = (current: boolean) =>
  `flex w-full items-center justify-center border whitespace-nowrap ${
    current ? "border-black" : "border-transparent"
  } ${
    current
      ? "lg:bg-black lg:text-white dark:lg:bg-white dark:lg:text-black"
      : "lg:bg-transparent lg:text-black dark:lg:text-white"
  } bg-black p-4 text-lg text-white no-underline transition-all duration-200 hover:border-black lg:w-auto lg:rounded-full lg:px-4 lg:py-2 dark:text-white lg:dark:hover:border-white/35`;

const NavLink = ({
  href,
  children,
  current = false,
  inertia = false,
}: {
  href: string;
  children: React.ReactNode;
  current?: boolean;
  inertia?: boolean;
}) =>
  inertia ? (
    <Link href={href} className={navLinkClasses(current)}>
      {children}
    </Link>
  ) : (
    <a href={href} className={navLinkClasses(current)}>
      {children}
    </a>
  );

const MobileNavLink = ({
  href,
  children,
  inertia = false,
}: {
  href: string;
  children: React.ReactNode;
  inertia?: boolean;
}) =>
  inertia ? (
    <Link
      href={href}
      className="flex w-full items-center justify-center border border-transparent bg-black p-4 text-lg text-white no-underline transition-colors duration-200"
    >
      {children}
    </Link>
  ) : (
    <a
      href={href}
      className="flex w-full items-center justify-center border border-transparent bg-black p-4 text-lg text-white no-underline transition-colors duration-200"
    >
      {children}
    </a>
  );
