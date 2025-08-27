## Helper Widget

We've embedded a support portal using the Helper API to assist Gumroad creators with platform-related questions. To run the widget locally, you'll also need to run the [Helper](https://github.com/antiwork/helper) app locally.

Once you have Helper working, you can run it alongside Gumroad by doing the following:

1. Create or update your `.env` file with the following:
   ```
   HELPER_WIDGET_HOST=https://helperai.dev
   # If you aren't using the default seeds for Helper, change this to your own widgetHMACSecret.
   HELPER_WIDGET_SECRET=9cff9d28-7333-4e29-8f01-c2945f1a887f
   ```
2. Re-run `bin/generate_ssl_certificates` in Gumroad.
3. Run `make local` in Gumroad. (It's important to run this **before** starting either Gumroad or Helper.)
   - If you get errors, try running `pnpm nginx:stop` in Helper first.
4. Run `bin/dev` in Gumroad.
5. Run `pnpm dev` in Helper.

The Helper app will be available at `https://helperai.dev`, and the integrated support portal will be available at `https://gumroad.dev/support`.
