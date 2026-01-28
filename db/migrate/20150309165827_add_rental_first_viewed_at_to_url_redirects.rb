# frozen_string_literal: true

class AddRentalFirstViewedAtToUrlRedirects < ActiveRecord::Migration[4.2]
  def change
    add_column :url_redirects, :rental_first_viewed_at, :datetime
  end
end
