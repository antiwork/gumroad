import { Plus, Trash } from "@boxicons/react";
import { addHours, differenceInCalendarDays } from "date-fns";
import { fromZonedTime } from "date-fns-tz";
import * as React from "react";

import { Button } from "$app/components/Button";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { DateInput } from "$app/components/DateInput";
import { Availability } from "$app/components/ProductEdit/state";
import { Input } from "$app/components/ui/Input";
import { Placeholder } from "$app/components/ui/Placeholder";

const DEFAULT_INTERVAL_START_HOURS = 9;
const DEFAULT_INTERVAL_LENGTH = 8;

let newAvailabilityId = 0;

type ParsedAvailability = Omit<Availability, "start_time" | "end_time"> & { start_time: Date; end_time: Date };

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
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  });
  const zonedParts = (date: Date) => {
    const fields = Object.fromEntries(formatter.formatToParts(date).map(({ type, value }) => [type, value]));
    return { date: `${fields.year}-${fields.month}-${fields.day}`, time: `${fields.hour}:${fields.minute}` };
  };
  const calendarDate = (date: Date) => new Date(`${zonedParts(date).date}T12:00:00`);
  const formatTime = (date: Date) => zonedParts(date).time;
  const setTime = (date: Date, timeString: string) =>
    timeString ? fromZonedTime(`${zonedParts(date).date}T${timeString}`, timeZone) : date;
  const shiftDate = (date: Date, days: number) => {
    const parts = zonedParts(date);
    // UTC calendar arithmetic avoids the browser's DST gaps.
    const wallTime = new Date(`${parts.date}T${parts.time}Z`);
    wallTime.setUTCDate(wallTime.getUTCDate() + days);
    return fromZonedTime(wallTime.toISOString().slice(0, -1), timeZone).toISOString();
  };

  const availabilities = serializedAvailabilities.map((availability) => ({
    ...availability,
    start_time: new Date(availability.start_time),
    end_time: new Date(availability.end_time),
  }));

  const groupedAvailabilities = availabilities
    .reduce((acc: ParsedAvailability[][], availability) => {
      const existingGroup = acc.find(
        (group) => group[0] && zonedParts(group[0].start_time).date === zonedParts(availability.start_time).date,
      );
      if (existingGroup) existingGroup.push(availability);
      else acc.push([availability]);
      return acc;
    }, [])
    .map((group) => group.sort((a, b) => a.start_time.getTime() - b.start_time.getTime()))
    .sort((a, b) => (a[0]?.start_time.getTime() ?? 0) - (b[0]?.start_time.getTime() ?? 0));

  const serializeDate = (date: Date) => date.toISOString();

  const addAvailability = (date: Date, intervalInHours = 1) => {
    const parts = zonedParts(date);
    const startTime = new Date(`${parts.date}T${parts.time.slice(0, 2)}:00:00Z`);
    const endTime = addHours(startTime, intervalInHours);

    onChange([
      ...serializedAvailabilities,
      {
        id: (newAvailabilityId++).toString(),
        start_time: fromZonedTime(startTime.toISOString().slice(0, -1), timeZone).toISOString(),
        end_time: fromZonedTime(endTime.toISOString().slice(0, -1), timeZone).toISOString(),
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
  const addDay = () => {
    const date = new Date(`${zonedParts(lastAvailabilityStartTime ?? new Date()).date}T00:00:00Z`);
    if (lastAvailabilityStartTime) date.setUTCDate(date.getUTCDate() + 1);
    date.setUTCHours(DEFAULT_INTERVAL_START_HOURS);
    addAvailability(fromZonedTime(date.toISOString().slice(0, -1), timeZone), DEFAULT_INTERVAL_LENGTH);
  };

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
            <section
              style={{ display: "contents" }}
              aria-label={group[0] ? calendarDate(group[0].start_time).toLocaleDateString() : undefined}
              key={idx}
            >
              {group.map((availability, idx) => (
                <section key={availability.id} aria-label={`Availability ${idx + 1}`} style={{ display: "contents" }}>
                  {idx === 0 ? (
                    <DateInput
                      value={calendarDate(availability.start_time)}
                      onChange={(value) => {
                        if (!value) return;

                        const days = differenceInCalendarDays(value, calendarDate(availability.start_time));
                        if (days === 0) return;
                        const updatedDay = new Map(
                          group.map((interval) => [
                            interval.id,
                            {
                              ...interval,
                              start_time: shiftDate(interval.start_time, days),
                              end_time: shiftDate(interval.end_time, days),
                            },
                          ]),
                        );
                        onChange(serializedAvailabilities.map((interval) => updatedDay.get(interval.id) ?? interval));
                      }}
                      aria-label="Date"
                    />
                  ) : (
                    <span />
                  )}
                  <Input
                    type="time"
                    value={formatTime(availability.start_time)}
                    onChange={(evt) =>
                      updateAvailability(availability.id, {
                        start_time: setTime(availability.start_time, evt.target.value),
                      })
                    }
                    aria-label="From"
                  />
                  <Input
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
                    <Trash className="size-5" />
                  </Button>
                  {idx === 0 ? (
                    <Button onClick={() => addAvailability(lastGroupEndTime ?? new Date())} aria-label="Add hours">
                      <Plus className="size-5" />
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
      <AddButton onClick={addDay} />
    </>
  ) : (
    <Placeholder>
      <h2>Add day of availability</h2>
      Adjust your availability to reflect specific dates and times
      <AddButton onClick={addDay} />
    </Placeholder>
  );
};

const AddButton = ({ onClick }: { onClick: () => void }) => (
  <Button color="primary" onClick={onClick}>
    <Plus className="size-5" />
    Add day of availability
  </Button>
);
