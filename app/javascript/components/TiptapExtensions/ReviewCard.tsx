import { Node, NodeViewProps } from "@tiptap/core";
import { NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Review as ReviewType, getReview } from "$app/data/product_reviews";
import { assertResponseError } from "$app/utils/request";

import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Review } from "$app/components/Review";
import { showAlert } from "$app/components/server-components/Alert";
import { createInsertCommand } from "$app/components/TiptapExtensions/utils";

declare module "@tiptap/core" {
  interface Commands<ReturnType> {
    reviewCard: {
      insertReviewCard: (options: { reviewId: string }) => ReturnType;
    };
  }
}

export const ReviewCard = Node.create({
  name: "reviewCard",
  group: "block",
  atom: true,
  selectable: true,
  draggable: true,

  addAttributes() {
    return {
      reviewId: { default: null },
    };
  },

  parseHTML() {
    return [
      {
        tag: "review-card",
      },
    ];
  },

  renderHTML({ HTMLAttributes }) {
    return ["review-card", HTMLAttributes];
  },

  addNodeView() {
    return ReactNodeViewRenderer(ReviewCardNodeView);
  },

  addCommands() {
    return {
      insertReviewCard: createInsertCommand("reviewCard"),
    };
  },
});

const ReviewCardNodeView = ({ node, selected, editor }: NodeViewProps) => {
  const reviewId = cast<string>(node.attrs.reviewId ?? "");
  const [review, setReview] = React.useState<ReviewType | null>(null);
  const isEditable = editor.isEditable;
  const seller = useCurrentSeller();

  React.useEffect(() => {
    const fetchReview = async () => {
      try {
        const { review } = await getReview(reviewId);
        setReview(review);
      } catch (error) {
        assertResponseError(error);
        showAlert(error.message, "error");
      }
    };

    void fetchReview();
  }, [reviewId]);

  return (
    <NodeViewWrapper>
      {review ? (
        <article
          className="p-4"
          style={{
            outline: selected && isEditable ? "2px solid rgb(var(--accent))" : "var(--border)",
            borderRadius: "var(--border-radius-1)",
          }}
          data-drag-handle
        >
          <Review
            review={review}
            seller={
              seller
                ? {
                    id: seller.id,
                    name: seller.name || "",
                    avatar_url: seller.avatarUrl,
                    profile_url: "",
                  }
                : null
            }
            canRespond={false}
            hideResponse
          />
        </article>
      ) : (
        <div className="dummy" style={{ height: "8rem" }}></div>
      )}
    </NodeViewWrapper>
  );
};
