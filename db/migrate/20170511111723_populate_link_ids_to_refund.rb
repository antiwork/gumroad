# frozen_string_literal: true

class PopulateLinkIdsToRefund < ActiveRecord::Migration[4.2]
  def change
    Refund.find_each do |refund|
      refund.link_id = refund.purchase.link_id if refund.purchase
      refund.save!
    end
  end
end
