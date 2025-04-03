import { createCable } from "@anycable/web";

const createConsumerWithSSR = () => {
  if (typeof document === "undefined") return null;
  return createCable({ logLevel: process.env.NODE_ENV === "production" ? "error" : "debug" });
};

export default createConsumerWithSSR();
