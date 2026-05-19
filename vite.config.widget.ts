import UnpluginTypia from "@typia/unplugin/vite";
import { resolve } from "path";
import { defineConfig } from "vite";

const widgets: Record<string, string> = {
  gumroad: "app/javascript/widget/overlay.ts",
  "gumroad-embed": "app/javascript/widget/embed.ts",
};

const target = process.env.WIDGET_TARGET || "gumroad";
const entry = widgets[target];
if (!entry) throw new Error(`Unknown WIDGET_TARGET: ${target}. Expected one of: ${Object.keys(widgets).join(", ")}`);

export default defineConfig({
  plugins: [UnpluginTypia({ cache: true })],
  publicDir: false,
  build: {
    outDir: "public/js",
    emptyOutDir: false,
    lib: {
      entry: resolve(__dirname, entry),
      name: target.replace(/-/gu, "_"),
      formats: ["iife"],
      fileName: () => `${target}-bundle.js`,
    },
  },
  define: {
    "process.env.PROTOCOL": JSON.stringify(process.env.PROTOCOL || "https"),
    "process.env.DOMAIN": JSON.stringify(process.env.DOMAIN || "gumroad.com"),
    "process.env.ROOT_DOMAIN": JSON.stringify(process.env.ROOT_DOMAIN || "gumroad.com"),
    "process.env.SHORT_DOMAIN": JSON.stringify(process.env.SHORT_DOMAIN || "gum.co"),
    "process.env.NODE_ENV": JSON.stringify(process.env.NODE_ENV || "production"),
    "process.env": "{}",
  },
  css: {
    preprocessorOptions: {
      scss: {
        loadPaths: [resolve(__dirname, "app/assets")],
      },
    },
  },
});
