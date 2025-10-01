# frozen_string_literal: true

class ReviewsController < ApplicationController
  before_action :authenticate_user!
  after_action :verify_authorized

  def index
    authorize ProductReview

    @title = "Reviews"
    presenter = ReviewsPresenter.new(current_seller)

    render inertia: "Reviews/Index",
           props: inertia_props(
             **presenter.reviews_props.merge(
               following_wishlists_enabled: Feature.active?(:follow_wishlists, current_seller)
             )
           )
  end
end
