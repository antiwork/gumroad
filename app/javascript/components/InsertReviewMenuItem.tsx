import type { Editor } from "@tiptap/react";
import * as React from "react";

import { Icon } from "$app/components/Icons";

const TestimonialSelectModal = React.lazy(() => import("$app/components/TestimonialSelectModal"));

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
      <div
        role="menuitem"
        onClick={(e) => {
          e.stopPropagation();
          setShowReviewModal(true);
        }}
      >
        <Icon name="solid-star" />
        <span>Review</span>
      </div>
      {showReviewModal ? (
        <React.Suspense fallback={null}>
          <TestimonialSelectModal
            isOpen={showReviewModal}
            onClose={() => setShowReviewModal(false)}
            onInsert={onInsertReviews}
            productId={productId}
          />
        </React.Suspense>
      ) : null}
    </>
  );
};
