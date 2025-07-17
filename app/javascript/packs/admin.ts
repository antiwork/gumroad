import Clipboard from "clipboard";
import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import AdminNav from "$app/components/server-components/Admin/Nav";
import AdminSalesReportsPage from "$app/components/server-components/Admin/SalesReportsPage";
import AdminSearchPopover from "$app/components/server-components/Admin/SearchPopover";

BasePage.initialize();
ReactOnRails.register({ AdminNav, AdminSearchPopover, AdminSalesReportsPage });

let clipboard: Clipboard | null = null;

// Supplements AdminHelper#copy_to_clipboard.
function registerClipboardHandlers() {
  if (clipboard) {
    clipboard.destroy();
  }

  clipboard = new Clipboard("[data-clipboard-text]");

  clipboard.on("success", (e: Clipboard.Event) => {
    const tooltip = e.trigger.closest(".has-tooltip")?.querySelector<HTMLElement>("[role='tooltip']");

    if (tooltip) {
      const original = tooltip.textContent || "";
      tooltip.textContent = "Copied!";
      setTimeout(() => (tooltip.textContent = original), 2000);
    }

    e.clearSelection();
  });
}

document.addEventListener("DOMContentLoaded", registerClipboardHandlers);
