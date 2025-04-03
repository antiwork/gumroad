# frozen_string_literal: false

describe Follower::CreateService do
  let(:user) { create(:user) }
  let(:follower_user) { create(:user) }
  let(:follower) { create(:follower, user:) }
  let(:active_follower) { create(:active_follower, user:) }
  let(:deleted_follower) { create(:deleted_follower, user:) }

  context "when follower is present" do
    it "updates the source of the follow and follower_user_id" do
      Follower::CreateService.perform(
        followed_user: user,
        follower_email: deleted_follower.email,
        follower_attributes: {
          source: "welcome-greeter",
          follower_user_id: follower_user.id
        }
      )

      deleted_follower.reload
      expect(deleted_follower.source).to eq("welcome-greeter")
      expect(deleted_follower.follower_user_id).to eq(follower_user.id)
    end

    context "when follower is cancelled" do
      it "uncancels the follower" do
        Follower::CreateService.perform(
          followed_user: user,
          follower_email: deleted_follower.email
        )

        deleted_follower.reload
        expect(deleted_follower.deleted?).to be_falsey
        expect(deleted_follower.confirmed?).to be_falsey
      end
    end

    context "when follower exists in master DB but not in replica" do
      it "reactivates the existing follower" do
        deleted_follower

        # Mock a situation when an existing follower is at first not found because
        # changes have not propagated to replica DB
        allow(user.followers).to receive(:find_by)
                                     .with(email: deleted_follower.email)
                                     .and_return(nil, deleted_follower)

        # At first attempt to save the follower, fail with ActiveRecord::RecordNotUnique
        behaviour = [:raise_once, :then_call_original]
        allow_any_instance_of(Follower).to receive(:save!).and_wrap_original do |m, *args|
          raise(ActiveRecord::RecordNotUnique) if behaviour.shift == :raise_once
          m.call(*args)
        end


        Follower::CreateService.perform(
          followed_user: user,
          follower_email: deleted_follower.email
        )

        deleted_follower.reload
        expect(deleted_follower.deleted?).to be_falsey
      end
    end

    describe "confirmation" do
      context "when follower not confirmed nor cancelled" do
        it "sends the confirmation email again" do
          expect do
            Follower::CreateService.perform(
              followed_user: user,
              follower_email: follower.email,
            )
          end.to have_enqueued_mail(FollowerMailer, :confirm_follower).with(user.id, follower.id)
        end
      end

      context "when imported from CSV" do
        it "auto-confirms and does not send the confirmation email" do
          expect do
            follower = Follower::CreateService.perform(
              followed_user: user,
              follower_email: "imported@email.com",
              follower_attributes: {
                source: Follower::From::CSV_IMPORT
              }
            )

            expect(follower.confirmed?).to be_truthy
          end.to_not have_enqueued_mail(FollowerMailer, :confirm_follower)

          # Re-importing existing followers should not trigger an email either
          expect do
            follower = Follower::CreateService.perform(
              followed_user: user,
              follower_email: "imported@email.com",
              follower_attributes: {
                source: Follower::From::CSV_IMPORT
              }
            )
            expect(follower.confirmed?).to be_truthy
          end.to_not have_enqueued_mail(FollowerMailer, :confirm_follower)
        end
      end

      context "when follower is not logged in" do
        it "does not auto-confirm and sends the confirmation email" do
          expect do
            follower = Follower::CreateService.perform(
              followed_user: user,
              follower_email: deleted_follower.email
            )
            expect(follower.confirmed?).to be_falsey
          end.to have_enqueued_mail(FollowerMailer, :confirm_follower).with(user.id, deleted_follower.id)
        end

        it "sends the confirmation email even if follower is confirmed" do
          expect do
            Follower::CreateService.perform(
              followed_user: user,
              follower_email: active_follower.email
            )
          end.to have_enqueued_mail(FollowerMailer, :confirm_follower).with(user.id, active_follower.id)
        end

        it "does not send the confirmation email if the new email is invalid" do
          expect do
            follower = Follower::CreateService.perform(
              followed_user: user,
              follower_email: active_follower.email,
              follower_attributes: { email: "invalid email" }
            )
            expect(follower.valid?).to eq(false)
          end.not_to have_enqueued_mail(FollowerMailer, :confirm_follower).with(user.id, active_follower.id)
        end
      end

      context "when follower is logged in" do
        it "auto-confirms if logged-in user has confirmed email" do
          confirmed_user = create(:user)

          expect do
            follower = Follower::CreateService.perform(
              followed_user: user,
              follower_email: confirmed_user.email,
              logged_in_user: confirmed_user
            )
            expect(follower.confirmed?).to be_truthy
          end.to_not have_enqueued_mail(FollowerMailer, :confirm_follower)
        end

        it "sends the confirmation email if-logged in user has unconfirmed email" do
          unconfirmed_user = create(:unconfirmed_user)

          expect do
            follower = Follower::CreateService.perform(
              followed_user: user,
              follower_email: unconfirmed_user.email,
              logged_in_user: unconfirmed_user
            )
            expect(follower.confirmed?).to be_falsey
          end.to have_enqueued_mail(FollowerMailer, :confirm_follower).with(user.id, anything)
        end
      end
    end
  end

  context "when follower is not present" do
    it do
      expect do
        Follower::CreateService.perform(
          followed_user: user,
          follower_email: "new@email.com",
          follower_attributes: { source: "welcome-greeter" }
        )
      end.to have_enqueued_mail(FollowerMailer, :confirm_follower)
      follower = Follower.find_by(email: "new@email.com")
      expect(follower.source).to eq("welcome-greeter")
      expect(follower.confirmed?).to be_falsey
    end

    it "does not send the confirmation email if the email is invalid" do
      expect do
        follower = Follower::CreateService.perform(
          followed_user: user,
          follower_email: "invalid email",
          follower_attributes: { source: "welcome-greeter" }
        )
        expect(follower.persisted?).to eq(false)
        expect(follower.valid?).to eq(false)
      end.not_to have_enqueued_mail(FollowerMailer, :confirm_follower)
    end
  end
end
