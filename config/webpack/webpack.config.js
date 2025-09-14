import ForkTsCheckerWebpackPlugin from "fork-ts-checker-webpack-plugin";
import MiniCssExtractPlugin from "mini-css-extract-plugin";
import path from "path";
import webpack from "webpack";
import WebpackAssetsManifest from "webpack-assets-manifest";
import { merge } from "webpack-merge";

import shakapackerConfig from "./shakapacker.js";

export default async () => {
  const baseConfigs = (await import(`./${process.env.NODE_ENV}.js`)).default;
  const clientConfigs = baseConfigs;

  const serverConfig = merge(baseConfigs[0], {
    entry: path.join(process.cwd(), shakapackerConfig.source_path, "ssr.ts"),
    devtool: baseConfigs[0].mode === "production" ? false : "eval",
    output: { filename: "js/ssr.js", chunkFormat: "array-push" },
    // override libraries that incorrectly assume a non-browser target means a node target
    resolve: {
      alias: {
        "braintree-web": "braintree-web/dist/browser",
        "react-dom/server": "react-dom/server.browser",
        "@rails/activestorage": false,
      },
      fallback: {
        tty: false,
        os: false,
        util: false,
      },
    },
    target: "es2019", // most recent supported ES version by the libv8-node gem
  });
  serverConfig.optimization = undefined;
  serverConfig.plugins = [
    ...serverConfig.plugins.filter(
      (plugin) =>
        !(plugin instanceof WebpackAssetsManifest) &&
        !(plugin instanceof MiniCssExtractPlugin) &&
        !(plugin instanceof ForkTsCheckerWebpackPlugin) &&
        !(plugin instanceof webpack.DefinePlugin),
    ),
    new webpack.optimize.LimitChunkCountPlugin({ maxChunks: 1 }),
    new webpack.DefinePlugin({
      SSR: true,
      // React needs this in SSR but doesn't actually use it, so not worth polyfilling
      TextEncoder: class TextEncoder {
        encode(x) {
          return x;
        }
      },
    }),
  ];

  return process.env.WEBPACK_SERVE
    ? clientConfigs
    : process.env.WEBPACK_SSR
      ? serverConfig
      : [...clientConfigs, serverConfig];
};
