# frozen_string_literal: true

class AddCoverImageUrlToInstallment < ActiveRecord::Migration
  def change
    add_column(:installments, :cover_image_url, :string)
  end
end
