# frozen_string_literal: true

class ProductReviewVideos::UploadContextsController < ApplicationController
  before_action :authenticate_user!

  def show
    render json: {
      aws_access_key_id: AWS_ACCESS_KEY,
      s3_url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}",
      user_id: logged_in_user.external_id,
    }
  end
end
