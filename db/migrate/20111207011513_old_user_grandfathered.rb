# frozen_string_literal: true

class OldUserGrandfathered < ActiveRecord::Migration
  def up
    User.update_all({ confirmed_at: true })
  end

  def down
  end
end
