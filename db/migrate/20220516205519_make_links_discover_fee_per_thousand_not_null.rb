# frozen_string_literal: true

class MakeLinksDiscoverFeePerThousandNotNull < ActiveRecord::Migration[6.1]
  def change
    change_column_null :links, :discover_fee_per_thousand, false, 100
  end
end
