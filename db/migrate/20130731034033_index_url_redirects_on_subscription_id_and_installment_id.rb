# frozen_string_literal: true

class IndexUrlRedirectsOnSubscriptionIdAndInstallmentId < ActiveRecord::Migration
  def change
    add_index :url_redirects, :installment_id
    add_index :url_redirects, :subscription_id
  end
end
