# frozen_string_literal: true

require("spec_helper")

describe "/follow page", type: :system, js: true do
  before do
    @email = generate(:email)
    @creator = create(:named_user)
    @user = create(:user)
  end

  describe "following" do
    it "allows user to subscribe when logged in" do
      login_as(@user)
      expect do
        visit "#{@creator.subdomain_with_protocol}/follow"
        click_on("Subscribe")
        wait_for_ajax
        Follower.where(email: @user.email).first.confirm!
      end.to change { Follower.active.count }.by 1
      expect(Follower.last.follower_user_id).to eq @user.id
    end

    it "doesn't allow user to subscribe to self when logged in" do
      login_as(@creator)
      visit "#{@creator.subdomain_with_protocol}/follow"
      fill_in("Your email address", with: @creator.email)
      click_on("Subscribe")
      expect(page).to have_alert(text: "As the creator of this profile, you can't follow yourself!")
    end

    it "allows user to subscribe when logged out" do
      expect do
        visit "#{@creator.subdomain_with_protocol}/follow"
        fill_in("Your email address", with: @email)
        click_on("Subscribe")
        wait_for_ajax
        Follower.find_by(email: @email).confirm!
      end.to change { Follower.active.count }.by 1
      expect(Follower.last.email).to eq @email
    end
  end
end
