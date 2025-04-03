// Utility to disable interactive elements for team members that have read-only access (View only)
// TEAM_READ_ONLY_SELECTOR can be applied to either the interactive element that needs to be disabled,
// or a parent element that contains the interactive element.
// To see usage example, search for the value of TEAM_READ_ONLY_SELECTOR in the codebase
//
export function initTeamMemberReadOnlyAccess() {
  const topLevelContainer = document.body;

  // On initial load, some elements may already have TEAM_READ_ONLY_SELECTOR set.
  handleExistingReadOnlyElements(topLevelContainer);
  // This observers if any new elements having TEAM_READ_ONLY_SELECTOR are added to the DOM.
  observeForNewReadOnlyElements(topLevelContainer);
}

const TEAM_READ_ONLY_SELECTOR = ".js-team-member-read-only";
const INTERACTIVE_ELEMENTS = ["input", "select", "textarea", "button", "a.button"];

function handleExistingReadOnlyElements(container: HTMLElement) {
  const nodeList = container.querySelectorAll(TEAM_READ_ONLY_SELECTOR);

  Array.from(nodeList)
    .filter((element): element is HTMLElement => element instanceof HTMLElement)
    .forEach((container) => {
      handleAndObserveReadOnlyElement(container);
    });
}

function observeForNewReadOnlyElements(container: HTMLElement) {
  new MutationObserver((mutationsList) => {
    mutationsList.forEach((mutation) => {
      mutation.addedNodes.forEach((element) => {
        if (element instanceof HTMLElement && element.matches(TEAM_READ_ONLY_SELECTOR)) {
          handleAndObserveReadOnlyElement(element);
        }
      });
    });
  }).observe(container, { childList: true, subtree: true });
}

function handleAndObserveReadOnlyElement(element: HTMLElement) {
  // This applies when the interactive element has TEAM_READ_ONLY_SELECTOR set.
  disableInteractiveElements(element);

  new MutationObserver((mutationsList) => {
    mutationsList.forEach((mutation) => {
      mutation.addedNodes.forEach((element) => {
        if (element instanceof HTMLElement) {
          disableInteractiveElements(element);
        }
      });
    });
  }).observe(element, { childList: true, subtree: true });
}

function disableInteractiveElements(container: HTMLElement): void {
  const elements = isInteractiveElement(container) ? [container] : [];
  const childElements = container.querySelectorAll(INTERACTIVE_ELEMENTS.join(", "));
  const allElements = [...elements, ...childElements];

  for (const element of allElements) {
    if (element instanceof HTMLInputElement) disableInteractiveElement(element);
  }
}

function disableInteractiveElement(element: HTMLInputElement): void {
  if (element.hasAttribute("disabled")) return;

  element.disabled = true;
  const inputWrapper = element.closest(".input");
  if (inputWrapper) {
    inputWrapper.classList.add("disabled");
  }
}

function isInteractiveElement(element: HTMLElement) {
  const tagName = element.tagName.toLowerCase();
  return (tagName === "a" && element.classList.contains("button")) || INTERACTIVE_ELEMENTS.includes(tagName);
}
