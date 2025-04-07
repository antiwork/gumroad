# frozen_string_literal: true

class ProductReview::UpdateService
  def initialize(product_review, rating:, message:)
    @product_review = product_review
    @rating = rating
    @message = message
  end

  def update
    @product_review.transaction do
      # Lock to avoid race condition as we update the aggregated stats based on
      # the changes.
      @product_review.with_lock do
        update_rating_and_message
      end
    end
  end

  private
    def update_rating_and_message
      @product_review.update!(rating: @rating, message: @message)
    end
end
