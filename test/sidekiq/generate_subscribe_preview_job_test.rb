# frozen_string_literal: true

require "test_helper"

class GenerateSubscribePreviewJobTest < ActiveSupport::TestCase
  self.described_class = GenerateSubscribePreviewJob



  context_ GenerateSubscribePreviewJob do
    let(:user) { create(:user, username: "foo") }

  context_ "#perform" do
  context_ "image generation works" do
        before :each do
          subscribe_preview = File.binread("#{Rails.root}/test/support/fixtures/subscribe_preview.png")
          allow(SubscribePreviewGeneratorService).to receive(:generate_pngs).and_return(subscribe_preview)
        end

  test "attaches the generated image to the user" do
          expect(user.subscribe_preview).not_to be_attached
          described_class.new.perform(user.id)
          expect(user.reload.subscribe_preview).to be_attached
        end
      end

  context_ "image generation does not work" do
        before :each do
          allow(SubscribePreviewGeneratorService).to receive(:generate_pngs).and_return([nil])
        end

  test "raises 'Subscribe Preview could not be generated'" do
          expected_error = "Subscribe Preview could not be generated for user.id=#{user.id}"
          expect { described_class.new.perform(user.id) }.to raise_error(expected_error)
        end
      end

  context_ "error occurred" do
        before :each do
          @error = "Failure"
          allow(SubscribePreviewGeneratorService).to receive(:generate_pngs).and_raise(@error)
        end

  test "propagates the error to Sidekiq" do
          expect { described_class.new.perform(user.id) }.to raise_error(@error)
        end
      end
    end
  end
end
