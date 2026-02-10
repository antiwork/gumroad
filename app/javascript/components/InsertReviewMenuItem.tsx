import type { Editor } from "@tiptap/react";
import * as React from "react";

import { Icon } from "$app/components/Icons";
import { TestimonialSelectModal } from "$app/components/TestimonialSelectModal";

export const InsertReviewMenuItem = ({ editor, productId }: { editor: Editor; productId: string }) => {
  const [showReviewModal, setShowReviewModal] = React.useState(false);

  const onInsertReviews = (reviewIds: string[]) => {
    for (const reviewId of reviewIds) {
      editor.chain().focus().insertReviewCard({ reviewId }).run();
    }
    setShowReviewModal(false);
  };

  return (
    <>
      <div role="menuitem" onClick={() => setShowReviewModal(true)}>
        <Icon name="solid-star" />
        <span>Review</span>
      </div>
      {showReviewModal ? (
        <TestimonialSelectModal
          isOpen={showReviewModal}
          onClose={() => setShowReviewModal(false)}
          onInsert={onInsertReviews}
          productId={productId}
        />
      ) : null}
    </>
  );
};
