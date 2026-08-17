import * as React from "react";

import { useRefToLatest } from "$app/components/useRefToLatest";

type ActiveCall<TKey, TResult> = {
  key: TKey;
  promise: Promise<TResult>;
};

type QueuedCall<TResult> = {
  promise: Promise<TResult>;
  resolve: (value: TResult | PromiseLike<TResult>) => void;
  reject: (reason?: unknown) => void;
};

// Same-key calls share the active request. An approved result releases one changed-key call after
// React commits the response, so that call uses any canonical ids returned by the server.
export const useDedupeInFlight = <TKey, TResult>(
  key: TKey,
  fn: () => Promise<TResult>,
  shouldStartQueued: (result: TResult) => boolean,
): ((forceQueue?: boolean) => Promise<TResult>) => {
  const fnRef = useRefToLatest(fn);
  const shouldStartQueuedRef = useRefToLatest(shouldStartQueued);
  const activeRef = React.useRef<ActiveCall<TKey, TResult> | null>(null);
  const queuedRef = React.useRef<QueuedCall<TResult> | null>(null);
  const [settledVersion, setSettledVersion] = React.useState(0);

  const start = React.useCallback(
    (invocationKey: TKey) => {
      const promise = Promise.resolve().then(() => fnRef.current());
      activeRef.current = { key: invocationKey, promise };

      const settle = (result: TResult) => {
        if (activeRef.current?.promise !== promise) return;
        activeRef.current = null;
        const queued = queuedRef.current;
        if (!queued) return;

        if (shouldStartQueuedRef.current(result)) setSettledVersion((version) => version + 1);
        else {
          queuedRef.current = null;
          queued.resolve(result);
        }
      };
      const rejectQueued = (reason: unknown) => {
        if (activeRef.current?.promise !== promise) return;
        activeRef.current = null;
        const queued = queuedRef.current;
        queuedRef.current = null;
        queued?.reject(reason);
      };
      void promise.then(settle, rejectQueued);
      return promise;
    },
    [fnRef, shouldStartQueuedRef],
  );

  React.useEffect(() => {
    const queued = queuedRef.current;
    if (!queued || activeRef.current) return;

    queuedRef.current = null;
    void start(key).then(queued.resolve, queued.reject);
  }, [key, settledVersion, start]);

  return React.useCallback((forceQueue = false) => {
    const active = activeRef.current;
    if (!active) {
      if (queuedRef.current) return queuedRef.current.promise;
      return start(key);
    }
    if (!forceQueue && !queuedRef.current && Object.is(active.key, key)) return active.promise;
    if (queuedRef.current) return queuedRef.current.promise;

    let resolve: QueuedCall<TResult>["resolve"] = () => {};
    let reject: QueuedCall<TResult>["reject"] = () => {};
    const promise = new Promise<TResult>((resolvePromise, rejectPromise) => {
      resolve = resolvePromise;
      reject = rejectPromise;
    });
    queuedRef.current = { promise, resolve, reject };
    return promise;
  }, [key, start]);
};
