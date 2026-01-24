import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { LoggedInUserProvider, parseLoggedInUser } from "$app/components/LoggedInUser";
import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Product, useSelectionFromUrl, Props as ProductProps } from "$app/components/Product";

type CustomStyles = {
  background_color: string;
  highlight_color: string;
  font: string;
};

type RawLoggedInUser = {
  id: string;
  email: string | null;
  name: string | null;
  avatar_url: string;
  team_memberships: unknown[];
  policies: Record<string, unknown>;
  confirmed: boolean;
  is_gumroad_admin: boolean;
  is_impersonating: boolean;
  lazy_load_offscreen_discover_images: boolean;
};

type PageProps = ProductProps & {
  custom_styles: CustomStyles;
  logged_in_user: RawLoggedInUser | null;
};

// Generate CSS custom properties for seller custom styles
function getCustomStylesCss(styles: CustomStyles): string {
  const { background_color, highlight_color, font } = styles;

  // Determine if colors are dark or light for contrast
  const hexToRgb = (hex: string) => {
    const result = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/iu.exec(hex);
    if (!result?.[1] || !result[2] || !result[3]) {
      return { r: 255, g: 255, b: 255 };
    }
    return {
      r: parseInt(result[1], 16),
      g: parseInt(result[2], 16),
      b: parseInt(result[3], 16),
    };
  };

  const getLightness = (hex: string) => {
    const { r, g, b } = hexToRgb(hex);
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  };

  const splitColor = (hex: string) => {
    const { r, g, b } = hexToRgb(hex);
    return `${r} ${g} ${b}`;
  };

  const bgLightness = getLightness(background_color);
  const highlightLightness = getLightness(highlight_color);

  const color = bgLightness < 0.55 ? "255 255 255" : "0 0 0";
  const contrastColor = bgLightness < 0.55 ? "0 0 0" : "255 255 255";
  const contrastAccent = highlightLightness < 0.55 ? "255 255 255" : "0 0 0";

  const fontFallback = ["Domine", "Merriweather", "Roboto Slab"].includes(font)
    ? "serif"
    : font === "Roboto Mono"
      ? "monospace"
      : "sans-serif";

  const fontFamily = `"${font}", "ABC Favorit", ${fontFallback}`;

  return `
    :root {
      --accent: ${splitColor(highlight_color)};
      --contrast-accent: ${contrastAccent};
      --font-family: ${fontFamily};
      --color: ${color};
      --primary: var(--color);
      --contrast-primary: ${contrastColor};
      --filled: ${splitColor(background_color)};
      --contrast-filled: var(--color);
      --body-bg: ${background_color};
      --active-bg: rgb(var(--color) / var(--gray-1));
      --border-alpha: 1;
    }
    body {
      background-color: ${background_color};
      color: ${bgLightness < 0.55 ? "#fff" : "#000"};
      font-family: ${fontFamily};
    }
  `;
}

function PurchaseProductPage() {
  const props = cast<PageProps>(usePage().props);
  const { product, purchase, discount_code, wishlists, custom_styles, logged_in_user } = props;
  const [selection, setSelection] = useSelectionFromUrl(product);

  // Apply custom styles via a style tag
  React.useEffect(() => {
    const styleId = "seller-custom-styles";
    let styleElement = document.getElementById(styleId);

    if (!styleElement) {
      const newStyleElement = document.createElement("style");
      newStyleElement.id = styleId;
      document.head.appendChild(newStyleElement);
      styleElement = newStyleElement;
    }

    styleElement.textContent = getCustomStylesCss(custom_styles);

    // Load custom font if not ABC Favorit
    if (custom_styles.font !== "ABC Favorit") {
      const fontUrl = `https://fonts.googleapis.com/css2?family=${encodeURIComponent(custom_styles.font)}:wght@400;600&display=swap`;
      const existingLink = document.querySelector(`link[href="${fontUrl}"]`);
      if (!existingLink) {
        const link = document.createElement("link");
        link.rel = "stylesheet";
        link.href = fontUrl;
        document.head.appendChild(link);
      }
    }

    return () => {
      // Cleanup style element on unmount
      const element = document.getElementById(styleId);
      if (element) {
        element.remove();
      }
    };
  }, [custom_styles]);

  return (
    <LoggedInUserProvider value={parseLoggedInUser(logged_in_user)}>
      <div>
        <div>
          <section>
            <Product
              product={product}
              purchase={purchase}
              discountCode={discount_code}
              wishlists={wishlists}
              selection={selection}
              setSelection={setSelection}
            />
          </section>
          <PoweredByFooter className="p-0" />
        </div>
      </div>
    </LoggedInUserProvider>
  );
}

PurchaseProductPage.disableLayout = true;
export default PurchaseProductPage;
