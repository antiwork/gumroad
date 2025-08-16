# frozen_string_literal: true

class MakeOfferCodeUserIdNonNullable < ActiveRecord::Migration[7.1]
  def change
    change_column_null :offer_codes, :user_id, false
  end
end
