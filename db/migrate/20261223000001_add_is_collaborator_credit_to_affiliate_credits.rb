# frozen_string_literal: true

class AddIsCollaboratorCreditToAffiliateCredits < ActiveRecord::Migration[8.1]
  def change
    add_column :affiliate_credits, :is_collaborator_credit, :boolean, default: false, null: false
  end
end
