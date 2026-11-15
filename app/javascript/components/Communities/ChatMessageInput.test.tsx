// @vitest-environment happy-dom
import { cleanup, createEvent, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { ChatMessageInput } from "$app/components/Communities/ChatMessageInput";

// The component only needs the length limit from the page module; importing the real page would pull in the whole
// communities screen.
vi.mock("$app/pages/Communities/Index", () => ({ MAX_MESSAGE_LENGTH: 20_000 }));

afterEach(cleanup);

const mount = () => {
  const onSend = vi.fn();
  render(
    <ChatMessageInput
      ref={React.createRef<HTMLTextAreaElement>()}
      draft={{ content: "こんにちは", isSending: false }}
      updateDraftMessage={() => {}}
      onSend={onSend}
      onHeightChange={() => {}}
      errors={undefined}
    />,
  );
  return { onSend, textarea: screen.getByPlaceholderText("Type a message") };
};

// Returns whether the handler called preventDefault(). The flags are defined on the event directly so the test does
// not depend on which KeyboardEvent init fields happy-dom honours.
const pressEnter = (target: HTMLElement, { isComposing = false, keyCode = 13, shiftKey = false } = {}) => {
  const event = createEvent.keyDown(target, { key: "Enter", shiftKey });
  Object.defineProperty(event, "isComposing", { value: isComposing });
  Object.defineProperty(event, "keyCode", { value: keyCode });
  fireEvent(target, event);
  return event.defaultPrevented;
};

describe("ChatMessageInput", () => {
  it("sends the message on Enter", () => {
    const { onSend, textarea } = mount();
    expect(pressEnter(textarea)).toBe(true);
    expect(onSend).toHaveBeenCalledTimes(1);
  });

  it("does not send while an IME composition is being confirmed with Enter", () => {
    const { onSend, textarea } = mount();
    expect(pressEnter(textarea, { isComposing: true })).toBe(false);
    expect(onSend).not.toHaveBeenCalled();
  });

  it("does not send on the keyCode 229 Enter that Safari fires after the composition ends", () => {
    const { onSend, textarea } = mount();
    expect(pressEnter(textarea, { keyCode: 229 })).toBe(false);
    expect(onSend).not.toHaveBeenCalled();
  });

  it("does not send on Shift+Enter", () => {
    const { onSend, textarea } = mount();
    expect(pressEnter(textarea, { shiftKey: true })).toBe(false);
    expect(onSend).not.toHaveBeenCalled();
  });
});
