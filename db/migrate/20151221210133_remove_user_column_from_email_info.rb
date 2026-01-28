# frozen_string_literal: true

class RemoveUserColumnFromEmailInfo < ActiveRecord::Migration[4.2]
  def change
    remove_column :email_infos, :user_id
  end
end
