# frozen_string_literal: true

require "spec_helper"

describe PartnerSeller do
  let(:partner_application) { create(:oauth_application, is_partner: true, confidential: true, scopes: "partner_api") }

  it "treats partner user IDs that differ only in case, accents, or trailing spaces as different users" do
    %w[aB3x Ab3X café cafe].push("id", "id ").each do |external_user_id|
      create(:partner_seller, oauth_application: partner_application, external_user_id:)
    end

    expect(partner_application.partner_sellers.pluck(:external_user_id)).to contain_exactly("aB3x", "Ab3X", "café", "cafe", "id", "id ")
  end
end
