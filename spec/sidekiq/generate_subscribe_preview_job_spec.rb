# frozen_string_literal: true

require "spec_helper"

describe GenerateSubscribePreviewJob do
  let(:user) { create(:user, username: "foo") }

  describe "#perform" do
    context "image generation works" do
      before :each do
        subscribe_preview = File.binread("#{Rails.root}/spec/support/fixtures/subscribe_preview.png")
        allow(SubscribePreviewGeneratorService).to receive(:generate_pngs).and_return(subscribe_preview)
      end

      it "attaches the generated image to the user" do
        expect(user.subscribe_preview).not_to be_attached
        described_class.new.perform(user.id)
        expect(user.reload.subscribe_preview).to be_attached
      end
    end

    context "image generation does not work" do
      before :each do
        allow(SubscribePreviewGeneratorService).to receive(:generate_pngs).and_return([nil])
      end

      it "raises 'Subscribe Preview could not be generated'" do
        expected_error = "Subscribe Preview could not be generated for user.id=#{user.id}"
        expect { described_class.new.perform(user.id) }.to raise_error(expected_error)
      end
    end

    context "error occurred" do
      before :each do
        @error = "Failure"
        allow(SubscribePreviewGeneratorService).to receive(:generate_pngs).and_raise(@error)
      end

      it "propagates the error to Sidekiq" do
        expect { described_class.new.perform(user.id) }.to raise_error(@error)
      end
    end
  end
end
