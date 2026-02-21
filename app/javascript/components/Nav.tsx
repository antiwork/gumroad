import * as React from "react";
import { cast } from "ts-safe-cast";

import { escapeRegExp } from "$app/utils";
import { classNames } from "$app/utils/classNames";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Icon } from "$app/components/Icons";
import { TeamMembership } from "$app/components/LoggedInUser";
import { showAlert } from "$app/components/server-components/Alert";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

type NavContextValue = {
  open: boolean;
  close: () => void;
};

const NavContext = React.createContext<NavContextValue | undefined>(undefined);

export const useNav = () => React.useContext(NavContext);

interface BaseNavLinkProps {
  text: string;
  icon?: IconName;
  badge?: React.ReactNode;
  href: string;
  exactHrefMatch?: boolean;
  additionalPatterns?: string[];
  component?: string | React.ComponentType<Record<string, unknown>>;
  onClick?: (ev: React.MouseEvent<HTMLAnchorElement>) => void;
}

const BaseNavLink = ({
  text,
  icon,
  badge,
  href,
  exactHrefMatch,
  additionalPatterns = [],
  component = "a",
  ...props
}: BaseNavLinkProps) => {
  const { href: originalHref } = new URL(typeof window !== "undefined" ? window.location.href : useOriginalLocation());
  const ariaCurrent = [href, ...additionalPatterns].some((pattern) => {
    const escaped = escapeRegExp(pattern);
    return new RegExp(exactHrefMatch ? `^${escaped}/?$` : escaped, "u").test(originalHref);
  })
    ? "page"
    : undefined;

  const Component = component === "a" ? "a" : component;

  return (
    <Component
      aria-current={ariaCurrent}
      href={href}
      title={text}
      className={classNames(
        "flex items-center truncate border-y border-white/50 border-b-transparent px-6 py-4 no-underline last:border-b-white/50 hover:text-accent dark:border-foreground/50 dark:border-b-transparent dark:last:border-b-foreground/50",
        { "text-accent": !!ariaCurrent },
      )}
      {...props}
    >
      {icon ? <Icon name={icon} className="mr-4" /> : null}
      {text}
      {badge ? (
        <>
          <span className="flex-1" />
          {badge}
        </>
      ) : null}
    </Component>
  );
};

interface NavLinkProps extends BaseNavLinkProps {
  onClick?: (ev: React.MouseEvent<HTMLAnchorElement>) => void;
}

export const NavLink = ({ onClick, ...props }: NavLinkProps) => (
  <BaseNavLink {...props} {...(onClick && { onClick })} />
);

interface InertiaNavLinkProps extends BaseNavLinkProps {
  prefetch?: boolean;
}

export const InertiaNavLink = ({ prefetch = false, ...props }: InertiaNavLinkProps) => (
  <BaseNavLink {...props} {...(prefetch && { prefetch })} />
);

export const NavLinkDropdownItem = ({
  text,
  icon,
  href,
  onClick,
}: {
  text: string;
  icon: IconName;
  href: string;
  onClick?: (ev: React.MouseEvent<HTMLAnchorElement>) => void;
}) => (
  <a role="menuitem" href={href} onClick={onClick} className="block truncate border-0 px-4 py-2 no-underline">
    <Icon name={icon} className="mr-3 ml-1" />
    {text}
  </a>
);

type Props = {
  children: React.ReactNode;
  title: string;
  footer: React.ReactNode;
};

export const Nav = ({ title, children, footer }: Props) => {
  const [open, setOpen] = React.useState(false);
  const close = React.useCallback((): void => setOpen(false), []);
  const toggle = React.useCallback((): void => setOpen((prev) => !prev), []);
  const contextValue = React.useMemo<NavContextValue>(() => ({ open, close }), [open, close]);

  return (
    <NavContext.Provider value={contextValue}>
      <nav
        aria-label="Main"
        className={classNames(
          "flex flex-col overflow-x-hidden overflow-y-auto bg-black text-white lg:static lg:w-52 dark:text-foreground",
          { "fixed z-10 size-full": open },
        )}
      >
        <div className="override grid grid-cols-[auto_1fr_auto] items-center gap-3 p-4 text-lg leading-6 lg:hidden">
          <a href={Routes.root_url()} className="no-underline">
            <span className="logo-g" />
          </a>
          <h1 className="w-full truncate text-center text-base">{title}</h1>
          <button className="all-unset" aria-label="Toggle navigation" onClick={toggle}>
            <Icon name={open ? "x" : "outline-menu"} />
          </button>
        </div>
        <header className="hidden p-6 lg:grid">
          <a href={Routes.root_url()} aria-label="Dashboard" className="no-underline">
            <span className="logo-full w-full text-[2.5rem] leading-[1.2]" />
          </a>
        </header>
        {children}
        <footer className={classNames("mt-auto hidden lg:grid", { grid: open })}>{footer}</footer>
      </nav>
    </NavContext.Provider>
  );
};

export const NavSection = ({ children }: { children: React.ReactNode }) => {
  const nav = useNav();
  const isOpen = !!nav?.open;
  return <section className={classNames("mb-12 hidden lg:grid", { grid: isOpen })}>{children}</section>;
};

export const UnbecomeDropdownItem = () => {
  const makeRequest = asyncVoid(async (ev: React.MouseEvent<HTMLAnchorElement>) => {
    ev.preventDefault();

    try {
      const response = await request({ method: "DELETE", accept: "json", url: Routes.admin_unimpersonate_path() });
      if (response.ok) {
        const responseData = cast<{ redirect_to: string }>(await response.json());
        window.location.href = responseData.redirect_to;
      }
    } catch (e) {
      assertResponseError(e);
      showAlert("Something went wrong.", "error");
    }
  });

  return <NavLinkDropdownItem text="Unbecome" icon="box-arrow-in-right-fill" href="#" onClick={makeRequest} />;
};

export const NavLinkDropdownMembershipItem = ({ teamMembership }: { teamMembership: TeamMembership }) => {
  const onClick = (ev: React.MouseEvent<HTMLAnchorElement>) => {
    const currentUrl = new URL(window.location.href);
    // It is difficult to tell if the account to be switched has access to the current page via policies in this context.
    // Pundit deals with that, and PunditAuthorization concern handles Pundit::NotAuthorizedError.
    // account_switched param is solely for the purpose of not showing the error message when redirecting to the
    // dashboard in case the user doesn't have access to the page.
    currentUrl.searchParams.set("account_switched", "true");
    ev.preventDefault();
    request({
      method: "POST",
      accept: "json",
      url: Routes.sellers_switch_path({ team_membership_id: teamMembership.id }),
    })
      .then((res) => {
        if (!res.ok) throw new ResponseError();
        window.location.href = currentUrl.toString();
      })
      .catch((e: unknown) => {
        assertResponseError(e);
        showAlert("Something went wrong.", "error");
      });
  };

  return (
    <a
      role="menuitemradio"
      href={Routes.sellers_switch_path()}
      onClick={onClick}
      aria-checked={teamMembership.is_selected}
      className="flex! min-w-0 items-center gap-2"
    >
      <img className="user-avatar shrink-0" src={teamMembership.seller_avatar_url} alt={teamMembership.seller_name} />
      <span className="min-w-0 flex-1 truncate" title={teamMembership.seller_name}>
        {teamMembership.seller_name}
      </span>
      {teamMembership.is_selected ? <Icon name="solid-check-circle" className="h-5 shrink-0 text-accent" /> : null}
    </a>
  );
};
