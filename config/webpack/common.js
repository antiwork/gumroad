import ForkTsCheckerWebpackPlugin from "fork-ts-checker-webpack-plugin";
import fs from "fs";
import MiniCssExtractPlugin from "mini-css-extract-plugin";
import { fileURLToPath } from "node:url";
import path from "path";
import tsCast from "ts-safe-cast/transformer.js";
import webpack from "webpack";
import WebpackAssetsManifest from "webpack-assets-manifest";
import { BundleAnalyzerPlugin } from "webpack-bundle-analyzer";

import shakapackerConfig from "./shakapacker.js";

const dirname = path.dirname(fileURLToPath(import.meta.url));
const rootPath = path.join(dirname, "../../");
const additionalPaths = shakapackerConfig.additional_paths.map((dir) => path.join(rootPath, dir));
const outputPath = path.join(rootPath, shakapackerConfig.public_root_path, shakapackerConfig.public_output_path);
const context = path.join(rootPath, shakapackerConfig.source_path, shakapackerConfig.source_entry_path);
const isProduction = process.env.NODE_ENV === "production";
const hash = isProduction ? "-[contenthash]" : "";
const miniCssHash = isProduction ? "-[contenthash:8]" : "";
const assetHost = process.env.SHAKAPACKER_ASSET_HOST || "/";

const mode = isProduction ? "production" : "development";

const styleLoaders = [
  MiniCssExtractPlugin.loader,
  {
    loader: "css-loader",
    options: {
      sourceMap: true,
      importLoaders: 2,
    },
  },
  {
    loader: "postcss-loader",
    options: { sourceMap: true },
  },
];

const jsRule = {
  test: /\.(js|ts|tsx)?$/u,
  use: [
    {
      loader: "esbuild-loader",
      options: { target: "es2019", supported: { "import-meta": true } },
    },
    {
      loader: path.join(dirname, "loaders", "transformerLoader.js"),
      options: { getTransformers: (program) => [tsCast(program)] },
    },
  ],
};

const assetRule = {
  test: [
    /\.bmp$/u,
    /\.gif$/u,
    /\.jpe?g$/u,
    /\.png$/u,
    /\.tiff$/u,
    /\.ico$/u,
    /\.avif$/u,
    /\.webp$/u,
    /\.eot$/u,
    /\.otf$/u,
    /\.ttf$/u,
    /\.woff2?$/u,
    /\.svg$/u,
  ],
  exclude: /app\/assets\/images\/email/u, // Some email clients don't support data URI for assets
  type: "asset",
  generator: { filename: "static/[hash][ext][query]" },
};

const sassRule = {
  test: /\.scss$/iu,
  use: [
    ...styleLoaders,
    {
      loader: "sass-loader",
      options: {
        sassOptions: { includePaths: additionalPaths },
      },
    },
  ],
};

const webpackAssetsManifestPlugin = new WebpackAssetsManifest({
  entrypoints: true,
  writeToDisk: true,
  output: "manifest.json",
  entrypointsUseAssets: true,
  publicPath: true,
  merge: true,
});

const miniCssExtractPlugin = new MiniCssExtractPlugin({
  filename: `css/[name]${miniCssHash}.css`,
  chunkFilename: `css/[id]${miniCssHash}.css`,
});

const output = {
  globalObject: "globalThis",
  path: outputPath,
  filename: `js/[name]${hash}.js`,
  chunkFilename: `js/[name]${hash}.chunk.js`,
  hotUpdateChunkFilename: "js/[id].[fullhash].hot-update.js",
  publicPath: `${assetHost.endsWith("/") ? assetHost : `${assetHost}/`}${shakapackerConfig.public_output_path}/`,
  // this is currently hardcoded to false in Webpack when using browserslist
  environment: { asyncFunction: true },
};

const entry = {};
for (const file of fs.readdirSync(context)) {
  if (file.startsWith(".")) continue;
  (entry[path.parse(file).name] ??= []).push(`./${file}`);
}

const config = {
  mode,
  devtool: "cheap-module-source-map",
  context,
  entry,
  resolve: {
    extensions: [".js", ".ts", ".tsx"],
    modules: [...additionalPaths, "node_modules"],
    alias: {
      // Vendor
      jwplayer: path.join(rootPath, "vendor/assets/components/jwplayer-7.12.13/jwplayer"),
      $vendor: path.join(rootPath, "vendor/assets/javascripts"),

      // Internal
      $app: path.join(rootPath, "app/javascript"),
      $assets: path.join(rootPath, "app/assets"),
    },
  },

  // Remove when migrated to React 18
  // Refer https://github.com/shakacode/react_on_rails/pull/1460
  ignoreWarnings: [
    {
      module: /react-on-rails\/node_package\/lib\/reactHydrateOrRender.js/u,
      message: /Can't resolve 'react-dom\/client'/u,
    },
  ],

  optimization: {
    // Create a webpack runtime chunk to improve caching.
    // This is basically code which is otherwise embedded in every entry file by Webpack.
    runtimeChunk: {
      name: "webpack-runtime",
    },

    splitChunks: {
      chunks: "all",
      cacheGroups: {
        commons: {
          name: "webpack-commons",
          chunks: "initial",
          minChunks: 3,
        },
      },
    },
  },

  module: {
    strictExportPresence: true,
    rules: [
      sassRule,
      assetRule,
      jsRule,
      {
        resourceQuery: /resource/u,
        type: "asset/resource",
      },
      {
        test: [/\.html$/u],
        type: "asset/source",
      },
      {
        test: /\.(css)$/iu,
        use: styleLoaders,
      },
    ],
  },

  plugins: [
    webpackAssetsManifestPlugin,
    miniCssExtractPlugin,
    new webpack.ProvidePlugin({ Routes: "$app/utils/routes" }),
    new ForkTsCheckerWebpackPlugin({
      typescript: {
        configFile: path.join(rootPath, "tsconfig.json"),
      },
      async: false,
    }),
    process.env.WEBPACK_ANALYZE === "1" && new BundleAnalyzerPlugin(),
    new webpack.DefinePlugin({ SSR: false }),
  ].filter(Boolean),

  output,
};

const widgetConfig = {
  mode,
  context: path.join(rootPath, shakapackerConfig.source_path, "widget"),
  entry: {
    embed: "./embed.ts",
    overlay: ["./overlay.ts", "./overlay.scss"],
  },
  resolve: {
    extensions: [".js", ".ts"],
    modules: [...additionalPaths, "node_modules"],
  },
  output,
  module: {
    strictExportPresence: true,
    rules: [sassRule, assetRule, jsRule],
  },
  plugins: [
    webpackAssetsManifestPlugin,
    miniCssExtractPlugin,
    new webpack.EnvironmentPlugin(["ROOT_DOMAIN", "SHORT_DOMAIN", "DOMAIN", "PROTOCOL"]),
  ],
};

export default [config, widgetConfig];
