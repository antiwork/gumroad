import cx from "classnames";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { escapeRegExp } from "$app/utils";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request } from "$app/utils/request";

import { Icon } from "$app/components/Icons";
import { showAlert } from "$app/components/server-components/Alert";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

export const NavLink = ({
  text,
  icon,
  href,
  exactHrefMatch,
  additionalPatterns = [],
  onClick,
}: {
  text: string;
  icon?: IconName;
  href: string;
  exactHrefMatch?: boolean;
  additionalPatterns?: string[];
  onClick?: (ev: React.MouseEvent<HTMLAnchorElement>) => void;
}) => {
  const { href: originalHref } = new URL(useOriginalLocation());
  const ariaCurrent = [href, ...additionalPatterns].some((pattern) => {
    const escaped = escapeRegExp(pattern);
    return new RegExp(exactHrefMatch ? `^${escaped}/?$` : escaped, "u").test(originalHref);
  })
    ? "page"
    : undefined;

  return (
    <a aria-current={ariaCurrent} href={href} title={text} onClick={onClick}>
      {icon ? <Icon name={icon} /> : null}
      {text}
    </a>
  );
};

export const NavLinkDropdownItem = ({
  text,
  icon,
  href,
  method = "GET",
  onClick,
  ...props
}: {
  text: string;
  icon: IconName;
  href: string;
  method?: "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
  onClick?: (ev: React.MouseEvent<HTMLAnchorElement>) => void;
} & React.AnchorHTMLAttributes<HTMLAnchorElement>) => (
  <a role="menuitem" href={href} data-method={method.toLowerCase()} onClick={onClick} {...props}>
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

  return (
    <nav aria-label="Main" className={cx({ compact, open })}>
      <div className="navbar">
        <a href={Routes.root_url()}>
          <span className="logo-g">&nbsp;</span>
        </a>
        <h1>{title}</h1>
        <button className="toggle" onClick={() => setOpen(!open)} />
      </div>
      <header>
        <a href={Routes.root_url()} aria-label="Dashboard">
          <span className="logo-full">&nbsp;</span>
        </a>
      </header>
      {children}
      <footer>{footer}</footer>
    </nav>
  );
};

export const LogoutDropdownItem = ({
  routeParams,
}: {
  routeParams?: {
    host?: string;
  };
}) => {
  const makeRequest = asyncVoid(async (ev: React.MouseEvent<HTMLAnchorElement>) => {
    ev.preventDefault();

    try {
      await request({ method: "DELETE", accept: "html", url: Routes.logout_url(routeParams) });
    } catch (e) {
      // Even if there's an error, continue with logout since the session might be invalid
    }

    window.location.href = Routes.login_url(routeParams);
  });

  return (
    <NavLinkDropdownItem
      text="Logout"
      icon="box-arrow-in-right-fill"
      href={Routes.logout_url(routeParams)}
      onClick={makeRequest}
      method="DELETE"
    />
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
