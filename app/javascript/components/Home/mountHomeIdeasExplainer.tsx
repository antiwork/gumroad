import { createElement } from "react";
import type { ComponentProps } from "react";
import { createRoot } from "react-dom/client";

import { HomeIdeasExplainer } from "$app/components/Home/HomeIdeasExplainer";

const mount = document.getElementById("home-ideas-explainer");

if (mount) {
  const props: ComponentProps<typeof HomeIdeasExplainer> = JSON.parse(mount.dataset.props ?? "{}");
  createRoot(mount).render(createElement(HomeIdeasExplainer, props));
}
