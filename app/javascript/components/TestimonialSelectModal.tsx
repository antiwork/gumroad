import * as React from "react";

import { Review as ReviewType, getReviews } from "$app/data/product_reviews";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { PaginationProps } from "$app/components/Pagination";
import { Review } from "$app/components/Review";
import { showAlert } from "$app/components/server-components/Alert";
import { useRunOnce } from "$app/components/useRunOnce";

export const TestimonialSelectModal = ({
  isOpen,
  onClose,
  onInsert,
  productId,
}: {
  isOpen: boolean;
  onClose: () => void;
  onInsert: (reviewIds: string[]) => void;
  productId: string;
}) => {
  const [selectedReviewIds, setSelectedReviewIds] = React.useState<string[]>([]);
  const [state, setState] = React.useState<{
    reviews: ReviewType[];
    pagination: PaginationProps | null;
  }>({
    reviews: [],
    pagination: null,
  });
  const [isLoading, setIsLoading] = React.useState(false);

  const loadReviews = async (page = 1) => {
    setIsLoading(true);
    try {
      const data = await getReviews(productId, page);

      setState((prevState) => ({
        reviews: [...prevState.reviews, ...data.reviews],
        pagination: data.pagination,
      }));
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
    } finally {
      setIsLoading(false);
    }
  };

  useRunOnce(() => {
    void loadReviews(1);
  });

  const handleLoadMore = () => {
    if (state.pagination) {
      void loadReviews(state.pagination.page + 1);
    }
  };

  const hasMorePages = state.pagination && state.pagination.page < state.pagination.pages;

  const toggleSelectAll = () => {
    if (selectedReviewIds.length === state.reviews.length) {
      setSelectedReviewIds([]);
    } else {
      setSelectedReviewIds(state.reviews.map((review) => review.id));
    }
  };

  const toggleReviewSelection = (reviewId: string) => {
    if (selectedReviewIds.includes(reviewId)) {
      setSelectedReviewIds(selectedReviewIds.filter((id) => id !== reviewId));
    } else {
      setSelectedReviewIds([...selectedReviewIds, reviewId]);
    }
  };

  return (
    <Modal
      open={isOpen}
      onClose={onClose}
      title="Insert reviews"
      footer={
        <>
          <Button onClick={onClose}>Cancel</Button>
          <Button color="primary" onClick={() => onInsert(selectedReviewIds)}>
            Insert
          </Button>
        </>
      }
    >
      <div>
        <div className="flex flex-row items-center gap-2">
          <input
            type="checkbox"
            role="checkbox"
            checked={selectedReviewIds.length === state.reviews.length && state.reviews.length > 0}
            onChange={toggleSelectAll}
            aria-label="Select all reviews"
          />
          <p>Select all</p>
        </div>
        <section className="paragraphs" style={{ marginTop: "var(--spacer-2)" }}>
          {state.reviews.map((review) => (
            <SelectableReviewCard
              key={review.id}
              review={review}
              isSelected={selectedReviewIds.includes(review.id)}
              onSelect={() => toggleReviewSelection(review.id)}
            />
          ))}
          {hasMorePages ? (
            <div className="mt-4">
              <Button onClick={handleLoadMore} disabled={isLoading}>
                {isLoading ? "Loading..." : "Load more"}
              </Button>
            </div>
          ) : null}
        </section>
      </div>
    </Modal>
  );
};

const SelectableReviewCard = ({
  review,
  isSelected,
  onSelect,
}: {
  review: ReviewType;
  isSelected: boolean;
  onSelect: () => void;
}) => (
  <div className="flex gap-4 rounded-sm p-4 outline outline-[1px]">
    <input type="checkbox" role="checkbox" checked={isSelected} onChange={onSelect} aria-label="Select review" />
    <div className="w-full">
      <Review review={review} seller={null} canRespond={false} hideResponse />
    </div>
  </div>
);
