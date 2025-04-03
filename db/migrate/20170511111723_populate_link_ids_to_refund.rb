# frozen_string_literal: true

class PopulateLinkIdsToRefund < ActiveRecord::Migration
  def change
    Refund.find_each do |refund|
      refund.link_id = refund.purchase.link_id if refund.purchase
      refund.save!
    end
  end
end
