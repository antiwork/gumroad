# frozen_string_literal: true

class AddDigestSentAtToUsers < ActiveRecord::Migration
  def change
    add_column :users, :digest_sent_at, :datetime
  end
end
