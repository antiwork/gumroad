# frozen_string_literal: true

require "spec_helper"

describe AttributeBlockable do
  let(:blocked_email) { "blocked@example.com" }
  let(:unblocked_email) { "unblocked@example.com" }
  let(:user_with_blocked_email) { create(:user, email: blocked_email) }
  let(:user_with_unblocked_email) { create(:user, email: unblocked_email) }

  before do
    BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], blocked_email, 1)
  end

  after do
    BlockedObject.delete_all
  end

  describe ".attr_blockable" do
    it "defines blocked? methods for the specified attribute" do
      expect(user_with_blocked_email).to respond_to(:blocked_by_email?)
      expect(user_with_blocked_email).to respond_to(:blocked_by_email_object)
    end

    it "defines blocked? methods for custom method names" do
      expect(user_with_blocked_email).to respond_to(:blocked_by_form_email?)
      expect(user_with_blocked_email).to respond_to(:blocked_by_form_email_object)
    end

    it "defines block and unblock methods" do
      expect(user_with_blocked_email).to respond_to(:block_by_email!)
      expect(user_with_blocked_email).to respond_to(:unblock_by_email!)
    end

    describe "generated instance methods" do
      describe "#blocked_by_email?" do
        it "returns true for blocked emails" do
          expect(user_with_blocked_email.blocked_by_email?).to be true
        end

        it "returns false for unblocked emails" do
          expect(user_with_unblocked_email.blocked_by_email?).to be false
        end

        it "returns false for blank email" do
          user = create(:user)
          user.update_column(:email, "")
          expect(user.blocked_by_email?).to be false
        end
      end

      describe "#blocked_by_email_object" do
        it "returns blocked object with blocked_at timestamp for blocked emails" do
          blocked_object = user_with_blocked_email.blocked_by_email_object
          expect(blocked_object).to be_a(BlockedObject)
          expect(blocked_object.blocked_at).to be_a(DateTime)
          expect(blocked_object.blocked_at.to_time).to be_within(1.minute).of(Time.current)
        end

        it "returns nil for unblocked emails" do
          expect(user_with_unblocked_email.blocked_by_email_object).to be_nil
        end

        it "caches the result in blocked_by_attributes" do
          user_with_blocked_email.blocked_by_email_object
          expect(user_with_blocked_email.blocked_by_attributes["email"]).not_to be_nil
        end

        it "uses cached value on subsequent calls" do
          first_result = user_with_blocked_email.blocked_by_email_object

          blocked_object = BlockedObject.find_by(object_value: blocked_email)
          blocked_object.update!(blocked_at: 1.year.ago)

          second_result = user_with_blocked_email.blocked_by_email_object
          expect(second_result.blocked_at).to eq(first_result.blocked_at)
        end
      end

      describe "#blocked_by_form_email?" do
        it "uses the email attribute for blocking checks" do
          expect(user_with_blocked_email.blocked_by_form_email?).to be true
          expect(user_with_unblocked_email.blocked_by_form_email?).to be false
        end

        it "does not consider unblocked records" do
          user = create(:user, email: "test_unblocked_#{SecureRandom.hex(4)}@example.com")
          blocked_object = BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], user.email, 1)

          expect(user.reload.blocked_by_form_email?).to be true
          expect(user.blocked_by_form_email_object).not_to be_nil

          blocked_object.unblock!

          expect(user.reload.blocked_by_form_email?).to be false
          expect(user.blocked_by_form_email_object).to be_nil
        end

        it "finds active block after unblocking and reblocking" do
          user = create(:user, email: "test_reblock_#{SecureRandom.hex(4)}@example.com")

          first_block = BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], user.email, 1)
          expect(user.reload.blocked_by_form_email?).to be true

          first_block.unblock!
          expect(user.reload.blocked_by_form_email?).to be false
          expect(user.blocked_by_form_email_object).to be_nil

          second_block = BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], user.email, 1)

          expect(first_block.id).to eq(second_block.id)
          expect(user.reload.blocked_by_form_email?).to be true
          expect(user.blocked_by_form_email_object.id).to eq(first_block.id)
          expect(user.blocked_by_form_email_object.blocked_at).not_to be_nil
        end
      end

      describe "#block_by_email!" do
        it "blocks the user by their email" do
          user = create(:user, email: "test@example.com")
          expect(user.blocked_by_email?).to be false

          user.block_by_email!
          expect(user.blocked_by_email?).to be true
        end

        it "accepts expires_in parameter" do
          user = create(:user, email: "test@example.com")
          user.block_by_email!(expires_in: 1.hour)
          expect(user.blocked_by_email?).to be true
          expect(BlockedObject.last.expires_at.to_time).to be_within(1.minute).of(1.hour.from_now)
        end

        it "accepts by_user_id parameter" do
          user = create(:user, email: "userid@example.com")
          user.block_by_email!(by_user_id: 123)
          expect(user.blocked_by_email?).to be true
          expect(BlockedObject.last.blocked_by).to eq(123)
        end

        it "accepts both by_user_id and expires_in parameters" do
          user = create(:user, email: "both@example.com")
          user.block_by_email!(by_user_id: 456, expires_in: 2.hours)
          expect(user.blocked_by_email?).to be true

          blocked_object = BlockedObject.last
          expect(blocked_object.blocked_by).to eq(456)
          expect(blocked_object.expires_at.to_time).to be_within(1.minute).of(2.hours.from_now)
        end

        it "does nothing when email is blank" do
          user = create(:user)
          user.update_column(:email, "")
          expect { user.block_by_email! }.not_to change { BlockedObject.count }
        end

        it "does nothing when email is nil" do
          user = create(:user)
          user.update_column(:email, nil)
          expect { user.block_by_email! }.not_to change { BlockedObject.count }
        end

        it "updates cache with correct blockable_method key" do
          user = create(:user, email: "cache_key_test@example.com")

          user.block_by_email!

          # Cache should be keyed by "email" (the blockable_method)
          expect(user.blocked_by_attributes["email"]).to be_a(BlockedObject)
          expect(user.blocked_by_attributes["email"].object_value).to eq("cache_key_test@example.com")
        end

        it "immediately reflects blocked status via cache" do
          user = create(:user, email: "immediate_cache@example.com")

          user.block_by_email!

          # Should not need to query database again
          expect(user.blocked_by_email?).to be true
          expect(user.blocked_by_attributes["email"]).to be_a(BlockedObject)
        end
      end

      describe "#unblock_by_email!" do
        it "unblocks the user by their email" do
          user = create(:user, email: "blocked_test@example.com")
          user.block_by_email!
          expect(user.blocked_by_email?).to be true

          user.unblock_by_email!
          user.reload
          expect(user.blocked_by_email?).to be false
        end

        it "does nothing when email is blank" do
          user = create(:user)
          user.update_column(:email, "")
          expect { user.unblock_by_email! }.not_to raise_error
        end

        it "does nothing when email is nil" do
          user = create(:user)
          user.update_column(:email, nil)
          expect { user.unblock_by_email! }.not_to raise_error
        end

        it "clears cached blocked_by_attributes when unblocking" do
          user = create(:user, email: "cached_test@example.com")
          user.block_by_email!
          user.blocked_by_email? # Populate cache
          expect(user.blocked_by_attributes["email"]).to be_a(BlockedObject)

          user.unblock_by_email!
          expect(user.blocked_by_attributes["email"]).to be_nil
        end
      end

      describe "cache management with custom method names" do
        describe "#block_by_form_email!" do
          it "updates cache with blockable_method key, not object_type key" do
            user = create(:user, email: "cache_test@example.com")

            user.block_by_form_email!

            expect(user.blocked_by_attributes["form_email"]).to be_a(BlockedObject)
            expect(user.blocked_by_attributes["email"]).to be_nil
          end

          it "correctly identifies blocked status after blocking" do
            user = create(:user, email: "form_block_test@example.com")

            user.block_by_form_email!

            expect(user.blocked_by_form_email?).to be true
            expect(user.blocked_by_email?).to be true
          end

          it "maintains separate cache entries for email and form_email" do
            user = create(:user, email: "separate_cache@example.com")

            user.block_by_form_email!
            user.blocked_by_email? # Populate the "email" cache key

            expect(user.blocked_by_attributes["form_email"]).to be_a(BlockedObject)
            expect(user.blocked_by_attributes["email"]).to be_a(BlockedObject)
            expect(user.blocked_by_attributes.keys).to include("form_email", "email")
          end
        end

        describe "#unblock_by_form_email!" do
          it "clears cache using blockable_method key, not object_type key" do
            user = create(:user, email: "cache_unblock_test@example.com")

            user.block_by_form_email!
            expect(user.blocked_by_attributes["form_email"]).to be_a(BlockedObject)

            user.unblock_by_form_email!
            expect(user.blocked_by_attributes["form_email"]).to be_nil
          end

          it "correctly updates blocked status after unblocking" do
            user = create(:user, email: "form_unblock_test@example.com")
            user.block_by_form_email!
            expect(user.blocked_by_form_email?).to be true

            user.unblock_by_form_email!
            user.reload

            expect(user.blocked_by_form_email?).to be false
            expect(user.blocked_by_email?).to be false
          end

          it "handles mixed cache state correctly" do
            user = create(:user, email: "mixed_cache@example.com")
            user.block_by_form_email!
            user.blocked_by_email? # Populate cache entry

            expect(user.blocked_by_attributes["form_email"]).to be_a(BlockedObject)
            expect(user.blocked_by_attributes["email"]).to be_a(BlockedObject)

            user.unblock_by_form_email!

            expect(user.blocked_by_attributes["form_email"]).to be_nil
            # The "email" cache still has a stale reference - reload is needed to get fresh data
            user.reload
            expect(user.blocked_by_email?).to be false
          end
        end

        describe "cache key consistency" do
          it "uses consistent cache keys across all operations" do
            user = create(:user, email: "consistency_test@example.com")

            user.block_by_form_email!
            expect(user.blocked_by_attributes.keys).to include("form_email")

            user.blocked_by_form_email?
            expect(user.blocked_by_attributes.keys).to include("form_email")

            user.unblock_by_form_email!
            expect(user.blocked_by_attributes["form_email"]).to be_nil
          end

          it "does not pollute cache with object_type keys" do
            user = create(:user, email: "no_pollution@example.com")

            user.block_by_form_email!

            expect(user.blocked_by_attributes.keys).not_to include("email")
            expect(user.blocked_by_attributes.keys).to include("form_email")
          end
        end
      end

      describe "cache management with email_domain methods" do
        describe "#block_by_form_email_domain!" do
          it "updates cache with blockable_method key" do
            user = create(:user, email: "test@domain.com")

            user.block_by_form_email_domain!

            # Cache should be keyed by "form_email_domain", not "email_domain"
            expect(user.blocked_by_attributes["form_email_domain"]).to be_a(BlockedObject)
            expect(user.blocked_by_attributes["email_domain"]).to be_nil
          end

          it "correctly identifies blocked status" do
            user = create(:user, email: "test@blocked-domain.com")

            user.block_by_form_email_domain!

            expect(user.blocked_by_form_email_domain?).to be true
            # form_email_domain blocks the actual domain value
            expect(BlockedObject.find_by(object_value: "blocked-domain.com")).to be_present
          end

          it "maintains independent cache from email methods" do
            user = create(:user, email: "test@multi-block.com")

            user.block_by_form_email_domain!

            expect(user.blocked_by_attributes["form_email_domain"]).to be_a(BlockedObject)
            expect(user.blocked_by_attributes["form_email"]).to be_nil
          end
        end

        describe "#unblock_by_form_email_domain!" do
          it "clears cache using correct blockable_method key" do
            user = create(:user, email: "test@unblock-domain.com")
            user.block_by_form_email_domain!

            expect(user.blocked_by_attributes["form_email_domain"]).to be_a(BlockedObject)

            user.unblock_by_form_email_domain!

            expect(user.blocked_by_attributes["form_email_domain"]).to be_nil
          end

          it "correctly updates blocked status" do
            user = create(:user, email: "test@unblock-test.com")
            user.block_by_form_email_domain!
            expect(user.blocked_by_form_email_domain?).to be true

            user.unblock_by_form_email_domain!
            user.reload

            expect(user.blocked_by_form_email_domain?).to be false
          end
        end
      end
    end
  end

  describe "blockable attribute introspection" do
    describe ".blockable_attributes" do
      it "returns an array of attribute configurations" do
        expect(User.blockable_attributes).to be_an(Array)
        expect(User.blockable_attributes).not_to be_empty
      end

      it "includes configuration for each attr_blockable declaration" do
        # User has: attr_blockable :email, :form_email (object_type: :email),
        #           :email_domain, :form_email_domain (object_type: :email_domain),
        #           :account_created_ip (object_type: :ip_address)
        expect(User.blockable_attributes).to include(
          { object_type: :email, blockable_method: :email }
        )
        expect(User.blockable_attributes).to include(
          { object_type: :email, blockable_method: :form_email }
        )
        expect(User.blockable_attributes).to include(
          { object_type: :email_domain, blockable_method: :email_domain }
        )
        expect(User.blockable_attributes).to include(
          { object_type: :email_domain, blockable_method: :form_email_domain }
        )
        expect(User.blockable_attributes).to include(
          { object_type: :ip_address, blockable_method: :account_created_ip }
        )
      end

      it "tracks custom attribute mappings correctly" do
        # form_email uses :email as the object_type
        form_email_config = User.blockable_attributes.find do |attr|
          attr[:blockable_method] == :form_email
        end

        expect(form_email_config).to eq({ object_type: :email, blockable_method: :form_email })
      end

      it "returns unique entries per model class" do
        # Create a custom test model with its own blockable attributes
        test_model_class = Class.new(ApplicationRecord) do
          self.table_name = "users"
          include AttributeBlockable
          attr_blockable :test_attribute

          def self.name
            "TestIntrospectionModel"
          end
        end

        expect(test_model_class.blockable_attributes).to include(
          { object_type: :test_attribute, blockable_method: :test_attribute }
        )
        # User's attributes shouldn't include the test model's attributes
        expect(User.blockable_attributes).not_to include(
          { object_type: :test_attribute, blockable_method: :test_attribute }
        )
      end
    end

    describe ".blockable_method_names" do
      it "returns an array of blockable method names" do
        expect(User.blockable_method_names).to be_an(Array)
        expect(User.blockable_method_names).to all(be_a(Symbol))
      end

      it "includes all blockable method names defined on the model" do
        expect(User.blockable_method_names).to include(:email)
        expect(User.blockable_method_names).to include(:form_email)
        expect(User.blockable_method_names).to include(:email_domain)
        expect(User.blockable_method_names).to include(:form_email_domain)
        expect(User.blockable_method_names).to include(:account_created_ip)
      end

      it "returns only method names without object_type info" do
        expect(User.blockable_method_names).to eq([:email, :form_email, :email_domain, :form_email_domain, :account_created_ip])
      end
    end

    describe ".with_all_blocked_attributes" do
      let!(:users) { 3.times.map { |i| create(:user, email: "unblocked#{i}@example.com") } }
      let!(:blocked_user) { create(:user, email: blocked_email) }

      it "returns an ActiveRecord::Relation" do
        result = User.with_all_blocked_attributes
        expect(result).to be_a(ActiveRecord::Relation)
      end

      it "preloads all blockable attributes" do
        users_with_preload = User.with_all_blocked_attributes.to_a

        users_with_preload.each do |user|
          # Check that the cache has been populated for all blockable methods
          if user.email == blocked_email
            expect(user.blocked_by_attributes["email"]).to be_a(BlockedObject)
          else
            expect(user.blocked_by_attributes["email"]).to be_nil
          end

          # The cache should have entries for all blockable methods
          expect(user.blocked_by_attributes).to have_key("form_email")
          expect(user.blocked_by_attributes).to have_key("email_domain")
          expect(user.blocked_by_attributes).to have_key("form_email_domain")
          expect(user.blocked_by_attributes).to have_key("account_created_ip")
        end
      end

      it "maintains chainability" do
        result = User.with_all_blocked_attributes.where(id: users.map(&:id))
        expect(result).to be_a(ActiveRecord::Relation)
        expect(result.to_a.size).to eq(3)
      end

      it "correctly identifies blocked users" do
        all_users = User.with_all_blocked_attributes
        blocked_users = all_users.select(&:blocked_by_email?)
        unblocked_users = all_users.reject(&:blocked_by_email?)

        expect(blocked_users.map(&:email)).to include(blocked_email)
        expect(unblocked_users.map(&:email)).not_to include(blocked_email)
      end
    end
  end

  describe ".with_blocked_attributes_for" do
    let!(:users) { 3.times.map { |i| create(:user, email: "unblocked#{i}@example.com") } }
    let!(:blocked_user) { create(:user, email: blocked_email) }

    it "returns an ActiveRecord::Relation" do
      result = User.with_blocked_attributes_for(:email)
      expect(result).to be_a(ActiveRecord::Relation)
    end

    it "maintains chainability" do
      result = User.with_blocked_attributes_for(:email).where(id: users.map(&:id))
      expect(result).to be_a(ActiveRecord::Relation)
      expect(result.to_a.size).to eq(3)
    end

    it "can chain additional scopes" do
      result = User.with_blocked_attributes_for(:email)
                   .where(email: blocked_email)
                   .limit(1)

      expect(result).to be_a(ActiveRecord::Relation)
      expect(result.first).to eq(blocked_user)
    end

    it "accepts multiple method names" do
      result = User.with_blocked_attributes_for(:email, :form_email)
      expect(result).to be_a(ActiveRecord::Relation)
    end

    describe "bulk loading blocked attributes" do
      it "correctly identifies blocked and unblocked records" do
        all_users = User.with_blocked_attributes_for(:email)
        blocked_users = all_users.select(&:blocked_by_email?)
        unblocked_users = all_users.reject(&:blocked_by_email?)

        expect(blocked_users.map(&:email)).to include(blocked_email)
        expect(unblocked_users.map(&:email)).not_to include(blocked_email)
      end

      it "populates blocked_by_attributes for all records" do
        users_with_preload = User.with_blocked_attributes_for(:email).to_a

        users_with_preload.each do |user|
          if user.email == blocked_email
            expect(user.blocked_by_attributes["email"]).to be_a(BlockedObject)
          else
            expect(user.blocked_by_attributes["email"]).to be_nil
          end
        end
      end

      it "handles mixed blocked and unblocked records" do
        mixed_blocked_email = "mixed_blocked@example.com"
        mixed_emails = [mixed_blocked_email, "unique_unblocked@example.com", "another@example.com"]

        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], mixed_blocked_email, 1)
        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], "another@example.com", 1)

        mixed_users = mixed_emails.map { |email| create(:user, email:) }

        result = User.where(id: mixed_users.map(&:id)).with_blocked_attributes_for(:email)
        blocked_users = result.select(&:blocked_by_email?)

        expect(blocked_users.map(&:email)).to eq([mixed_blocked_email, "another@example.com"])
      end

      it "works with custom method names that map to different object types" do
        custom_blocked_email = "custom_blocked@example.com"
        custom_unblocked_email = "custom_unblocked@example.com"

        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], custom_blocked_email, 1)

        test_users = [
          create(:user, email: custom_blocked_email),
          create(:user, email: custom_unblocked_email)
        ]

        result_users = User.where(id: test_users.map(&:id)).with_blocked_attributes_for(:form_email)
        blocked_users = result_users.select(&:blocked_by_form_email?)
        unblocked_users = result_users.reject(&:blocked_by_form_email?)

        expect(blocked_users.map(&:email)).to eq([custom_blocked_email])
        expect(unblocked_users.map(&:email)).to eq([custom_unblocked_email])

        result_users.each do |user|
          if user.email == custom_blocked_email
            expect(user.blocked_by_attributes["form_email"]).to be_a(BlockedObject)
          else
            expect(user.blocked_by_attributes["form_email"]).to be_nil
          end
        end
      end

      it "uses the correct BlockedObject scope for custom method names" do
        custom_blocked_email_1 = "scope_test1@example.com"
        custom_blocked_email_2 = "scope_test2@example.com"
        custom_blocked_email_domain = "example.com"

        test_users = [
          create(:user, email: custom_blocked_email_1),
          create(:user, email: custom_blocked_email_2)
        ]

        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], custom_blocked_email_1, 1)
        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], custom_blocked_email_2, 1)
        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email_domain], custom_blocked_email_domain, 1)

        allow(BlockedObject).to receive(:find_active_objects).and_call_original

        User.where(id: test_users.map(&:id)).with_blocked_attributes_for(:form_email, :email_domain).to_a

        expect(BlockedObject).to have_received(:find_active_objects).with([custom_blocked_email_1, custom_blocked_email_2]).once
        expect(BlockedObject).to have_received(:find_active_objects).with([custom_blocked_email_domain]).once
      end
    end

    describe "performance" do
      it "makes only one MongoDB query when loading blocked attributes for multiple blocked users" do
        perf_users = []
        5.times do |i|
          email = "blocked_perfuser#{i}@example.com"
          perf_users << create(:user, email:)
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], email, 1)
        end

        allow(BlockedObject).to receive(:find_active_objects).and_call_original

        result = User.where(id: perf_users.map(&:id)).with_blocked_attributes_for(:email)

        expect(result.size).to eq(5)
        result.each do |user|
          expect(user.blocked_by_attributes["email"]).to be_a(BlockedObject)
          expect(user.blocked_by_email?).to be true
        end

        expect(BlockedObject).to have_received(:find_active_objects).once
      end

      it "handles empty result sets gracefully" do
        result = User.where(id: -1).with_blocked_attributes_for(:email)
        expect(result).to be_empty
      end

      it "handles records with nil values" do
        user_with_nil_email = create(:user)
        user_with_nil_email.update_column(:email, nil)
        result = User.with_blocked_attributes_for(:email).find_by(id: user_with_nil_email.id)

        expect(result.blocked_by_email?).to be false
        expect(result.blocked_by_email_object).to be_nil
      end

      it "only preloads active blocks, ignoring unblocked records" do
        # Create users with active and unblocked records
        active_email = "preload_active_#{SecureRandom.hex(4)}@example.com"
        unblocked_email = "preload_unblocked_#{SecureRandom.hex(4)}@example.com"
        reblocked_email = "preload_reblocked_#{SecureRandom.hex(4)}@example.com"

        user_active = create(:user, email: active_email)
        user_unblocked = create(:user, email: unblocked_email)
        user_reblocked = create(:user, email: reblocked_email)

        # Create active block
        active_record = BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], active_email, 1)

        # Create unblocked record (blocked_at is nil)
        unblocked_record = BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], unblocked_email, 1)
        unblocked_record.unblock!

        # Create unblocked record, then block the same email again
        # find_or_initialize_by ensures it's the same record, just re-blocked
        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], reblocked_email, 1)
        BlockedObject.send(:email).find_by(object_value: reblocked_email).unblock!
        reblocked_record = BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], reblocked_email, 1)

        # Preload blocked attributes
        users = User.where(id: [user_active.id, user_unblocked.id, user_reblocked.id])
                    .with_blocked_attributes_for(:email)
                    .to_a

        # Verify results
        active_user = users.find { |u| u.id == user_active.id }
        unblocked_user = users.find { |u| u.id == user_unblocked.id }
        reblocked_user = users.find { |u| u.id == user_reblocked.id }

        expect(active_user.blocked_by_email?).to be true
        expect(active_user.blocked_by_email_object.id).to eq(active_record.id)

        expect(unblocked_user.blocked_by_email?).to be false
        expect(unblocked_user.blocked_by_email_object).to be_nil

        expect(reblocked_user.blocked_by_email?).to be true
        expect(reblocked_user.blocked_by_email_object.id).to eq(reblocked_record.id)
        expect(reblocked_user.blocked_by_email_object.blocked_at).not_to be_nil
      end
    end
  end

  describe "different blocked object types" do
    let(:blocked_ip) { "192.168.1.100" }
    let(:unblocked_ip) { "192.168.1.200" }

    before do
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], blocked_ip, 1, expires_in: 1.hour)
    end

    let(:test_model_class) do
      Class.new(ApplicationRecord) do
        self.table_name = "users"
        include AttributeBlockable

        attr_blockable :current_sign_in_ip, object_type: :ip_address

        def self.name
          "TestModel"
        end
      end
    end

    it "works with different BLOCKED_OBJECT_TYPES" do
      model = test_model_class.new(current_sign_in_ip: blocked_ip)
      expect(model.blocked_by_current_sign_in_ip?).to be true

      model2 = test_model_class.new(current_sign_in_ip: unblocked_ip)
      expect(model2.blocked_by_current_sign_in_ip?).to be false
    end
  end

  describe "edge cases and error handling" do
    it "raises an error for missing BLOCKED_OBJECT_TYPES" do
      user = create(:user, username: "testuser")

      expect do
        user.blocked_at_by_method(:username)
      end.to raise_error(NoMethodError)
    end

    it "handles expired blocked objects" do
      expired_email = "expired@example.com"

      BlockedObject.create!(
        object_type: BLOCKED_OBJECT_TYPES[:email],
        object_value: expired_email,
        blocked_at: 1.hour.ago,
        expires_at: 30.minutes.ago,
        blocked_by: 1
      )

      user = create(:user, email: expired_email)

      # Expired blocks are treated the same as unblocked - no object returned
      expect(user.blocked_by_email?).to be false
      expect(user.blocked_by_email_object).to be_nil
    end

    it "handles blocked objects without expires_at" do
      permanent_blocked_email = "permanent@example.com"

      BlockedObject.create!(
        object_type: BLOCKED_OBJECT_TYPES[:email],
        object_value: permanent_blocked_email,
        blocked_at: 1.hour.ago,
        expires_at: nil,
        blocked_by: 1
      )

      user = create(:user, email: permanent_blocked_email)
      expect(user.blocked_by_email?).to be true
      expect(user.blocked_by_email_object&.expires_at).to be_nil
    end
  end

  describe "integration with blocked_by_attributes" do
    it "initializes with empty hash" do
      user = User.new
      expect(user.blocked_by_attributes).to eq({})
    end

    it "persists cached blocked attributes" do
      user = create(:user, email: blocked_email)
      expect(user.blocked_by_attributes["email"]).to be_nil
      user.blocked_by_email? # Populate cache
      expect(user.blocked_by_attributes["email"]).to be_a(BlockedObject)
      user.reload # Clear cache
      expect(user.blocked_by_attributes["email"]).to be_nil
      expect(user.blocked_by_email?).to be true
    end
  end

  describe "#blocked_objects_for_values" do
    let(:user) { create(:user, email: "test@example.com") }

    it "returns blocked objects for given values" do
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], "blocked1@example.com", 1)
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], "blocked2@example.com", 1)

      values = ["blocked1@example.com", "blocked2@example.com", "unblocked@example.com"]
      blocked_objects = user.blocked_objects_for_values(:email, values)

      expect(blocked_objects.count).to eq(2)
      expect(blocked_objects.map(&:object_value)).to contain_exactly("blocked1@example.com", "blocked2@example.com")
    end

    it "returns empty collection when no values are blocked" do
      values = ["unblocked1@example.com", "unblocked2@example.com"]
      blocked_objects = user.blocked_objects_for_values(:email, values)
      expect(blocked_objects).to be_empty
    end

    it "works with different object types" do
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], "192.168.1.1", 1, expires_in: 1.hour)

      values = ["192.168.1.1", "192.168.1.2"]
      blocked_objects = user.blocked_objects_for_values(:ip_address, values)

      expect(blocked_objects.count).to eq(1)
      expect(blocked_objects.first.object_value).to eq("192.168.1.1")
      expect(blocked_objects.first.ip_address?).to be true
    end

    it "handles empty values array" do
      blocked_objects = user.blocked_objects_for_values(:email, [])
      expect(blocked_objects).to be_empty
    end
  end
end
