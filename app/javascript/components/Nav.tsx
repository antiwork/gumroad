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
  const { href: originalHref } = new URL(useOriginalLocation());
  const ariaCurrent = [href, ...additionalPatterns].some((pattern) => {
    const escaped = escapeRegExp(pattern);
    return new RegExp(exactHrefMatch ? `^${escaped}/?$` : escaped, "u").test(originalHref);
  })
    ? "page"
    : undefined;

  const Component = component === "a" ? "a" : component;

  return (
    <Component aria-current={ariaCurrent} href={href} title={text} className="flex items-center" {...props}>
      {icon ? <Icon name={icon} /> : null}
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
  <a role="menuitem" href={href} onClick={onClick}>
    <Icon name={icon} />
    {text}
  </a>
);

type Props = {
  children: React.ReactNode;
  title: string;
  footer: React.ReactNode;
  compact?: boolean;
};

export const Nav = ({ title, children, footer, compact }: Props) => {
  const [open, setOpen] = React.useState(false);
  const close = React.useCallback((): void => setOpen(false), []);
  const toggle = React.useCallback((): void => setOpen((prev) => !prev), []);
  const contextValue = React.useMemo<NavContextValue>(() => ({ close }), [close]);

  return (
    <NavContext.Provider value={contextValue}>
      <nav aria-label="Main" className={classNames({ compact, open })}>
        <div className="navbar">
          <a href={Routes.root_url()}>
            <span className="logo-g">&nbsp;</span>
          </a>
          <h1>{title}</h1>
          <button className="toggle" aria-label="Toggle navigation" onClick={toggle} />
        </div>
        <header>
          <a href={Routes.root_url()} aria-label="Dashboard">
            <span className="logo-full">&nbsp;</span>
          </a>
        </header>
        {children}
        <footer>{footer}</footer>
      </nav>
    </NavContext.Provider>
  );
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
    >
      <img className="user-avatar" src={teamMembership.seller_avatar_url} alt={teamMembership.seller_name} />
      <span title={teamMembership.seller_name}>{teamMembership.seller_name}</span>
    </a>
  );
};
