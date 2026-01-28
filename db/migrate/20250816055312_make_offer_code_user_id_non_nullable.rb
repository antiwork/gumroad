# frozen_string_literal: true

class MakeOfferCodeUserIdNonNullable < ActiveRecord::Migration[4.2]
  def change
    change_column_null :offer_codes, :user_id, false
  end
end
