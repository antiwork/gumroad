# frozen_string_literal: true

class AddCoverImageUrlToInstallment < ActiveRecord::Migration[4.2]
  def change
    add_column(:installments, :cover_image_url, :string)
  end
end
