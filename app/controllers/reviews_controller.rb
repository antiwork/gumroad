# frozen_string_literal: true

class ReviewsController < ApplicationController
  before_action :authenticate_user!
  after_action :verify_authorized

  def index
    authorize ProductReview

    @title = "Reviews"
    @presenter = ReviewsPresenter.new(current_seller)
  end
end
