/**
 * Avoid exceptions when localStorage is not accessible.
 * This may occur due to browser settings.
 */
export function isLocalStorageAccessible() {
  try {
    const testKey = "gumroad_local_storage_test_key";

    localStorage.setItem(testKey, "true");
    localStorage.removeItem(testKey);

    return true;
  } catch {
    return false;
  }
}
