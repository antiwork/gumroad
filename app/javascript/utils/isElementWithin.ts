export const isElementWithin = (target: HTMLElement, els: (HTMLElement | null)[]) =>
  els.some((el) => el?.contains(target));
