# frozen_string_literal: true

class ProductReviewVideos::UploadContextsController < ApplicationController
  before_action :authenticate_user!

  def show
    render json: {
      aws_access_key_id: AWS_ACCESS_KEY,
      s3_url: "https://s3.amazonaws.com/#{S3_BUCKET}",
      user_id: logged_in_user.external_id,
    }
  end
end
