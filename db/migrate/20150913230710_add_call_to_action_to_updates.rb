# frozen_string_literal: true

class AddCallToActionToUpdates < ActiveRecord::Migration
  def change
    add_column(:installments, :call_to_action_text, :string, limit: 2083)
    add_column(:installments, :call_to_action_url,  :string, limit: 2083)
  end
end
