# frozen_string_literal: true

require "spec_helper"

describe Onetime::GenerateSubscribePreviews do
  let(:users) { create_list(:user, 2) }
  let(:user_ids) { users.map(&:id) }

  describe "#perform" do
    context "when subscribe preview generation succeeds" do
      it "attaches the generated image to the user and enables the rollout flag for the user" do
        subscribe_preview = File.binread("#{Rails.root}/spec/support/fixtures/subscribe_preview.png")
        allow(SubscribePreviewGeneratorService).to receive(:generate_pngs).and_return([subscribe_preview, subscribe_preview])

        expect(users.first.subscribe_preview).not_to be_attached
        expect(users.second.subscribe_preview).not_to be_attached

        described_class.new.perform(user_ids)

        expect(users.first.reload.subscribe_preview).to be_attached
        expect(users.second.reload.subscribe_preview).to be_attached
      end
    end

    context "image generation does not work" do
      it "raises an error" do
        allow(SubscribePreviewGeneratorService).to receive(:generate_pngs).and_return([nil])
        expect { described_class.new.perform(user_ids) }.to raise_error("Failed to generate all subscribe previews for top sellers")
      end
    end

    context "error occurred" do
      it "propagates the error to Sidekiq" do
        allow(SubscribePreviewGeneratorService).to receive(:generate_pngs).and_raise("WHOOPS")
        expect { described_class.new.perform(user_ids) }.to raise_error("WHOOPS")
      end
    end
  end
end
