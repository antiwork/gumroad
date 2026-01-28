# frozen_string_literal: true

class IncreaseStringLimitForFb < ActiveRecord::Migration[4.2]
  def change
    change_column(:users, :facebook_access_token, :string, limit: 1024)
  end
end
