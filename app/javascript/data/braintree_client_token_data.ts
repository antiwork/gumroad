import * as React from "react";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

const fetchBraintreeClientToken = async (): Promise<{ clientToken: string | null }> => {
  const response = await request({ url: Routes.braintree_client_token_path(), method: "GET", accept: "json" });
  return cast<{ clientToken: string | null }>(await response.json());
};

const BRAINTREE_TOKEN_VALIDITY_MS = 12 * 60 * 60 * 1000; // 12 hrs
const BRAINTREE_TOKEN_MAX_RETRIES = 3;
const BRAINTREE_TOKEN_RETRY_IN_MS = 1 * 60 * 1000; // 1 min
export type BraintreeFetcherReturnValue = { abort: () => void };
export const fetchBraintreeClientTokenWithRetriesAndRefetch = ({
  onError,
  onDone,
}: {
  onError: () => void;
  onDone: (token: { clientToken: string }) => void;
}): BraintreeFetcherReturnValue => {
  let isRelevant = true;

  let retries = 0;
  let retryTimeout: null | ReturnType<typeof setTimeout> = null;
  let refetchTimeout: null | ReturnType<typeof setTimeout> = null;

  const triggerFetchToken = async () => {
    if (!isRelevant) return;

    const token = await fetchBraintreeClientToken().catch(() => ({ clientToken: null }));

    if (token.clientToken == null) {
      if (retries >= BRAINTREE_TOKEN_MAX_RETRIES) {
        onError();
      } else {
        retries += 1;
        retryTimeout = setTimeout(() => {
          void triggerFetchToken();
          retryTimeout = null;
        }, BRAINTREE_TOKEN_RETRY_IN_MS);
      }
    } else {
      retries = 0;
      onDone({ clientToken: token.clientToken });

      refetchTimeout = setTimeout(() => {
        void triggerFetchToken();
        refetchTimeout = null;
      }, BRAINTREE_TOKEN_VALIDITY_MS);
    }
  };

  void triggerFetchToken();

  return {
    abort: () => {
      isRelevant = false;
      if (retryTimeout != null) {
        clearTimeout(retryTimeout);
      }
      if (refetchTimeout != null) {
        clearTimeout(refetchTimeout);
      }
    },
  };
};

type BraintreeToken = { type: "not-available" } | { type: "loading" } | { type: "available"; token: string };
export const useBraintreeToken = (isSupported: boolean): BraintreeToken => {
  const [token, setToken] = React.useState<BraintreeToken>({ type: "not-available" });
  const braintreeTokenFetcherRef = React.useRef<BraintreeFetcherReturnValue | null>(null);

  React.useEffect(() => {
    if (isSupported) {
      if (braintreeTokenFetcherRef.current != null) return;
      setToken({ type: "loading" });
      braintreeTokenFetcherRef.current = fetchBraintreeClientTokenWithRetriesAndRefetch({
        onError: () => setToken({ type: "not-available" }),
        onDone: (token) => setToken({ type: "available", token: token.clientToken }),
      });
    }
  }, [isSupported]);
  // When unmounting, stop continuous token updates & error retries
  React.useEffect(
    () => () => {
      if (braintreeTokenFetcherRef.current != null) {
        braintreeTokenFetcherRef.current.abort();
        braintreeTokenFetcherRef.current = null;
      }
    },
    [],
  );

  // `isSupported=false` does _not_ reset the `token` in order to ensure we can more quickly reuse it later on if `isSupported` is flipped back to `true`
  const exposedToken: BraintreeToken = React.useMemo(
    () => (isSupported ? token : { type: "not-available" }),
    [isSupported, token],
  );
  return exposedToken;
};
