# frozen_string_literal: true

class AddRentalFirstViewedAtToUrlRedirects < ActiveRecord::Migration
  def change
    add_column :url_redirects, :rental_first_viewed_at, :datetime
  end
end
