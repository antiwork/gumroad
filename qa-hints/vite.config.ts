import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const root = "/tmp/g2626before";

export default defineConfig({
  root: `${root}/qa-hints`,
  base: "./",
  plugins: [react()],
  resolve: {
    alias: {
      $app: `${root}/app/javascript`,
      $assets: `${root}/public`,
      $vendor: `${root}/vendor/assets/javascripts`,
    },
  },
  build: {
    outDir: "/private/tmp/g2626before/qa-hints/dist",
    emptyOutDir: true,
    rollupOptions: {
      input: `${root}/qa-hints/main.tsx`,
    },
  },
});
