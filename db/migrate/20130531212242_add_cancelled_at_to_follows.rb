# frozen_string_literal: true

class AddCancelledAtToFollows < ActiveRecord::Migration
  def change
    add_column :follows, :cancelled_at, :datetime
  end
end
