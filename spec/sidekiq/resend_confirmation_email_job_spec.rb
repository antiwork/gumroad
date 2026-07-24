# frozen_string_literal: true

require "spec_helper"

describe ResendConfirmationEmailJob do
  let(:suppression_manager) { instance_double(EmailSuppressionManager) }

  describe "#perform" do
    context "when the user still needs to confirm their account" do
      let(:user) { create(:user, confirmed_at: nil) }

      before do
        allow(EmailSuppressionManager).to receive(:new).with(user.email).and_return(suppression_manager)
        allow(suppression_manager).to receive(:remove_from_lists)
      end

      it "clears the bounce and block suppressions for the address before re-sending the confirmation email" do
        # Order matters: if we re-send before clearing the suppression, SendGrid
        # drops the send. Record the calls in sequence to prove unsuppress-first.
        sequence = []
        allow(suppression_manager).to receive(:remove_from_lists) { |lists| sequence << [:remove_from_lists, lists] }
        allow_any_instance_of(User).to receive(:send_confirmation_instructions) { sequence << :send_confirmation_instructions }

        described_class.new.perform(user.id)

        expect(sequence).to eq([[:remove_from_lists, [:bounces, :blocks]], :send_confirmation_instructions])
      end

      it "never touches the spam-report or unsubscribe consent surfaces" do
        expect(suppression_manager).to receive(:remove_from_lists).with([:bounces, :blocks])

        described_class.new.perform(user.id)
      end

      it "still sends the confirmation email when the suppression API fails" do
        # The send is the critical payload — a SendGrid suppression outage must not
        # burn the job's retries and silently strand the user unconfirmed.
        allow(suppression_manager).to receive(:remove_from_lists).and_raise(SocketError, "sendgrid down")
        expect(ErrorNotifier).to receive(:notify)
        expect_any_instance_of(User).to receive(:send_confirmation_instructions)

        described_class.new.perform(user.id)
      end
    end

    context "when the user is confirming a changed email address" do
      let(:user) do
        create(:user).tap do |u|
          u.confirm
          u.update!(email: "changed@example.com")
        end
      end

      it "clears suppressions for the pending unconfirmed address, not the current one" do
        expect(user.unconfirmed_email).to eq("changed@example.com")
        expect(EmailSuppressionManager).to receive(:new).with("changed@example.com").and_return(suppression_manager)
        expect(suppression_manager).to receive(:remove_from_lists).with([:bounces, :blocks])

        described_class.new.perform(user.id)
      end
    end

    context "when the user confirmed before the job ran" do
      let(:user) { create(:user) }

      it "does nothing" do
        expect(EmailSuppressionManager).not_to receive(:new)
        expect_any_instance_of(User).not_to receive(:send_confirmation_instructions)

        described_class.new.perform(user.id)
      end
    end

    context "when the user no longer exists" do
      it "does nothing" do
        expect(EmailSuppressionManager).not_to receive(:new)

        described_class.new.perform(0)
      end
    end

    context "when the user has been deleted" do
      let(:user) { create(:user, confirmed_at: nil) }

      before { user.mark_deleted! }

      it "does nothing" do
        expect(EmailSuppressionManager).not_to receive(:new)

        described_class.new.perform(user.id)
      end
    end
  end
end
