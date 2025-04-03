type ParamName = string;
type RawValue = string;
type SimpleValue = string | number | boolean;
type SimpleArrayValue = SimpleValue[];

// tuple of [param name, param value, mode]
export type SerializationItem =
  | [ParamName, SimpleValue, "encode"]
  | [ParamName, SimpleArrayValue, "encode_and_join"]
  | [ParamName, RawValue, "use_raw_value"];
export type SerializationBuffer = SerializationItem[];

export const escapeParamNameInterpolation = (val: string): string => encodeURIComponent(val);

export const serializeToQueryParam = (items: SerializationBuffer): string =>
  items
    .map((tuple) => {
      switch (tuple[2]) {
        case "encode": {
          const [paramName, paramValue] = tuple;
          return `${encodeURIComponent(paramName)}=${encodeURIComponent(paramValue)}`;
        }
        case "encode_and_join": {
          const [paramName, paramValue] = tuple;
          return `${encodeURIComponent(paramName)}=${paramValue.map((x) => encodeURIComponent(x)).join(",")}`;
        }
        case "use_raw_value": {
          const [paramName, paramValue] = tuple;
          return `${encodeURIComponent(paramName)}=${paramValue}`;
        }
      }
    })
    .join("&");
