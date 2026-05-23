# frozen_string_literal: true

require "test_helper"
require "shared_examples/deletable_concern"

class FollowerTest < ActiveSupport::TestCase
  self.described_class = Follower



  context_ Follower do
    it_behaves_like "Deletable concern", :follower

    let(:active_follower) { create(:active_follower) }
    let(:deleted_follower) { create(:deleted_follower) }
    let(:unconfirmed_follower) { create(:follower) }

  context_ ".unsubscribe" do
  test "marks follower as deleted" do
        follower = create(:active_follower)
        Follower.unsubscribe(follower.followed_id, follower.email)

        expect(follower.reload).to be_deleted
      end
    end

  context_ "scopes" do
      before do
        active_follower
        deleted_follower
        unconfirmed_follower
      end

  context_ ".confirmed" do
  test "returns only confirmed followers" do
          expect(Follower.confirmed).to contain_exactly(active_follower)
        end
      end

  context_ ".active" do
  test "returns only confirmed and alive followers" do
          expect(Follower.active).to match_array(active_follower)
        end
      end
    end

  context_ "uniqueness" do
      before do
        @follower = create(:follower)
      end

  test "is not valid with same followed_id and email" do
        expect(Follower.new(email: @follower.email, followed_id: @follower.followed_id)).not_to be_valid
      end

  test "is not saved to the database with the same followed_id and email" do
        follower = Follower.new(email: @follower.email)
        follower.followed_id = @follower.followed_id
        expect { follower.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
      end
    end

  context_ "invalid email" do
  test "is not valid with space in the email" do
        expect(Follower.new(email: "sahil lavingia@gmail.com")).not_to be_valid
      end
    end

  context_ "#mark_undeleted!" do
  test "does nothing when follower is not deleted" do
        expect(active_follower).not_to receive(:send_confirmation_email)
        active_follower.mark_undeleted!
        expect(active_follower).not_to be_deleted
      end

  test "undeletes a follower" do
        expect do
          deleted_follower.mark_undeleted!
        end.to change { deleted_follower.deleted? }.from(true).to(false)
      end
    end

  context_ "#mark_deleted!" do
      it do
        follower = create(:follower)
        follower.mark_deleted!
        follower.reload
        expect(follower).to be_deleted
        expect(follower).not_to be_confirmed
      end
    end

  context_ "#confirm!" do
  test "does nothing when follower is confirmed" do
        active_follower
        expect(active_follower).not_to receive(:send_confirmation_email)
        active_follower.confirm!
        expect(active_follower).to be_confirmed
      end

  test "sets confirmed_at to time when follower is not confirmed" do
        time = Time.current
        allow(Time).to receive(:current).and_return(time)
        user = create(:user)

        unconfirmed_follower = create(:follower, id: 99, user:)
        unconfirmed_follower.confirm!
        expect(unconfirmed_follower.confirmed_at.to_s).to eq(time.utc.to_s)
      end

  test "removes deleted_at" do
        deleted_follower.confirm!
        expect(deleted_follower.deleted_at).to eq(nil)
      end
    end

  context_ "#confirmed?" do
  test "returns if follower has confirmed following or not" do
        expect(active_follower.confirmed?).to eq(true)
        expect(unconfirmed_follower.confirmed?).to eq(false)
      end
    end

  context_ "#unconfirmed?" do
  test "returns if follower has unconfirmed following or not" do
        expect(active_follower.unconfirmed?).to eq(false)
        expect(unconfirmed_follower.unconfirmed?).to eq(true)
      end
    end

  context_ "validations" do
      before do
        @follower = create(:follower)
      end

  test "checks for valid entry in table User exists by (and only) id for follower" do
        follower_user = create(:user)

        @follower.follower_user_id = follower_user.id * 2
        expect(@follower.valid?).to be(false)

        @follower.follower_user_id = follower_user.id
        @follower.email = follower_user.email + "dummy"
        expect(@follower.valid?).to be(true)

        @follower.follower_user_id = nil
        expect(@follower.valid?).to be(true)
      end

  test "prevents records to be saved as both confirmed and deleted" do
        @follower.confirmed_at = Time.current
        @follower.deleted_at = Time.current
        expect(@follower.valid?).to eq(false)
      end
    end

  context_ "get_email" do
      before do
        @follower_user = create(:user)
        @follower = create(:follower, follower_user_id: @follower_user.id)
      end

  test "fetches email from the user table if follower user id exists" do
        expect(@follower.follower_user_id).not_to be(nil)
        expect(@follower.follower_email).to eq(@follower_user.email)
      end

  test "fetches email from the followers record if follower_user_id does not exist" do
        @follower.follower_user_id = nil
        @follower.save!

        expect(@follower.follower_email).to eq(@follower.email)
        expect(@follower.email).not_to eq(@follower_user.email)
      end

  test "fetches email from the followers record if follower_user_id exists but the user has a blank email" do
        @follower_user.update_column(:email, "")

        expect(@follower.follower_email).to eq(@follower.email)
        expect(@follower.email).not_to eq(@follower_user.email)
      end

  test "has the right error message for duplicate followers" do
        duplicate_follower = Follower.new(user: @follower.user, email: @follower.email)
        duplicate_follower.save
        expect(duplicate_follower.errors.full_messages.to_sentence).to eq "You are already following this creator."
      end
    end

  context_ "schedule_workflow_jobs" do
      before do
        @seller = create(:user)
        @product = create(:product, user: @seller)
        @follower_workflow = create(:workflow, seller: @seller, link: nil, workflow_type: Workflow::FOLLOWER_TYPE, published_at: 1.week.ago)
        @seller_workflow = create(:workflow, seller: @seller, link: nil, workflow_type: Workflow::SELLER_TYPE, published_at: 1.week.ago)
        @installment1 = create(:installment, workflow: @follower_workflow)
        @installment_rule1 = create(:installment_rule, installment: @installment1, delayed_delivery_time: 3.days)
        @installment2 = create(:installment, workflow: @follower_workflow)
        @installment_rule2 = create(:installment_rule, installment: @installment2, delayed_delivery_time: 3.days)
        @seller_installment = create(:installment, workflow: @seller_workflow)
        @seller_installment_rule = create(:installment_rule, installment: @seller_installment, delayed_delivery_time: 1.day)
      end

  test "enqueues 2 installment jobs when follower confirms" do
        follower = Follower.create!(user: @seller, email: "email@test.com")
        follower.confirm!

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(2)
      end

  test "doesn't enqueue installment jobs when follower doesn't confirm" do
        user = create(:user)
        Follower.create!(user:, email: "email@test.com")

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
      end

  test "doesn't enqueue installment jobs when workflow is marked as member_cancellation and a follower confirms" do
        @follower_workflow.update!(workflow_trigger: "member_cancellation")

        follower = Follower.create!(user: @seller, email: "email@test.com")
        follower.confirm!

        expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
      end
    end

  context_ "#send_confirmation_email" do
  context_ "when confirmation emails are sent repeatedly" do
  test "suppresses repeated sending of confirmation emails" do
          unconfirmed_follower

          # Erase the information about the first confirmation email
          Rails.cache.clear

          expect do
            unconfirmed_follower.send_confirmation_email
          end.to have_enqueued_mail(FollowerMailer, :confirm_follower).with(unconfirmed_follower.followed_id, unconfirmed_follower.id)

          # Try sending again
          expect do
            unconfirmed_follower.send_confirmation_email
          end.not_to have_enqueued_mail(FollowerMailer, :confirm_follower).with(unconfirmed_follower.followed_id, unconfirmed_follower.id)
        end
      end
    end

  context_ "AudienceMember callbacks" do
  context_ "#should_be_audience_member?" do
  test "only returns true for expected cases" do
          expect(create(:follower).should_be_audience_member?).to eq(false)
          expect(create(:active_follower).should_be_audience_member?).to eq(true)
          expect(create(:deleted_follower).should_be_audience_member?).to eq(false)

          follower = create(:active_follower)
          follower.update_column(:email, nil)
          expect(follower.should_be_audience_member?).to eq(false)
          follower.update_column(:email, "some-invalid-email")
          expect(follower.should_be_audience_member?).to eq(false)
        end
      end

  test "adds follower to audience when confirmed" do
        follower = create(:follower)
        expect do
          follower.confirm!
        end.to change(AudienceMember, :count).by(1)

        member = AudienceMember.find_by(email: follower.email, seller: follower.user)
        expect(member.details["follower"]).to eq({ "id" => follower.id, "created_at" => follower.created_at.iso8601 })
      end

  test "removes follower from audience when marked as deleted" do
        follower = create(:active_follower)
        create(:purchase, :from_seller, seller: follower.user, email: follower.email)
        expect do
          follower.mark_deleted!
        end.not_to change(AudienceMember, :count)

        member = AudienceMember.find_by(email: follower.email, seller: follower.user)
        expect(member.details["follower"]).to be_nil
        expect(member.details["purchases"]).to be_present
      end

  test "removes audience member when marked as deleted with no other audience types" do
        follower = create(:active_follower)
        expect do
          follower.mark_deleted!
        end.to change(AudienceMember, :count).by(-1)

        member = AudienceMember.find_by(email: follower.email, seller: follower.user)
        expect(member).to be_nil
      end

  test "recreates audience member when changing email" do
        follower = create(:active_follower)
        old_email = follower.email
        new_email = "new@example.com"
        follower.update!(email: new_email)

        old_member = AudienceMember.find_by(email: old_email, seller: follower.user)
        new_member = AudienceMember.find_by(email: new_email, seller: follower.user)
        expect(old_member).to be_nil
        expect(new_member).to be_present
      end
    end
  end
end
