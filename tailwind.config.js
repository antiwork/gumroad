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
      },
      boxShadow: {
        DEFAULT: "0.25rem 0.25rem 0 currentColor",
        lg: "0.5rem 0.5rem 0 currentColor",
      },
    },
  },
};
