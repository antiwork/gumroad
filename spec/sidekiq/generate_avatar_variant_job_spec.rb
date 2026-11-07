# frozen_string_literal: true

require "spec_helper"

describe GenerateAvatarVariantJob do
  describe "#perform" do
    def avatar_variant_record(user)
      blob = user.reload.avatar.blob
      blob.variant_records.find_by(variation_digest: blob.variant(User::AVATAR_VARIANT_TRANSFORMATIONS).variation.digest)
    end

    it "processes the 400x400 avatar variant ahead of the first page view" do
      user = create(:user, :with_avatar)
      expect(avatar_variant_record(user)).to be_nil

      described_class.new.perform(user.id)

      expect(avatar_variant_record(user).image).to be_attached
    end

    it "does nothing for a user without an avatar" do
      expect { described_class.new.perform(create(:user).id) }.not_to raise_error
    end

    it "does nothing for a user that no longer exists" do
      expect { described_class.new.perform(0) }.not_to raise_error
    end

    it "gives up without retrying when the uploaded avatar is gone from storage" do
      user = create(:user, :with_avatar)
      user.avatar.blob.service.delete(user.avatar.key)

      expect { described_class.new.perform(user.id) }.not_to raise_error
      expect(avatar_variant_record(user)).to be_nil
    end

    # Unique jobs are off in test. This runs the real client and server lock middleware on the test Redis.
    context "with the unique lock enabled" do
      around do |example|
        SidekiqUniqueJobs.use_config(enabled: true) do
          Sidekiq::Testing.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
          example.run
        ensure
          Sidekiq::Testing.server_middleware { |chain| chain.remove SidekiqUniqueJobs::Middleware::Server }
        end
      end

      it "drops a duplicate while queued but queues an avatar replaced while the job runs" do
        user = create(:user, :with_avatar)
        first_avatar = user.avatar.blob
        expect(described_class.jobs.size).to eq(1)
        expect(described_class.perform_async(user.id)).to be_nil

        replaced = false
        allow_any_instance_of(User).to receive(:avatar_variant).and_wrap_original do |original, *args, **kwargs|
          original.call(*args, **kwargs).tap do
            next if replaced

            replaced = true
            user.avatar.attach(io: File.open(Rails.root.join("spec", "support", "fixtures", "smilie.png")), filename: "replacement.png")
          end
        end

        described_class.perform_one

        first_variant_digest = first_avatar.variant(User::AVATAR_VARIANT_TRANSFORMATIONS).variation.digest
        expect(first_avatar.variant_records.exists?(variation_digest: first_variant_digest)).to be(true)
        expect(described_class.jobs.map { _1["args"] }).to eq([[user.id]])
        described_class.perform_one
        expect(user.reload.avatar.blob).not_to eq(first_avatar)
        expect(avatar_variant_record(user).image).to be_attached
      end
    end
  end

  describe "job options" do
    it "runs on the low queue, one queued job per user" do
      expect(described_class.get_sidekiq_options).to include("lock" => :until_executing, "queue" => :low)
    end
  end
end
