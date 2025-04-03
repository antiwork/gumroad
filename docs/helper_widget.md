## Helper Widget

We've embedded a Helper widget to assist Gumroad creators with platform-related questions. To run the widget locally, you'll also need to run the Helper app locally. By default, the development environment expects the Helper Next.js server to run on `localhost:3010`. Currently, the Helper host is set to port 3000. You can update the port by modifying `bin/dev` and `apps/nextjs/webpack.sdk.cjs` inside the Helper project to use a different port, such as 3010.

You can update the `HELPER_WIDGET_HOST` in your `.env.development` file to point to a different host if needed.
The widget performs HMAC validation on the email to confirm it's coming from Gumroad. If necessary, you can update the `helper_widget_secret` in the credentials to match the one used by Helper.
