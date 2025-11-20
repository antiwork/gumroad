import { merge } from "webpack-merge";

import configs from "./common.js";
import shakapacker from "./shakapacker.js";
const { dev_server } = shakapacker;

export default configs.map((config, idx) =>
  merge(config, {
    stats: {
      colors: true,
      entrypoints: false,
      errorDetails: true,
      modules: false,
      moduleTrace: false,
    },
    // We only want to set this for one of the configs. If we set it
    // for more than one, we'll get a `ConcurrentCompilationError: You
    // ran Webpack twice. Each instance only supports a single concurrent
    // compilation at a time at MultiCompiler.watch.` The dev server will
    // run correctly for both configurations even if it is only specified
    // once.
    devServer:
      dev_server && process.env.WEBPACK_SERVE === "true" && idx === 0
        ? {
            compress: dev_server.compress,
            allowedHosts: dev_server.allowed_hosts,
            host: process.env.SHAKAPACKER_DEV_SERVER_HOST || dev_server.host,
            port: dev_server.port,
            server: dev_server.server,
            hot: dev_server.hmr,
            liveReload: !dev_server.hmr,
            historyApiFallback: { disableDotRule: true },
            headers: dev_server.headers,
            client: dev_server.client,
            static: { publicPath: config.output.path, ...dev_server.static },
          }
        : undefined,
  }),
);
