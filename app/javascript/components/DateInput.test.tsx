// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { parseISO } from "date-fns";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { CurrentSeller, CurrentSellerProvider } from "$app/components/CurrentSeller";
import { DateInput } from "$app/components/DateInput";

afterEach(cleanup);

const seller = (timeZone: string): CurrentSeller => ({
  id: "seller-1",
  email: "seller@example.com",
  name: "Local QA",
  subdomain: "localqa",
  avatarUrl: "",
  isBuyer: false,
  timeZone: { name: timeZone, offset: 0 },
  has_published_products: true,
  can_publish_products: true,
  publishBlockedReason: null,
  noPayoutRailInComplianceCountry: false,
  legalGuardianRequirementMet: true,
  legalGuardianUnsupported: false,
  isNameInvalidForEmailDelivery: false,
  profileBackgroundColor: "#ffffff",
  profileHighlightColor: "#000000",
  profileFont: "Inter",
});

const DateField = ({
  currentSeller,
  withTime,
  onChange,
}: {
  currentSeller: CurrentSeller | null;
  withTime?: true;
  onChange: (value: Date | null) => void;
}) => {
  const [value, setValue] = React.useState<Date | null>(new Date("2027-03-13T12:00:00Z"));
  return (
    <CurrentSellerProvider value={currentSeller}>
      <DateInput
        aria-label="Schedule date"
        value={value}
        {...(withTime ? { withTime: true as const } : {})}
        onChange={(next) => {
          onChange(next);
          setValue(next);
        }}
      />
    </CurrentSellerProvider>
  );
};

const enterDate = (value: string) => {
  const input = screen.getByLabelText<HTMLInputElement>("Schedule date");
  fireEvent.change(input, { target: { value } });
  fireEvent.blur(input);
  return input;
};

describe("DateInput seller time", () => {
  it("keeps four-digit years in seller datetime values and bounds", () => {
    render(
      <CurrentSellerProvider value={seller("UTC")}>
        <DateInput
          aria-label="Schedule date"
          withTime
          value={new Date("0999-01-02T12:30:00Z")}
          min={new Date("0999-01-01T12:00:00Z")}
        />
      </CurrentSellerProvider>,
    );

    const input = screen.getByLabelText<HTMLInputElement>("Schedule date");
    expect(input.value).toBe("0999-01-02T12:30");
    expect(input.min).toBe("0999-01-01T12:00");
  });

  it("displays seller datetime values and bounds without the browser's DST normalization", () => {
    render(
      <CurrentSellerProvider value={seller("UTC")}>
        <DateInput
          aria-label="Schedule date"
          withTime
          value={new Date("2027-03-14T02:30:00Z")}
          min={new Date("2027-03-14T02:00:00Z")}
          max={new Date("2027-03-14T02:59:00Z")}
        />
      </CurrentSellerProvider>,
    );

    const input = screen.getByLabelText<HTMLInputElement>("Schedule date");
    expect(input.value).toBe("2027-03-14T02:30");
    expect(input.min).toBe("2027-03-14T02:00");
    expect(input.max).toBe("2027-03-14T02:59");
  });

  it.each([
    ["UTC", "2027-03-14T02:30:00.000Z"],
    ["Asia/Kolkata", "2027-03-13T21:00:00.000Z"],
    ["Europe/Berlin", "2027-03-14T01:30:00.000Z"],
    ["Australia/Sydney", "2027-03-13T15:30:00.000Z"],
  ])("retains a valid %s wall clock during the browser's DST gap", (timeZone, expected) => {
    const onChange = vi.fn();
    render(<DateField currentSeller={seller(timeZone)} withTime onChange={onChange} />);

    const input = enterDate("2027-03-14T02:30");

    expect(onChange).toHaveBeenCalledExactlyOnceWith(new Date(expected));
    expect(input.value).toBe("2027-03-14T02:30");
  });

  it("converts an ordinary seller wall clock to its UTC instant", () => {
    const onChange = vi.fn();
    render(<DateField currentSeller={seller("Asia/Kolkata")} withTime onChange={onChange} />);

    const input = enterDate("2027-01-15T09:45");

    expect(onChange).toHaveBeenCalledExactlyOnceWith(new Date("2027-01-15T04:15:00Z"));
    expect(input.value).toBe("2027-01-15T09:45");
  });

  it("keeps the timezone library's selection for an ambiguous seller wall clock", () => {
    const onChange = vi.fn();
    render(<DateField currentSeller={seller("America/Los_Angeles")} withTime onChange={onChange} />);

    const input = enterDate("2027-11-07T01:30");

    expect(onChange).toHaveBeenCalledExactlyOnceWith(new Date("2027-11-07T08:30:00Z"));
    expect(input.value).toBe("2027-11-07T01:30");
  });

  it("clears an empty datetime", () => {
    const onChange = vi.fn();
    render(<DateField currentSeller={seller("UTC")} withTime onChange={onChange} />);

    enterDate("");

    expect(onChange).toHaveBeenCalledExactlyOnceWith(null);
  });

  it("rejects a datetime before the supported year", () => {
    const onChange = vi.fn();
    render(<DateField currentSeller={seller("UTC")} withTime onChange={onChange} />);

    enterDate("0001-01-01T12:00");

    expect(onChange).toHaveBeenCalledExactlyOnceWith(null);
  });

  it("keeps date-only values in the browser's local calendar", () => {
    const onChange = vi.fn();
    render(<DateField currentSeller={seller("Asia/Kolkata")} onChange={onChange} />);

    const input = enterDate("2027-03-14");

    expect(onChange).toHaveBeenCalledExactlyOnceWith(parseISO("2027-03-14"));
    expect(input.value).toBe("2027-03-14");
  });

  it("keeps datetime values in the browser timezone without a seller", () => {
    const onChange = vi.fn();
    render(<DateField currentSeller={null} withTime onChange={onChange} />);

    enterDate("2027-03-14T02:30");

    expect(onChange).toHaveBeenCalledExactlyOnceWith(parseISO("2027-03-14T02:30"));
  });
});
