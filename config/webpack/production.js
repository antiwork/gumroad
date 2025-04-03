import CompressionPlugin from "compression-webpack-plugin";
import { EsbuildPlugin } from "esbuild-loader";
import TerserPlugin from "terser-webpack-plugin";
import { merge } from "webpack-merge";

import configs from "./common.js";

export default configs.map((config) =>
  merge(config, {
    bail: true,
    devtool: "nosources-source-map",
    optimization: {
      minimizer: [
        new TerserPlugin({
          terserOptions: {
            ecma: 2018,
            output: { comments: false },
          },
        }),
        new EsbuildPlugin({ minify: false, css: true }),
      ],
    },
    plugins: [
      new CompressionPlugin({
        filename: "[path][base].gz[query]",
        algorithm: "gzip",
        test: /\.(js|css|html|json|ico|svg|eot|otf|ttf|map)$/u,
      }),
      new CompressionPlugin({
        filename: "[path][base].br[query]",
        algorithm: "brotliCompress",
        test: /\.(js|css|html|json|ico|svg|eot|otf|ttf|map)$/u,
      }),
    ],
  }),
);
