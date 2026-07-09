// Remembers which email addresses the buyer has already told us are correct ("No" on the
// "Did you mean ...?" checkout popover). Without persistence the dismissal only lived in
// component state, so a returning buyer was re-asked about the same address on every visit.
// Stored in localStorage; all access is wrapped in try/catch because localStorage can throw
// (Safari private browsing, disabled storage) and the suggester must degrade gracefully.

const STORAGE_KEY = "gr_checkout_acknowledged_emails";
const MAX_STORED_EMAILS = 50;

export const loadAcknowledgedEmails = (): Set<string> => {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return new Set();
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return new Set();
    return new Set(parsed.filter((item): item is string => typeof item === "string"));
  } catch {
    return new Set();
  }
};

export const persistAcknowledgedEmail = (email: string): void => {
  try {
    const emails = [...loadAcknowledgedEmails()].filter((stored) => stored !== email);
    emails.push(email);
    // Cap the list so one shared/kiosk browser can't grow the entry unboundedly.
    localStorage.setItem(STORAGE_KEY, JSON.stringify(emails.slice(-MAX_STORED_EMAILS)));
  } catch {
    // Persistence is best-effort; the in-memory dismissal still works for this page load.
  }
};
