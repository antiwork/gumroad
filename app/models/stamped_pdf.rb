# frozen_string_literal: true

class StampedPdf < ApplicationRecord
  include S3Retrievable, Deletable, CdnDeletable
  has_s3_fields :url

  belongs_to :url_redirect, optional: true
  belongs_to :product_file, optional: true

  validates_presence_of :url_redirect, :product_file, :url

  def user
    product_file.try(:link).try(:user)
  end

  def has_alive_duplicate_files? = false
end
