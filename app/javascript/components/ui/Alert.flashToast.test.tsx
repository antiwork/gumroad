import * as React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { Alert } from "$app/components/ui/Alert";

// Pages without a React root render their flash toast from these partials, so the markup is
// generated from Alert instead of hand-copied. Regenerate with `npx vitest run -u <this file>`.
const MESSAGE_SLOT = "FLASH_TOAST_MESSAGE";
const statuses = ["success", "danger", "warning", "info"] as const;

describe("server flash toast partials", () => {
  it.each(statuses)("%s matches the Alert markup", async (status) => {
    const markup = renderToStaticMarkup(
      <Alert variant={status} role="status">
        {MESSAGE_SLOT}
      </Alert>,
    );
    expect(markup.split(MESSAGE_SLOT)).toHaveLength(2);

    await expect(
      `<%# Generated from ui/Alert by ui/Alert.flashToast.test.tsx. Do not edit by hand. %>\n${markup.replace(MESSAGE_SLOT, "<%= message %>")}\n`,
    ).toMatchFileSnapshot(`../../../views/layouts/shared/flash/_${status}.html.erb`);
  });
});
