# frozen_string_literal: true

require "spec_helper"

describe Admin::UserPresenter::Card do
  describe "#props" do
    let(:admin_user) { create(:user) }
    let(:user) { create(:named_user, *user_traits) }
    let(:user_traits) { [] }
    let(:pundit_user) { SellerContext.new(user: admin_user, seller: admin_user) }
    let(:presenter) { described_class.new(user:, pundit_user:) }

    subject(:props) { presenter.props }

    before do
      create_list(:comment, 2, commentable: user, comment_type: Comment::COMMENT_TYPE_NOTE)
    end

    describe "fields" do
      it "returns the correct values" do
        expect(props[:external_id]).to eq(user.external_id)
        expect(props[:name]).to eq(user.name)
        expect(props[:bio]).to eq(user.bio)
        expect(props[:avatar_url]).to eq(user.avatar_url)
        expect(props[:username]).to eq(user.username)
        expect(props[:email]).to eq(user.form_email)
        expect(props[:form_email]).to eq(user.form_email)
        expect(props[:form_email_domain]).to eq(user.form_email_domain)
        expect(props[:support_email]).to eq(user.support_email)
        expect(props[:profile_url]).to eq(user.avatar_url)
        expect(props[:subdomain_with_protocol]).to eq(user.subdomain_with_protocol)
        expect(props[:custom_fee_per_thousand]).to eq(user.custom_fee_per_thousand)
        expect(props[:unpaid_balance_cents]).to eq(user.unpaid_balance_cents)
        expect(props[:disable_paypal_sales]).to eq(user.disable_paypal_sales)
        expect(props[:verified]).to eq(user.verified?)
        expect(props[:suspended]).to eq(user.suspended?)
        expect(props[:flagged_for_fraud]).to eq(user.flagged_for_fraud?)
        expect(props[:flagged_for_tos_violation]).to eq(user.flagged_for_tos_violation?)
        expect(props[:on_probation]).to eq(user.on_probation?)
        expect(props[:all_adult_products]).to eq(user.all_adult_products?)
        expect(props[:user_risk_state]).to eq(user.user_risk_state.humanize)
        expect(props[:comments_count]).to eq(2)
        expect(props[:compliant]).to eq(user.compliant?)
        expect(props[:created_at]).to eq(user.created_at)
        expect(props[:updated_at]).to eq(user.updated_at)
        expect(props[:deleted_at]).to eq(user.deleted_at)
      end
    end

    describe "blocking information" do
      context "when user is not blocked by form_email" do
        it "returns nil for blocked_by_form_email_object" do
          expect(props[:blocked_by_form_email_object]).to be_nil
        end
      end

      context "when user is blocked by form_email" do
        let(:blocked_at_time) { 2.days.ago }
        let(:created_at_time) { 5.days.ago }

        before do
          blocked_object = double(
            "BlockedFormEmail",
            blocked_at: blocked_at_time,
            created_at: created_at_time
          )
          allow(user).to receive(:blocked_by_form_email_object).and_return(blocked_object)
        end

        it "returns the blocking information" do
          expect(props[:blocked_by_form_email_object]).to eq(
            blocked_at: blocked_at_time,
            created_at: created_at_time
          )
        end
      end

      context "when user is not blocked by form_email_domain" do
        it "returns nil for blocked_by_form_email_domain_object" do
          expect(props[:blocked_by_form_email_domain_object]).to be_nil
        end
      end

      context "when user is blocked by form_email_domain" do
        let(:blocked_at_time) { 3.days.ago }
        let(:created_at_time) { 6.days.ago }

        before do
          blocked_object = double(
            "BlockedFormEmailDomain",
            blocked_at: blocked_at_time,
            created_at: created_at_time
          )
          allow(user).to receive(:blocked_by_form_email_domain_object).and_return(blocked_object)
        end

        it "returns the blocking information" do
          expect(props[:blocked_by_form_email_domain_object]).to eq(
            blocked_at: blocked_at_time,
            created_at: created_at_time
          )
        end
      end
    end

    describe "user memberships" do
      context "when user has no memberships" do
        it "returns an empty array" do
          expect(props[:admin_manageable_user_memberships]).to eq([])
        end
      end

      context "when user has memberships" do
        let(:seller) { create(:user) }
        let!(:membership) do
          create(:team_membership, user:, seller:, role: TeamMembership::ROLE_ADMIN)
        end

        it "returns an array of membership hashes" do
          memberships = props[:admin_manageable_user_memberships]

          expect(memberships).to be_an(Array)
          expect(memberships.size).to eq(1)
        end

        it "includes membership attributes" do
          membership_data = props[:admin_manageable_user_memberships].first

          expect(membership_data).to include(
            id: membership.id,
            role: membership.role,
            last_accessed_at: membership.last_accessed_at,
            created_at: membership.created_at,
            updated_at: membership.updated_at
          )
        end

        it "includes seller information" do
          membership_data = props[:admin_manageable_user_memberships].first

          expect(membership_data[:seller]).to eq(
            external_id: seller.external_id,
            avatar_url: seller.avatar_url,
            display_name_or_email: seller.display_name_or_email
          )
        end
      end
    end

    describe "compliance info" do
      context "when user has no compliance info" do
        before do
          allow(user).to receive(:alive_user_compliance_info).and_return(nil)
        end

        it "returns nil" do
          expect(props[:alive_user_compliance_info]).to be_nil
        end
      end

      context "when user has compliance info" do
        let(:compliance_info) do
          create(:user_compliance_info, user:)
        end

        before do
          compliance_info
        end

        it "returns a hash with compliance information" do
          info = props[:alive_user_compliance_info]

          expect(info).to include(
            :is_business,
            :first_name,
            :last_name,
            :street_address,
            :city,
            :state,
            :state_code,
            :zip_code,
            :country,
            :country_code,
            :business_name,
            :business_type,
            :business_street_address,
            :business_city,
            :business_state,
            :business_state_code,
            :business_zip_code,
            :business_country,
            :business_country_code,
            :created_at,
            :has_individual_tax_id,
            :has_business_tax_id
          )
        end

        it "returns the correct field values" do
          info = props[:alive_user_compliance_info]

          expect(info[:first_name]).to eq(compliance_info.first_name)
          expect(info[:last_name]).to eq(compliance_info.last_name)
          expect(info[:is_business]).to eq(compliance_info.is_business)
          expect(info[:state_code]).to eq(compliance_info.state_code)
          expect(info[:country_code]).to eq(compliance_info.country_code)
          expect(info[:business_state_code]).to eq(compliance_info.business_state_code)
          expect(info[:business_country_code]).to eq(compliance_info.business_country_code)
          expect(info[:has_individual_tax_id]).to eq(compliance_info.has_individual_tax_id)
          expect(info[:has_business_tax_id]).to eq(compliance_info.has_business_tax_id)
        end
      end
    end
  end
end
