# frozen_string_literal: true

class MakeLinksDiscoverFeePerThousandNotNull < ActiveRecord::Migration[4.2]
  def change
    change_column_null :links, :discover_fee_per_thousand, false, 100
  end
end
