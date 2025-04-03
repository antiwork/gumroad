# frozen_string_literal: true

class AddStripeIdentityDocumentIdToUserComplianceInfo < ActiveRecord::Migration
  def change
    add_column :user_compliance_info, :stripe_identity_document_id, :string
  end
end
