# frozen_string_literal: true

class AddPkceToDoorkeeper < ActiveRecord::Migration[7.1]
  def change
    change_table :oauth_access_grants, bulk: true do |t|
      t.string :code_challenge
      t.string :code_challenge_method
    end
  end
end
