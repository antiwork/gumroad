import { describe, it, expect } from "vitest";

import {
  checkEmailForTypos,
  containsInvisibleCharacters,
  isValidEmail,
  removeInvisibleCharacters,
} from "$app/utils/email";

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

  // The characters below render as nothing, so they are written as escapes: an address carrying
  // one looks perfectly spelled on screen but is rejected by the mail provider, which is why the
  // form has to catch it before the account or the purchase is created.
  it("rejects an address carrying an invisible character", () => {
    expect(isValidEmail("\u200Fbuyer@example.com")).toBe(false);
    expect(isValidEmail("buyer\u200Bx@example.com")).toBe(false);
    expect(isValidEmail("\uFEFFbuyer@example.com")).toBe(false);
    expect(isValidEmail("buyer\u00A0@example.com")).toBe(false);
  });
});

describe("containsInvisibleCharacters", () => {
  it("finds a bidirectional mark", () => {
    expect(containsInvisibleCharacters("\u200Fbuyer@example.com")).toBe(true);
  });

  it("is false for an ordinary address", () => {
    expect(containsInvisibleCharacters("buyer@example.com")).toBe(false);
  });

  // The joiners carry meaning rather than formatting, so they must not be treated as invisible:
  // U+200C keeps "می‌روم" two words in Persian and U+200D is the glue inside multi-codepoint
  // emoji. This fails if someone later widens the set to the whole U+200B-U+200F range.
  it("does not treat the zero-width joiner or non-joiner as invisible", () => {
    expect(containsInvisibleCharacters("mi\u200Cravam")).toBe(false);
    expect(containsInvisibleCharacters("\u{1F468}\u200D\u{1F469}")).toBe(false);
  });
});

describe("removeInvisibleCharacters", () => {
  it("removes every occurrence, not just the first", () => {
    expect(removeInvisibleCharacters("\u200Fbu\u200Byer@example.com")).toBe("buyer@example.com");
  });

  it("leaves an ordinary address untouched", () => {
    expect(removeInvisibleCharacters("buyer@example.com")).toBe("buyer@example.com");
  });

  it("leaves the meaningful joiners in place", () => {
    expect(removeInvisibleCharacters("mi\u200Cravam")).toBe("mi\u200Cravam");
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
