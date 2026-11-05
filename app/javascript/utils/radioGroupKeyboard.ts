import type { KeyboardEvent as ReactKeyboardEvent } from "react";

// WAI-ARIA radio-group keyboard support. Arrow keys move focus and selection through the group,
// wrapping at the ends, and Home/End jump to the first/last radio; selection follows focus the way
// a native radio group behaves. Pair it with a roving tabIndex so the group is one tab stop.
const ARROW_STEPS: Record<string, number> = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 };

export const enabledRadios = (group: HTMLElement) =>
  [...group.querySelectorAll<HTMLElement>('[role="radio"]')].filter(
    (radio) => !radio.matches(":disabled, [aria-disabled='true']"),
  );

export const selectAdjacentRadio = (event: ReactKeyboardEvent<HTMLElement>) => {
  const step = ARROW_STEPS[event.key];
  if (step === undefined && event.key !== "Home" && event.key !== "End") return;
  const radios = enabledRadios(event.currentTarget);
  const index = radios.findIndex((radio) => radio === event.target);
  if (index === -1) return;
  event.preventDefault();
  const indexToFocus =
    event.key === "Home"
      ? 0
      : event.key === "End"
        ? radios.length - 1
        : (index + (step ?? 0) + radios.length) % radios.length;
  const radio = radios[indexToFocus];
  if (!radio) return;
  radio.focus();
  // Clicking a radio that is already checked re-runs its handler; for a custom-amount choice that
  // clears the price the buyer typed.
  const checked = radio.getAttribute("aria-checked") === "true" || (radio instanceof HTMLInputElement && radio.checked);
  if (!checked) radio.click();
};
