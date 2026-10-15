# frozen_string_literal: true

require "spec_helper"

describe CommunityPolicy do
  subject { described_class }

  let(:accountant_for_seller) { create(:user) }
  let(:admin_for_seller) { create(:user) }
  let(:marketing_for_seller) { create(:user) }
  let(:support_for_seller) { create(:user) }
  let(:seller) { create(:named_seller) }
  let(:buyer) { create(:user) }
  let(:product) { create(:product, user: seller, community_chat_enabled: true) }
  let!(:community) { create(:community, seller: seller, resource: product) }
  let(:other_product) { create(:product, community_chat_enabled: true) }
  let!(:other_community) { create(:community, seller: other_product.user, resource: other_product) }
  let!(:purchase) { create(:purchase, purchaser: buyer, link: other_product) }

  before do
    create(:team_membership, user: accountant_for_seller, seller:, role: TeamMembership::ROLE_ACCOUNTANT)
    create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
    create(:team_membership, user: marketing_for_seller, seller:, role: TeamMembership::ROLE_MARKETING)
    create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
  end

  permissions :index? do
    context "when user has accessible communities" do
      it "grants access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).to permit(seller_context, Community)
      end

      it "denies access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Community)
      end

      it "denies access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Community)
      end

      it "denies access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Community)
      end

      it "denies access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Community)
      end

      it "grants access to buyer with purchased product" do
        seller_context = SellerContext.new(user: buyer, seller: other_product.user)
        expect(subject).to permit(seller_context, Community)
      end

      it "denies access to seller who has at least one product but no active communities" do
        another_seller = create(:user)
        create(:product, user: another_seller)
        seller_context = SellerContext.new(user: another_seller, seller:)

        expect(subject).not_to permit(seller_context, Community)
      end
    end

    context "when user has no accessible communities" do
      before do
        product.update!(community_chat_enabled: false)
        other_product.update!(community_chat_enabled: false)
      end

      it "denies access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).not_to permit(seller_context, Community)
      end

      it "denies access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Community)
      end

      it "denies access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Community)
      end

      it "denies access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Community)
      end

      it "denies access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Community)
      end

      it "denies access to buyer with purchased product" do
        purchase
        seller_context = SellerContext.new(user: buyer, seller: other_product.user)
        expect(subject).not_to permit(seller_context, Community)
      end
    end
  end

  permissions :show? do
    context "when user has access to the community" do
      context "when user is a seller" do
        it "grants access to own community" do
          seller_context = SellerContext.new(user: seller, seller:)
          expect(subject).to permit(seller_context, community)
        end

        it "denies access to other seller's community" do
          seller_context = SellerContext.new(user: seller, seller:)
          expect(subject).not_to permit(seller_context, other_community)
        end
      end

      context "when user is a buyer" do
        it "grants access to community of purchased product" do
          purchase
          seller_context = SellerContext.new(user: buyer, seller:)
          expect(subject).to permit(seller_context, other_community)
        end

        it "denies access to community of unpurchased product" do
          seller_context = SellerContext.new(user: buyer, seller:)
          expect(subject).not_to permit(seller_context, community)
        end
      end

      context "when user is a team member" do
        it "denies access to seller's community" do
          seller_context = SellerContext.new(user: admin_for_seller, seller:)
          expect(subject).not_to permit(seller_context, community)
        end

        it "denies access to other seller's community" do
          seller_context = SellerContext.new(user: admin_for_seller, seller:)
          expect(subject).not_to permit(seller_context, other_community)
        end
      end
    end

    context "when user has no access to the community" do
      before do
        product.update!(community_chat_enabled: false)
        other_product.update!(community_chat_enabled: false)
      end

      it "denies access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).not_to permit(seller_context, community)
      end

      it "denies access to buyer" do
        purchase
        seller_context = SellerContext.new(user: buyer, seller:)
        expect(subject).not_to permit(seller_context, other_community)
      end

      it "denies access to team members" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).not_to permit(seller_context, community)
      end
    end

    context "when community's resource is deleted" do
      before do
        product.mark_deleted!
      end

      it "denies access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).not_to permit(seller_context, community)
      end

      it "denies access to team members" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).not_to permit(seller_context, community)
      end
    end

    context "when community chat is disabled" do
      before do
        product.update!(community_chat_enabled: false)
      end

      it "denies access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).not_to permit(seller_context, community)
      end

      it "denies access to team members" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).not_to permit(seller_context, community)
      end
    end
  end

  describe "#index? existence check flag" do
    let(:flag) { described_class::EXISTENCE_CHECK_FLAG }

    def index_for(user)
      described_class.new(SellerContext.new(user:, seller: user), Community).index?
    end

    def user_in_arm(treatment:)
      50.times do
        candidate = create(:user)
        return candidate if Feature.active?(flag, candidate) == treatment
      end
      raise "no #{treatment ? "treatment" : "control"} user in 50 draws"
    end

    def existence_check_log_lines
      lines = []
      allow(Rails.logger).to receive(:info).and_wrap_original do |original, *args, &block|
        lines << args.first if args.first.is_a?(String)
        original.call(*args, &block)
      end
      yield
      lines.filter_map { JSON.parse(_1) rescue nil }.select { _1["event"] == flag.to_s }
    end

    context "when the flag is off" do
      it "answers with accessible_communities_ids" do
        expect(seller).not_to receive(:has_accessible_communities?)
        expect(index_for(seller)).to eq(true)
      end
    end

    context "when the flag is on" do
      before { Feature.activate(flag) }

      it "answers with the existence check" do
        expect(seller).to receive(:has_accessible_communities?).and_call_original
        expect(seller).not_to receive(:accessible_communities_ids)
        expect(index_for(seller)).to eq(true)
      end

      it "grants a buyer and denies a user without communities" do
        expect(index_for(buyer)).to eq(true)
        expect(index_for(create(:user))).to eq(false)
      end

      it "does not log" do
        expect(existence_check_log_lines { index_for(seller) }).to be_empty
      end
    end

    context "when the flag is at 100% of actors" do
      before { Feature.activate_percentage(flag, 100) }

      it "answers with the existence check and does not log" do
        expect(seller).to receive(:has_accessible_communities?).and_call_original
        expect(existence_check_log_lines { expect(index_for(seller)).to eq(true) }).to be_empty
      end
    end

    context "when the flag is mid-ramp" do
      before { Feature.activate_percentage(flag, 50) }

      it "logs the arm, result, and elapsed time once per evaluation" do
        treatment_user = user_in_arm(treatment: true)
        control_user = user_in_arm(treatment: false)

        lines = existence_check_log_lines do
          expect(index_for(treatment_user)).to eq(false)
          expect(index_for(control_user)).to eq(false)
        end

        expect(lines.map { _1.values_at("arm", "user_id", "has_communities") }).to eq(
          [["treatment", treatment_user.id, false], ["control", control_user.id, false]]
        )
        expect(lines.map { _1["elapsed_ms"] }).to all(be_a(Numeric))
      end
    end
  end
end
