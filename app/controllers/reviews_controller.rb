# frozen_string_literal: true

class ReviewsController < ApplicationController
  layout "inertia"
  before_action :authenticate_user!
  after_action :verify_authorized

  def index
    authorize ProductReview

    presenter = ReviewsPresenter.new(current_seller)

    render inertia: "Reviews/Index", props: presenter.reviews_props.merge(
      following_wishlists_enabled: Feature.active?(:follow_wishlists, current_seller)
    )
  end
end
