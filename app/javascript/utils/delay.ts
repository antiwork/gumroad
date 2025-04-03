export const delay = (function () {
  let timer: ReturnType<typeof setTimeout> | null = null;
  return function (callback: () => void, ms: number) {
    if (timer) clearTimeout(timer);
    timer = setTimeout(callback, ms);
  };
})();
