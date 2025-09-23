import fs from "node:fs";
import module from "node:module";
import postcss from "postcss";
import tailwindPlugin from "tailwindcss/plugin";

const require = module.createRequire(import.meta.url);

const scopedPreflightPlugin = (preflightScopeSelector) => {
  if (!preflightScopeSelector) {
    throw new Error("Selector to manually enable the Tailwind CSS preflight is not provided");
  }

  let preflightCssPath;
  let preflightStyles;

  try {
    preflightCssPath = require.resolve("tailwindcss/lib/css/preflight.css");
    preflightStyles = postcss.parse(fs.readFileSync(preflightCssPath, "utf8"));
  } catch {
    const minimalPreflightStyles = `
      * {
        box-sizing: border-box;
        margin: 0;
        padding: 0;
      }
    `;
    preflightStyles = postcss.parse(minimalPreflightStyles);
  }

  return tailwindPlugin(({ addBase }) => {
    preflightStyles.walkRules((rule) => {
      rule.selectors = rule.selectors.map((s) => {
        const trimmedSelector = s.trim();
        if (trimmedSelector.toLowerCase() === ":root") {
          return `${preflightScopeSelector}`;
        }
        if (trimmedSelector.includes(",")) {
          return trimmedSelector
            .split(",")
            .map((part) => `${preflightScopeSelector} :where(${part.trim()})`)
            .join(", ");
        }
        return `${preflightScopeSelector} :where(${trimmedSelector})`;
      });
      rule.selector = rule.selectors.join(", ");
    });

    addBase(preflightStyles.nodes);
  });
};

export default {
  content: ["./app/javascript/**/*.{ts,tsx}", "./app/views/**/*.erb", "./public/help/**/*.html"],
  corePlugins: {
    preflight: false,
  },
  theme: {
    extend: {
      colors: {
        black: "#000000",
        white: "#ffffff",
        pink: "#ff90e8",
        purple: "#90a8ed",
        green: "#23a094",
        orange: "#ffc900",
        red: "#dc341e",
        yellow: "#f1f333",
        violet: "#b23386",
        gray: "#f4f4f0",
        "dark-gray": "#242423",

        body: "var(--body-bg)",
        background: "rgb(var(--filled))",
        foreground: "rgb(var(--color))",
        border: "rgb(var(--color) / var(--border-alpha))",
      },
      boxShadow: {
        DEFAULT: "0.25rem 0.25rem 0 currentColor",
        lg: "0.5rem 0.5rem 0 currentColor",
      },
      spacing: {
        "product-page": "75.25rem",
      },
    },
  },
  plugins: [scopedPreflightPlugin(".scoped-tailwind-preflight")],
};
