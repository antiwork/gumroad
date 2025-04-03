# frozen_string_literal: true

class AddBackgroundVideoUrlToUser < ActiveRecord::Migration
  def change
    add_column :users, :background_video_url, :string
  end
end
