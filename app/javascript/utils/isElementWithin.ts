export const isElementWithin = (target: Element, els: (HTMLElement | null)[]) => els.some((el) => el?.contains(target));
