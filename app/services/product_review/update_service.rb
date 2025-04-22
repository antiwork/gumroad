# frozen_string_literal: true

class ProductReview::UpdateService
  def initialize(product_review, rating:, message:, video_options: {})
    @product_review = product_review
    @rating = rating
    @message = message
    @video_options = video_options.to_h.with_indifferent_access
  end

  def update
    @product_review.transaction do
      # Lock to avoid race condition as we update the aggregated stats based on
      # the changes.
      @product_review.with_lock do
        update_rating_and_message
        update_video
      end
    end

    @product_review
  end

  private
    def update_rating_and_message
      @product_review.update!(rating: @rating, message: @message)
    end

    def update_video
      create_video(@video_options[:create] || {})
      destroy_video(@video_options[:destroy] || {})
    end

    def create_video(options)
      return unless options[:url]

      @product_review.videos.alive.pending_review.each(&:mark_deleted!)

      @product_review.videos.create!(
        approval_status: :pending_review,
        video_file_attributes: {
          url: options[:url],
          thumbnail: options[:thumbnail_signed_id],
          user_id: @product_review.purchase.purchaser_id
        }
      )
    end

    def destroy_video(options)
      return unless options[:id]

      @product_review.videos.find_by_external_id(options[:id])&.mark_deleted
    end
end
