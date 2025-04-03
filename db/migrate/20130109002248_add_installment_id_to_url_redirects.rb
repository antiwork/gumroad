# frozen_string_literal: true

class AddInstallmentIdToUrlRedirects < ActiveRecord::Migration
  def change
    add_column :url_redirects, :installment_id, :integer
  end
end
