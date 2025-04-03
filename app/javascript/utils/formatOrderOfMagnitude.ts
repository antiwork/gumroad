export const formatOrderOfMagnitude = (num: number, precision: number): string => {
  const item = lookup.find((item) => Math.abs(num) >= item.value);
  if (item == null) {
    return "0";
  }
  const roundedNum = Math.floor((num / item.value) * 10 ** precision) / 10 ** precision;
  return `${roundedNum}${item.symbol}`;
};

const lookup = [
  { value: 1e18, symbol: "E" },
  { value: 1e15, symbol: "P" },
  { value: 1e12, symbol: "T" },
  { value: 1e9, symbol: "G" },
  { value: 1e6, symbol: "M" },
  { value: 1e3, symbol: "K" },
  { value: 1, symbol: "" },
];
