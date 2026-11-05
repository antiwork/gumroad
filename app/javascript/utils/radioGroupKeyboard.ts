import * as React from "react";

// WAI-ARIA radio-group keyboard support. Arrow keys move focus and selection through the group,
// wrapping at the ends, and Home/End jump to the first/last radio; selection follows focus the way
// a native radio group behaves. Pair it with useRadioGroupTabStop, or a tabIndex computed in JSX, so
// the group is one tab stop.
const ARROW_STEPS: Record<string, number> = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 };

// A nested radiogroup's radios belong to that group, not this one.
const ownRadios = (group: HTMLElement) =>
  [...group.querySelectorAll<HTMLElement>('[role="radio"]')].filter(
    (radio) => radio.closest('[role="radiogroup"]') === group,
  );

const enabledRadios = (group: HTMLElement) =>
  ownRadios(group).filter((radio) => !radio.matches(":disabled, [aria-disabled='true']"));

const isChecked = (radio: HTMLElement) =>
  radio.getAttribute("aria-checked") === "true" || (radio instanceof HTMLInputElement && radio.checked);

export const selectAdjacentRadio = (event: React.KeyboardEvent<HTMLElement>) => {
  // Alt+Arrow is browser Back/Forward, and Ctrl/Meta+Arrow belong to the browser or screen reader.
  if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return;
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
  if (!isChecked(radio)) radio.click();
};

// Only the checked radio, or the first enabled one when none is checked, stays reachable with Tab.
// Re-applied on every render because the checked radio moves. Call it from the component that
// renders the group: a group mounted later inside a portal or popover is never seen.
export const useRadioGroupTabStop = (ref: React.RefObject<HTMLElement | null>, enabled = true) => {
  React.useEffect(() => {
    const group = ref.current;
    if (!enabled || !group) return;
    const enabledInGroup = enabledRadios(group);
    const tabStop = enabledInGroup.find(isChecked) ?? enabledInGroup[0];
    ownRadios(group).forEach((radio) => {
      radio.tabIndex = radio === tabStop ? 0 : -1;
    });
  });
};
