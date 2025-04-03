export const formatStatNumber = ({
  value,
  suffix = "",
  placeholder = "--",
}: {
  value: number | null;
  placeholder?: string;
  suffix?: string;
}) => (value === null ? placeholder : `${value.toLocaleString()}${suffix}`);
