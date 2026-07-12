import { describe, it, expect } from "vitest";

import { checkEmailForTypos, isValidEmail } from "$app/utils/email";

// checkEmailForTypos only invokes the callback when there is a suggestion, so capture it
// (or null) to assert on both "suggests X" and "stays quiet" cases.
const suggestionFor = (email: string): string | null => {
  let suggestion: string | null = null;
  checkEmailForTypos(email, (s) => {
    suggestion = s.full;
  });
  return suggestion;
};

describe("isValidEmail", () => {
  it("accepts a normal address", () => {
    expect(isValidEmail("buyer@example.com")).toBe(true);
  });

  it("rejects an address without a domain", () => {
    expect(isValidEmail("buyer@")).toBe(false);
  });
});

describe("checkEmailForTypos", () => {
  it("suggests gmail.com for the classic gnail.com typo", () => {
    expect(suggestionFor("buyer@gnail.com")).toBe("buyer@gmail.com");
  });

  it("suggests hotmail.com for hotmial.com", () => {
    expect(suggestionFor("buyer@hotmial.com")).toBe("buyer@hotmail.com");
  });

  it("stays quiet for an exact popular domain", () => {
    expect(suggestionFor("buyer@gmail.com")).toBeNull();
  });

  it("does not 'correct' a valid newer TLD to a nearby popular one (.land is not a typo of .ca)", () => {
    // Regression test for a buyer on a .land address who was asked "Did you mean ....ca?"
    // on every single checkout.
    expect(suggestionFor("kevin@hoge.land")).toBeNull();
  });

  it("leaves other valid modern TLDs alone", () => {
    expect(suggestionFor("dev@example.dev")).toBeNull();
    expect(suggestionFor("hi@example.io")).toBeNull();
    expect(suggestionFor("hi@example.xyz")).toBeNull();
    expect(suggestionFor("hi@example.app")).toBeNull();
    expect(suggestionFor("hi@example.link")).toBeNull();
  });

  it("still suggests a fix for a genuinely mistyped TLD", () => {
    expect(suggestionFor("buyer@example.con")).toBe("buyer@example.com");
    expect(suggestionFor("buyer@example.cmo")).toBe("buyer@example.com");
    expect(suggestionFor("buyer@example.nte")).toBe("buyer@example.net");
  });

  it("only rewrites the TLD even when the same string appears in the rest of the domain", () => {
    // A plain String.replace would rewrite the first "con" it finds, producing
    // "comcast.con" here. The correction must land on the TLD at the end.
    expect(suggestionFor("buyer@concast.con")).toBe("buyer@concast.com");
  });

  it("does not rewrite an unknown TLD", () => {
    expect(suggestionFor("buyer@example.pizza")).toBeNull();
  });
});
