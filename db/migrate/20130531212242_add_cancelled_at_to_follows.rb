# frozen_string_literal: true

class AddCancelledAtToFollows < ActiveRecord::Migration[4.2]
  def change
    add_column :follows, :cancelled_at, :datetime
  end
end
