import * as React from "react";

import { fetchAccountInfo, fetchCalendarList, getOAuthUrl } from "$app/data/google_calendar_integration";
import { startOauthRedirectChecker } from "$app/utils/oauth";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { useProductEditContext } from "$app/components/ProductEdit/state";
import { showAlert } from "$app/components/server-components/Alert";
import { ToggleSettingRow } from "$app/components/SettingRow";

export type GoogleCalendarIntegration = {
  integration_details: {
    access_token: string;
    refresh_token: string;
    email: string;
    calendar_id: string;
    calendar_summary: string;
  };
} | null;

export const GoogleCalendarIntegrationEditor = ({
  integration,
  onChange,
}: {
  integration: GoogleCalendarIntegration;
  onChange: (integration: GoogleCalendarIntegration) => void;
}) => {
  const [isEnabled, setIsEnabled] = React.useState(!!integration);
  const [isLoading, setIsLoading] = React.useState(false);
  const [calendars, setCalendars] = React.useState<{ id: string; summary: string }[]>(
    integration?.integration_details.calendar_id
      ? [{ id: integration.integration_details.calendar_id, summary: integration.integration_details.calendar_summary }]
      : [],
  );

  const { updateProduct, googleClientId } = useProductEditContext();

  React.useEffect(() => {
    if (integration?.integration_details) {
      const { access_token, refresh_token } = integration.integration_details;
      setIsLoading(true);
      fetchCalendarList(access_token, refresh_token)
        .then(setCalendars)
        .catch((e: unknown) => {
          assertResponseError(e);
          showAlert("Could not fetch calendars, please try again.", "error");
        })
        .finally(() => {
          setIsLoading(false);
        });
    }
  }, [integration]);

  const handleConnectGoogleAccount = () => {
    setIsLoading(true);
    const oauthPopup = window.open(getOAuthUrl(googleClientId), "google_calendar", "popup=yes");
    startOauthRedirectChecker({
      oauthPopup,
      onSuccess: async (code) => {
        try {
          const { accessToken, refreshToken, email } = await fetchAccountInfo(code);
          const calendarList = await fetchCalendarList(accessToken, refreshToken);
          setCalendars(calendarList);
          if (calendarList.length > 0) {
            onChange({
              integration_details: {
                access_token: accessToken,
                refresh_token: refreshToken,
                email,
                calendar_id: calendarList[0]?.id ?? "default",
                calendar_summary: calendarList[0]?.summary ?? "Default",
              },
            });
          }
        } catch (e) {
          assertResponseError(e);
          showAlert("Could not connect to your Google Calendar account, please try again.", "error");
        } finally {
          setIsLoading(false);
        }
      },
      onError: () => {
        showAlert("Could not connect to your Google Calendar account, please try again.", "error");
        setIsLoading(false);
      },
      onPopupClose: () => setIsLoading(false),
    });
  };

  const setEnabledForOptions = (enabled: boolean) =>
    updateProduct((product) => {
      for (const variant of product.variants)
        variant.integrations = { ...variant.integrations, google_calendar: enabled };
    });

  return (
    <ToggleSettingRow
      value={isEnabled}
      onChange={(newValue) => {
        if (newValue) {
          setIsEnabled(true);
          setEnabledForOptions(true);
          handleConnectGoogleAccount();
        } else {
          onChange(null);
          setIsEnabled(false);
          setEnabledForOptions(false);
        }
      }}
      label="Connect with Google Calendar to sync your calls"
      dropdown={
        <div className="flex flex-col gap-4">
          {isLoading ? (
            <LoadingSpinner />
          ) : integration ? (
            <>
              <p>
                People who purchase your product will automatically receive a Google Calendar invite and we'll keep your
                calendar in sync.
              </p>
              <label htmlFor="google-account">Google account</label>
              <input id="google-account" type="text" value={integration.integration_details.email} readOnly />
              <label htmlFor="calendar-select">Choose calendar</label>
              <select
                id="calendar-select"
                value={integration.integration_details.calendar_id}
                onChange={(e) => {
                  const selectedCalendar = calendars.find((c) => c.id === e.target.value);
                  if (selectedCalendar) {
                    onChange({
                      integration_details: {
                        ...integration.integration_details,
                        calendar_id: selectedCalendar.id,
                        calendar_summary: selectedCalendar.summary,
                      },
                    });
                  }
                }}
              >
                {calendars.map((calendar) => (
                  <option key={calendar.id} value={calendar.id}>
                    {calendar.summary}
                  </option>
                ))}
              </select>
              <Button color="danger" onClick={() => onChange(null)}>
                Disconnect Google Calendar
              </Button>
            </>
          ) : (
            <>
              <p>
                People who purchase your product will automatically receive a Google Calendar invite and we'll keep your
                calendar in sync.
              </p>
              <Button className="button-google" onClick={handleConnectGoogleAccount}>
                Connect to Google Calendar
              </Button>
            </>
          )}
        </div>
      }
    />
  );
};
