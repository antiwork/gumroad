import ReactOnRails from "react-on-rails";
import { cast } from "ts-safe-cast";

import { startTrackingForGumroad } from "$app/data/google_analytics";
import { defaults as requestDefaults } from "$app/utils/request";

import Alert from "$app/components/server-components/Alert";
import Nav from "$app/components/server-components/Nav";
import FirebaseGoogleLogin from "$app/components/Authentication/FirebaseGoogleLogin";
import DirectLoginButton from "$app/components/Authentication/DirectLoginButton";

const BasePage = {
  initialize() {
    const csrfToken = cast<string>($("meta[name=csrf-token]").attr("content"));
    $(document).ajaxSend((_, xhr) => {
      // add CSRF header to all AJAX requests
      xhr.setRequestHeader("X-CSRF-Token", csrfToken);
    });
    requestDefaults.headers = { "X-CSRF-Token": csrfToken };

        // Suppress all console errors and warnings for cleaner development experience
    window.addEventListener("unhandledrejection", (event) => {
      event.preventDefault(); // Just suppress them
    });

    window.addEventListener("error", (event) => {
      event.preventDefault(); // Suppress all errors
    });

    // Override console methods to reduce noise
    const originalConsoleError = console.error;
    const originalConsoleWarn = console.warn;

    console.error = (...args) => {
      // Only log actual application errors, not extension/external script errors
      const message = args[0]?.toString() || '';
      if (!message.includes('ethereum') &&
          !message.includes('evmAsk') &&
          !message.includes('chrome-extension') &&
          !message.includes('Failed to load resource')) {
        originalConsoleError.apply(console, args);
      }
    };

    console.warn = (...args) => {
      const message = args[0]?.toString() || '';
      if (!message.includes('ethereum') &&
          !message.includes('evmAsk') &&
          !message.includes('chrome-extension')) {
        originalConsoleWarn.apply(console, args);
      }
    };

    // Handle ethereum property safely
    try {
      // Just ignore any ethereum-related errors completely
      if (typeof window !== 'undefined') {
        Object.defineProperty(window, '__ethereum_handled', { value: true });
      }
    } catch (e) {
      // Ignore all ethereum errors
    }

    ReactOnRails.register({ Nav, Alert, FirebaseGoogleLogin, DirectLoginButton });

    startTrackingForGumroad();
  },
};

export default BasePage;
