// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { deleteComment, type PaginatedComments } from "$app/data/comments";
import type { CommunityChatMessage } from "$app/data/communities";
import { CommunityViewContext } from "$app/pages/Communities/Index";
import { ResponseError } from "$app/utils/request";

import { ChatMessage } from "$app/components/Communities/ChatMessage";
import { CommentsMetadataProvider, PostCommentsSection } from "$app/components/Post/PostCommentsSection";

vi.hoisted(() => {
  vi.stubGlobal("SSR", false);
  vi.stubGlobal("Routes", new Proxy({}, { get: (_, name: string) => () => `/${name}` }));
});
vi.mock("$app/pages/Communities/Index", async () => {
  const { createContext } = await import("react");
  return { CommunityViewContext: createContext(null), MIN_MESSAGE_LENGTH: 1, MAX_MESSAGE_LENGTH: 500 };
});
vi.mock("$app/components/CurrentSeller", () => ({ useCurrentSeller: () => ({ id: "seller-1" }) }));
vi.mock("$app/components/LoggedInUser", () => ({ useLoggedInUser: () => null }));
vi.mock("$app/components/UserAgent", () => ({ useUserAgentInfo: () => ({ locale: "en-US" }) }));
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => true }));
vi.mock("$app/components/DomainSettings", () => ({ useAppDomain: () => "gumroad.example" }));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
vi.mock("$app/data/comments", () => ({ deleteComment: vi.fn() }));
afterEach(() => {
  cleanup();
  vi.resetAllMocks();
});

const msg: CommunityChatMessage = {
  id: "message-1",
  community_id: "community-1",
  content: "Example message",
  created_at: "2026-11-20T00:00:00Z",
  updated_at: "2026-11-20T00:00:00Z",
  user: { id: "seller-1", name: "Test seller", avatar_url: "", is_seller: true },
};
const openChatDeletion = (request: Promise<void>) => {
  const deleteMessage = vi.fn(() => request);
  const context = { deleteMessage, markMessageAsRead: vi.fn(), updateMessage: vi.fn() };
  render(
    <CommunityViewContext.Provider value={context}>
      <ChatMessage message={msg} isLast={false} communitySellerId="seller-1" />
    </CommunityViewContext.Provider>,
  );
  fireEvent.mouseEnter(screen.getByLabelText("Chat message"));
  fireEvent.click(screen.getByRole("button", { name: "Delete message" }));
  expect(screen.getByRole("dialog", { name: "Delete message" })).toBeTruthy();
  return deleteMessage;
};

const openPostDeletion = (request: Promise<string[]>) => {
  vi.mocked(deleteComment).mockReturnValue(request);
  const data: PaginatedComments = {
    comments: [
      {
        id: "comment-1",
        author_id: "seller-1",
        author_name: "Test seller",
        purchase_id: null,
        author_avatar_url: "",
        content: { original: "Example comment", formatted: "<p>Example comment</p>" },
        depth: 0,
        created_at: "2026-11-20T00:00:00Z",
        created_at_humanized: "Today",
        is_editable: false,
        is_deletable: true,
        parent_id: null,
      },
    ],
    count: 1,
    pagination: { count: 1, items: 1, page: 1, pages: 1, prev: null, next: null, last: 1 },
  };
  render(
    <CommentsMetadataProvider
      value={{ seller_id: "seller-1", commentable_id: "post-1", purchase_id: null, max_allowed_depth: 1 }}
    >
      <PostCommentsSection paginated_comments={data} />
    </CommentsMetadataProvider>,
  );
  fireEvent.click(screen.getByRole("button", { name: "Open comment action menu" }));
  fireEvent.click(screen.getByRole("button", { name: "Delete" }));
  expect(screen.getByRole("dialog", { name: "Delete comment" })).toBeTruthy();
  return vi.mocked(deleteComment);
};

const waitForOutsideListener = () => new Promise((resolve) => setTimeout(resolve, 0));
const pendingDeletion = () => {
  let resolve: () => void = () => {};
  let reject: (error: Error) => void = () => {};
  const promise = new Promise<void>((done, fail) => {
    resolve = done;
    reject = fail;
  });
  return { promise, resolve, reject };
};
const dismiss = {
  Escape: () => fireEvent.keyDown(screen.getByRole("dialog"), { key: "Escape" }),
  "outside pointer": () => fireEvent.pointerDown(document.body, { pointerType: "mouse" }),
};

describe.each([
  {
    name: "chat message",
    confirm: "Delete",
    open: (request: Promise<unknown>) => openChatDeletion(request.then(() => undefined)),
  },
  {
    name: "post comment",
    confirm: "Confirm",
    open: (request: Promise<unknown>) => openPostDeletion(request.then(() => ["comment-1"])),
  },
])("$name delete confirmation", ({ confirm, open }) => {
  it.each(Object.entries(dismiss))("can dismiss with %s before confirming", async (_method, attempt) => {
    const request = open(new Promise(() => undefined));
    await waitForOutsideListener();
    attempt();
    expect(screen.queryByRole("dialog")).toBeNull();
    expect(request).not.toHaveBeenCalled();
  });

  it.each(Object.entries(dismiss))(
    "blocks %s while deletion is pending and restores it after a failure",
    async (_method, attempt) => {
      const { promise, reject } = pendingDeletion();
      const request = open(promise);
      await waitForOutsideListener();

      fireEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: confirm }));
      const pending = screen.getByRole<HTMLButtonElement>("button", { name: "Deleting..." });
      expect(pending.disabled).toBe(true);
      fireEvent.click(pending);
      expect(request).toHaveBeenCalledOnce();
      expect(screen.queryByRole("button", { name: "Close" })).toBeNull();
      expect(screen.getByRole<HTMLButtonElement>("button", { name: "Cancel" }).disabled).toBe(true);
      attempt();
      expect(screen.getByRole("dialog")).toBeTruthy();

      await act(async () => {
        reject(new ResponseError("The request failed"));
        await promise.catch(() => undefined);
      });
      expect(screen.getByRole<HTMLButtonElement>("button", { name: confirm }).disabled).toBe(false);
      expect(screen.getByRole("button", { name: "Close" })).toBeTruthy();
      attempt();
      expect(screen.queryByRole("dialog")).toBeNull();
    },
  );

  it("closes when deletion succeeds", async () => {
    const { promise, resolve } = pendingDeletion();
    const request = open(promise);
    fireEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: confirm }));
    expect(request).toHaveBeenCalledOnce();
    await act(async () => {
      resolve();
      await promise;
    });
    expect(screen.queryByRole("dialog")).toBeNull();
  });
});
