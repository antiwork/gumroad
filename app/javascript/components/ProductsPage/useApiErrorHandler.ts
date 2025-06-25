import { AbortError, assertResponseError } from "$app/utils/request";
import { showAlert } from "$app/components/server-components/Alert";

export const useApiErrorHandler = () => {
  return (error: unknown, setLoading?: (loading: boolean) => void) => {
    if (error instanceof AbortError) return;
    assertResponseError(error);
    setLoading?.(false);
    showAlert(error.message, "error");
  };
};