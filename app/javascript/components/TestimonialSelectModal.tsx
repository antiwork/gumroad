import * as React from "react";

import { Review as ReviewType, getReviews } from "$app/data/product_reviews";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Modal } from "$app/components/Modal";
import { PaginationProps } from "$app/components/Pagination";
import { Review } from "$app/components/Review";
import { showAlert } from "$app/components/server-components/Alert";

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
  const hasLoadedOnOpen = React.useRef(false);

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

  const resetState = () => {
    setState({ reviews: [], pagination: null });
    setSelectedReviewIds([]);
  };

  React.useEffect(() => {
    if (isOpen && !hasLoadedOnOpen.current) {
      hasLoadedOnOpen.current = true;
      void loadReviews(1);
    }

    if (!isOpen) {
      hasLoadedOnOpen.current = false;
      resetState();
    }
  }, [isOpen]);

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
          {state.reviews.length > 0 ? (
            <Button
              color="primary"
              onClick={() => onInsert(selectedReviewIds)}
              disabled={selectedReviewIds.length === 0}
            >
              Insert
            </Button>
          ) : null}
        </>
      }
    >
      <div>
        {isLoading && state.reviews.length === 0 ? (
          <div className="flex items-center justify-center">
            <LoadingSpinner width="2em" />
          </div>
        ) : !isLoading && state.reviews.length === 0 ? (
          <p>No reviews with text or video yet.</p>
        ) : (
          <>
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
          </>
        )}
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
