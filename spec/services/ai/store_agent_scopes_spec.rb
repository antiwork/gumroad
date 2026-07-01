# frozen_string_literal: true

require "spec_helper"

describe Ai::StoreAgentScopes do
  let(:seller) { create(:named_seller) }
  let(:admin) { create(:user) }
  let(:marketing) { create(:user) }

  before do
    create(:team_membership, user: admin, seller:, role: TeamMembership::ROLE_ADMIN)
    create(:team_membership, user: marketing, seller:, role: TeamMembership::ROLE_MARKETING)
  end

  def scopes_for(user)
    described_class.permitted_for(SellerContext.new(user:, seller:))
  end

  describe ".permitted_for" do
    it "gives the owner the full scope set" do
      expect(scopes_for(seller)).to match_array(described_class::ALL_SCOPES)
    end

    it "gives an admin the full scope set (admin can reach payouts/refunds in the dashboard)" do
      expect(scopes_for(admin)).to match_array(described_class::ALL_SCOPES)
    end

    it "gives a marketing member content scopes but NOT financial/sensitive ones" do
      result = scopes_for(marketing)

      expect(result).to include(*described_class::BASELINE_SCOPES)
      expect(result).to include(*described_class::CONTENT_SCOPES)
      # Marketing cannot view payouts/tax data or issue refunds in the dashboard, so the agent must
      # not grant those scopes either.
      expect(result).not_to include("view_payouts")
      expect(result).not_to include("view_tax_data")
      expect(result).not_to include("refund_sales")
      expect(result).not_to include("edit_sales")
      expect(result).not_to include("mark_sales_as_shipped")
    end

    it "fails closed (no scopes) when there is no acting user or seller" do
      expect(described_class.permitted_for(SellerContext.new(user: nil, seller: nil))).to eq([])
      expect(described_class.permitted_for(nil)).to eq([])
    end
  end

  describe ".all_scopes_string" do
    it "is the space-delimited superset the agent OAuth app registers with" do
      expect(described_class.all_scopes_string.split(" ")).to match_array(described_class::ALL_SCOPES)
    end
  end
end
