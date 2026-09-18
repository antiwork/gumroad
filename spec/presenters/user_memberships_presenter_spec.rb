# frozen_string_literal: true

require "spec_helper"

describe UserMembershipsPresenter do
  let(:user) { create(:user) }
  let(:seller_one) { create(:user, :without_username) }
  let(:seller_two) { create(:user) }
  let(:seller_three) { create(:user) }
  let!(:team_membership_owner) { user.create_owner_membership_if_needed! }
  let!(:team_membership_one) { create(:team_membership, user:, seller: seller_one) }
  let!(:team_membership_two) { create(:team_membership, user:, seller: seller_two) }
  let!(:team_membership_three) { create(:team_membership, seller: seller_three) } # for other user
  let(:pundit_user) { SellerContext.new(user:, seller: seller_one) }

  it "returns all memberships that belong to the user, ordered" do
    team_membership_one.update!(last_accessed_at: Time.current)

    props = UserMembershipsPresenter.new(pundit_user:).props
    expect(props.length).to eq(3)
    expect(props[0]).to eq(expected_memberships(team_membership_one, has_some_read_only_access: false, is_selected: true))
    expect(props[1]).to eq(expected_memberships(team_membership_two, has_some_read_only_access: false))
    expect(props[2]).to eq(expected_memberships(team_membership_owner, has_some_read_only_access: false))
  end

  context "when role is marketing" do
    before do
      team_membership_one.update!(
        last_accessed_at: Time.current,
        role: TeamMembership::ROLE_MARKETING
      )
    end

    it "returns correct has_some_read_only_access" do
      props = UserMembershipsPresenter.new(pundit_user:).props
      expect(props[0]).to eq(expected_memberships(team_membership_one, has_some_read_only_access: true, is_selected: true))
    end
  end

  context "with deleted membership" do
    before do
      team_membership_two.update_as_deleted!
    end

    it "doesn't include deleted membership" do
      props = UserMembershipsPresenter.new(pundit_user:).props
      expect(props.length).to eq(2)
      expect(props[0]).to eq(expected_memberships(team_membership_one, has_some_read_only_access: false, is_selected: true))
      expect(props[1]).to eq(expected_memberships(team_membership_owner, has_some_read_only_access: false))
    end
  end

  it "hides deleted sellers while preserving membership data, ordering, roles and restoration" do
    team_membership_one.update!(last_accessed_at: 1.hour.ago)
    team_membership_two.update!(role: TeamMembership::ROLE_SUPPORT, last_accessed_at: 2.hours.ago)
    deleted_membership = create(:team_membership, user:, deleted_at: Time.current)
    brand = create(:user, name: "Synthetic brand")
    brand_membership = create(:team_membership, user:, seller: brand, last_accessed_at: Time.current)
    original_attributes = brand_membership.attributes
    brand.deactivate!

    props = UserMembershipsPresenter.new(pundit_user:).props

    expect(props).to eq([
                          expected_memberships(team_membership_one, has_some_read_only_access: false, is_selected: true),
                          expected_memberships(team_membership_two, has_some_read_only_access: true),
                          expected_memberships(team_membership_owner, has_some_read_only_access: false),
                        ])
    expect(brand_membership.reload.attributes).to eq(original_attributes)

    brand.reactivate!
    restored_context = SellerContext.new(user: User.find(user.id), seller: seller_one)
    restored_props = UserMembershipsPresenter.new(pundit_user: restored_context).props

    expect(restored_props).to eq([
                                   expected_memberships(brand_membership, has_some_read_only_access: false),
                                   *props,
                                 ])
    expect(deleted_membership.reload).to be_deleted
  end

  def expected_memberships(team_membership, has_some_read_only_access:, is_selected: false)
    seller = team_membership.seller
    {
      id: team_membership.external_id,
      seller_name: seller.display_name(prefer_email_over_default_username: true),
      seller_avatar_url: seller.avatar_url,
      has_some_read_only_access:,
      is_selected:
    }
  end

  context "when owner membership is missing" do
    before do
      team_membership_owner.destroy!
    end

    context "with other memberships present" do
      it "notifies error tracker" do
        expect(ErrorNotifier).to receive(:notify).exactly(:once).with("Missing owner team membership for user #{user.id}")
        props = UserMembershipsPresenter.new(pundit_user:).props
        expect(props).to eq([])
      end
    end

    context "without other memberships" do
      before do
        user.user_memberships.delete_all
      end

      it "doesn't notify" do
        expect(ErrorNotifier).not_to receive(:notify)
        props = UserMembershipsPresenter.new(pundit_user:).props
        expect(props).to eq([])
      end
    end
  end
end
