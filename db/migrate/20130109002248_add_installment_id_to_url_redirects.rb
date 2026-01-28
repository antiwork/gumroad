# frozen_string_literal: true

class AddInstallmentIdToUrlRedirects < ActiveRecord::Migration[4.2]
  def change
    add_column :url_redirects, :installment_id, :integer
  end
end
