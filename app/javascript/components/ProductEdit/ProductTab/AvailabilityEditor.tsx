import { fromZonedTime, toZonedTime, format } from "date-fns-tz";
import * as React from "react";

import { Button } from "$app/components/Button";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { DateInput } from "$app/components/DateInput";
import { Icon } from "$app/components/Icons";
import { Availability } from "$app/components/ProductEdit/state";
import Placeholder from "$app/components/ui/Placeholder";

const DEFAULT_INTERVAL_START_HOURS = 9;
const DEFAULT_INTERVAL_LENGTH = 8;

let newAvailabilityId = 0;

type ParsedAvailability = Omit<Availability, "start_time" | "end_time"> & { start_time: Date; end_time: Date };

const formatTime = (date: Date) => format(date, "HH:mm");

const setTime = (date: Date, timeString: string) => {
  const [hours, minutes] = timeString.split(":").map(Number);
  if (hours == null || minutes == null) return date;

  const updatedDate = new Date(date);
  updatedDate.setHours(hours, minutes, 0, 0);

  return updatedDate;
};

export const AvailabilityEditor = ({
  availabilities: serializedAvailabilities,
  onChange,
}: {
  availabilities: Availability[];
  onChange: (availabilities: Availability[]) => void;
}) => {
  const seller = useCurrentSeller();
  if (!seller) return;
  const timeZone = seller.timeZone.name;

  const availabilities = serializedAvailabilities.map((availability) => ({
    ...availability,
    start_time: toZonedTime(new Date(availability.start_time), timeZone),
    end_time: toZonedTime(new Date(availability.end_time), timeZone),
  }));

  const groupedAvailabilities = availabilities
    .reduce((acc: ParsedAvailability[][], availability) => {
      const existingGroup = acc.find(
        (group) => group[0]?.start_time.toDateString() === availability.start_time.toDateString(),
      );
      if (existingGroup) existingGroup.push(availability);
      else acc.push([availability]);
      return acc;
    }, [])
    .map((group) => group.sort((a, b) => a.start_time.getTime() - b.start_time.getTime()))
    .sort((a, b) => (a[0]?.start_time.getTime() ?? 0) - (b[0]?.start_time.getTime() ?? 0));

  const serializeDate = (date: Date) => fromZonedTime(date.toISOString(), timeZone).toISOString();

  const addAvailability = (date: Date, intervalInHours = 1) => {
    date.setMinutes(0, 0, 0);
    const startTime = new Date(date);
    const endTime = new Date(date.setHours(date.getHours() + intervalInHours));

    onChange([
      ...serializedAvailabilities,
      {
        id: (newAvailabilityId++).toString(),
        start_time: serializeDate(startTime),
        end_time: serializeDate(endTime),
        newlyAdded: true,
      },
    ]);
  };

  const updateAvailability = (id: string, update: Partial<ParsedAvailability>) =>
    onChange(
      serializedAvailabilities.map((availability) =>
        availability.id === id
          ? {
              ...availability,
              ...(update.start_time && { start_time: serializeDate(update.start_time) }),
              ...(update.end_time && { end_time: serializeDate(update.end_time) }),
            }
          : availability,
      ),
    );

  const lastAvailabilityStartTime = groupedAvailabilities[groupedAvailabilities.length - 1]?.[0]?.start_time;

  return availabilities.length ? (
    <>
      <section style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr auto auto", gap: "var(--spacer-2)" }}>
        <b>Date</b>
        <b>From</b>
        <b>To</b>
        <span />
        <span />
        {groupedAvailabilities.map((group, idx) => {
          const lastGroupEndTime = group[group.length - 1]?.end_time;
          return (
            <section style={{ display: "contents" }} aria-label={group[0]?.start_time.toLocaleDateString()} key={idx}>
              {group.map((availability, idx) => (
                <section key={availability.id} aria-label={`Availability ${idx + 1}`} style={{ display: "contents" }}>
                  {idx === 0 ? (
                    <DateInput
                      value={availability.start_time}
                      onChange={(value) => {
                        if (value) {
                          const updatedStartTime = new Date(availability.start_time);
                          updatedStartTime.setFullYear(value.getFullYear(), value.getMonth(), value.getDate());

                          const updatedEndTime = new Date(availability.end_time);
                          updatedEndTime.setFullYear(value.getFullYear(), value.getMonth(), value.getDate());

                          updateAvailability(availability.id, {
                            start_time: updatedStartTime,
                            end_time: updatedEndTime,
                          });
                        }
                      }}
                      aria-label="Date"
                    />
                  ) : (
                    <span />
                  )}
                  <input
                    type="time"
                    value={formatTime(availability.start_time)}
                    onChange={(evt) =>
                      updateAvailability(availability.id, {
                        start_time: setTime(availability.start_time, evt.target.value),
                      })
                    }
                    aria-label="From"
                  />
                  <input
                    type="time"
                    value={formatTime(availability.end_time)}
                    onChange={(evt) =>
                      updateAvailability(availability.id, {
                        end_time: setTime(availability.end_time, evt.target.value),
                      })
                    }
                    aria-label="To"
                  />
                  <Button
                    onClick={() => onChange(serializedAvailabilities.filter(({ id }) => availability.id !== id))}
                    aria-label="Delete hours"
                  >
                    <Icon name="trash2" />
                  </Button>
                  {idx === 0 ? (
                    <Button onClick={() => addAvailability(lastGroupEndTime ?? new Date())} aria-label="Add hours">
                      <Icon name="plus" />
                    </Button>
                  ) : (
                    <span />
                  )}
                </section>
              ))}
            </section>
          );
        })}
      </section>
      <AddButton
        onClick={() => {
          let date = new Date();
          if (lastAvailabilityStartTime) {
            date = lastAvailabilityStartTime;
            date.setDate(date.getDate() + 1);
            date.setHours(DEFAULT_INTERVAL_START_HOURS);
          }
          addAvailability(date, DEFAULT_INTERVAL_LENGTH);
        }}
      />
    </>
  ) : (
    <Placeholder>
      <h2>Add day of availability</h2>
      Adjust your availability to reflect specific dates and times
      <AddButton
        onClick={() => {
          const date = new Date();
          date.setHours(DEFAULT_INTERVAL_START_HOURS);
          addAvailability(date, DEFAULT_INTERVAL_LENGTH);
        }}
      />
    </Placeholder>
  );
};

const AddButton = ({ onClick }: { onClick: () => void }) => (
  <Button color="primary" onClick={onClick}>
    <Icon name="plus" />
    Add day of availability
  </Button>
);
