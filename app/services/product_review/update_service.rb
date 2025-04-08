# frozen_string_literal: true

class ProductReview::UpdateService
  ALLOWED_VIDEO_OPTIONS = [
    # Create a new video review with the given uploaded URL.
    :create_by_url,

    # Destroy the video review with the given external ID.
    :destroy_by_external_id
  ].freeze

  def initialize(product_review, rating:, message:, video_options: {})
    @product_review = product_review
    @rating = rating
    @message = message
    @video_options = validate_video_options(video_options)
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
      if @video_options[:create_by_url]
        @product_review.videos
          .create!(video_file_attributes: { url: @video_options[:create_by_url] })
      end

      if @video_options[:destroy_by_external_id]
        @product_review.videos
          .find_by_external_id(@video_options[:destroy_by_external_id])
          &.mark_deleted
      end
    end

    def validate_video_options(input)
      input.symbolize_keys!

      unpermitted_options = input.keys - ALLOWED_VIDEO_OPTIONS
      unless unpermitted_options.empty?
        raise ArgumentError, "Unpermitted video options: #{unpermitted_options.join(", ")}"
      end

      input
    end
end
