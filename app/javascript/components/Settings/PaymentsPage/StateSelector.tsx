import * as React from "react";

interface StateSelectorProps {
  country: string | null;
  uid: string;
  value: string | null;
  isFormDisabled: boolean;
  hasError: boolean;
  onChange: (value: string) => void;
  required?: boolean;
  states: {
    us: { code: string; name: string }[];
    ca: { code: string; name: string }[];
    au: { code: string; name: string }[];
    mx: { code: string; name: string }[];
    ae: { code: string; name: string }[];
    ir: { code: string; name: string }[];
    br: { code: string; name: string }[];
  };
}

const StateSelector: React.FC<StateSelectorProps> = ({
  country,
  uid,
  value,
  isFormDisabled,
  hasError,
  onChange,
  required = false,
  states,
}) => {
  const getStateConfig = (country: string) => {
    switch (country) {
      case "US":
        return {
          id: "state",
          label: "State",
          placeholder: "State",
          options: states.us,
        };
      case "CA":
        return {
          id: "province",
          label: "Province",
          placeholder: "Province",
          options: states.ca,
        };
      case "AU":
        return {
          id: "state",
          label: "State",
          placeholder: "State",
          options: states.au,
        };
      case "MX":
        return {
          id: "state",
          label: "State",
          placeholder: "State",
          options: states.mx,
        };
      case "AE":
        return {
          id: "province",
          label: "Province",
          placeholder: "Province",
          options: states.ae,
        };
      case "IE":
        return {
          id: "county",
          label: "County",
          placeholder: "County",
          options: states.ir,
        };
      case "BR":
        return {
          id: "state",
          label: "State",
          placeholder: "State",
          options: states.br,
        };
      default:
        return null;
    }
  };

  const config = country ? getStateConfig(country) : null;

  if (!config) {
    return null;
  }

  return (
    <select
      id={`${uid}-${config.id}`}
      required={required}
      disabled={isFormDisabled}
      aria-invalid={hasError}
      value={value || config.placeholder}
      onChange={(evt) => onChange(evt.target.value)}
    >
      <option disabled>{config.placeholder}</option>
      {config.options.map((state) => (
        <option key={state.code} value={state.code}>
          {state.name}
        </option>
      ))}
    </select>
  );
};

export const getStateLabel = (country: string | null) => {
  if (!country) return "State";

  switch (country) {
    case "CA":
    case "AE":
      return "Province";
    case "IE":
      return "County";
    default:
      return "State";
  }
};

export default StateSelector;
