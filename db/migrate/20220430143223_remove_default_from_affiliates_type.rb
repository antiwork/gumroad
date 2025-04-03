# frozen_string_literal: true

class RemoveDefaultFromAffiliatesType < ActiveRecord::Migration[6.1]
  def change
    change_column_default :affiliates, :type, from: "DirectAffiliate", to: nil
  end
end
