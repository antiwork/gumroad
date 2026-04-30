# frozen_string_literal: true

require "spec_helper"

describe User::SocialGoogle do
  before(:all) do
    @data = JSON.parse(File.open("#{Rails.root}/spec/support/fixtures/google_omniauth.json").read)
  end

  describe ".find_or_create_for_google_oauth2" do
    before do
      @data_copy1 = @data.deep_dup
      @data_copy1["uid"] = "12345"
      @data_copy1["info"]["email"] = "paulius@example.com"
      @data_copy1["extra"]["raw_info"]["email"] = "paulius@example.com"

      @data_copy2 = @data.deep_dup
      @data_copy2["uid"] = "111111"
      @data_copy2["info"]["email"] = "spongebob@example.com"
      @data_copy2["extra"]["raw_info"]["email"] = "spongebob@example.com"
    end

    it "creates a new user if one does not exist with the corresponding google uid or email" do
      User.find_or_create_for_google_oauth2(@data)

      expect(User.find_by(email: @data["info"]["email"])).to_not eq(nil)
      expect(User.find_by(google_uid: @data["uid"])).to_not eq(nil)
    end

    it "finds a user using google's uid payload" do
      created_user = create(:user, google_uid: @data_copy1["uid"])
      found_user = User.find_or_create_for_google_oauth2(@data_copy1)

      expect(found_user.id).to eq(created_user.id)
      expect(created_user.reload.email).to eq(found_user.email)
      expect(created_user.reload.email).to eq(@data_copy1["info"]["email"])
    end

    it "finds a user using email when google's uid is missing and fills in uid" do
      created_user = create(:user, email: @data_copy2["info"]["email"])
      found_user = User.find_or_create_for_google_oauth2(@data_copy2)

      expect(created_user.google_uid).to eq(nil)
      expect(created_user.reload.google_uid).to eq(found_user.google_uid)
      expect(created_user.reload.google_uid).to eq(@data_copy2["uid"])
    end

    it "creates user with sanitized name when name contains colons" do
      @data_with_colon = @data.deep_dup
      @data_with_colon["uid"] = "unique_colon_test_uid"
      @data_with_colon["info"]["name"] = "Test: User"

      user = User.find_or_create_for_google_oauth2(@data_with_colon)

      expect(user).to be_persisted
      expect(user).to be_valid
      expect(user.name).to eq("Test User")
    end

    it "retries after a deadlock and returns the created user" do
      deadlock_data = @data.deep_dup
      deadlock_data["uid"] = "google-deadlock-retry-uid"
      deadlock_data["info"]["email"] = "google-deadlock-retry@example.com"
      deadlock_data["extra"]["raw_info"]["email"] = "google-deadlock-retry@example.com"

      allow_any_instance_of(User).to receive(:google_picture_url).and_return(nil)

      save_attempts = 0
      allow_any_instance_of(User).to receive(:save!).and_wrap_original do |original, *args|
        save_attempts += 1
        raise ActiveRecord::Deadlocked, "Deadlock found when trying to get lock" if save_attempts == 1

        original.call(*args)
      end

      result = User.find_or_create_for_google_oauth2(deadlock_data)

      expect(result).to be_persisted
      expect(result).to be_valid
      expect(result.google_uid).to eq(deadlock_data["uid"])
      expect(save_attempts).to be >= 2
    end

    it "returns nil and notifies after exhausting deadlock retries" do
      deadlock_data = @data.deep_dup
      deadlock_data["uid"] = "google-deadlock-failure-uid"
      deadlock_data["info"]["email"] = "google-deadlock-failure@example.com"
      deadlock_data["extra"]["raw_info"]["email"] = "google-deadlock-failure@example.com"

      allow_any_instance_of(User).to receive(:google_picture_url).and_return(nil)
      allow_any_instance_of(User).to receive(:save!).and_raise(ActiveRecord::Deadlocked, "Deadlock found when trying to get lock")
      expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::Deadlocked))

      result = User.find_or_create_for_google_oauth2(deadlock_data)

      expect(result).to be_nil
    end

    it "retries after a lock wait timeout and returns the created user" do
      lock_timeout_data = @data.deep_dup
      lock_timeout_data["uid"] = "google-lock-timeout-retry-uid"
      lock_timeout_data["info"]["email"] = "google-lock-timeout-retry@example.com"
      lock_timeout_data["extra"]["raw_info"]["email"] = "google-lock-timeout-retry@example.com"

      allow_any_instance_of(User).to receive(:google_picture_url).and_return(nil)

      save_attempts = 0
      allow_any_instance_of(User).to receive(:save!).and_wrap_original do |original, *args|
        save_attempts += 1
        raise ActiveRecord::LockWaitTimeout, "Lock wait timeout exceeded" if save_attempts == 1

        original.call(*args)
      end

      result = User.find_or_create_for_google_oauth2(lock_timeout_data)

      expect(result).to be_persisted
      expect(result).to be_valid
      expect(result.google_uid).to eq(lock_timeout_data["uid"])
      expect(save_attempts).to be >= 2
    end

    it "returns nil and notifies after exhausting lock wait timeout retries" do
      lock_timeout_data = @data.deep_dup
      lock_timeout_data["uid"] = "google-lock-timeout-failure-uid"
      lock_timeout_data["info"]["email"] = "google-lock-timeout-failure@example.com"
      lock_timeout_data["extra"]["raw_info"]["email"] = "google-lock-timeout-failure@example.com"

      allow_any_instance_of(User).to receive(:google_picture_url).and_return(nil)
      allow_any_instance_of(User).to receive(:save!).and_raise(ActiveRecord::LockWaitTimeout, "Lock wait timeout exceeded")
      expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::LockWaitTimeout))

      result = User.find_or_create_for_google_oauth2(lock_timeout_data)

      expect(result).to be_nil
    end
  end

  describe ".google_picture_url", :vcr do
    before do
      @user = create(:user, google_uid: @data["uid"])
    end

    it "stores the user's profile picture from Google to S3 and returns the URL for the saved file" do
      google_picture_url = @user.google_picture_url(@data)

      expect(google_picture_url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{@user.avatar_variant.key}")

      picture_response = HTTParty.get(google_picture_url)
      expect(picture_response.content_type).to eq("image/jpeg")
      expect(picture_response.success?).to eq(true)
    end

    it "returns nil for unsupported avatar content types" do
      allow(URI).to receive(:open).and_yield(double(content_type: "image/webp", read: ""))

      result = @user.google_picture_url(@data)

      expect(result).to be_nil
    end

    it "returns nil when avatar file size exceeds maximum" do
      large_content = "x" * (User::Validations::MAXIMUM_AVATAR_FILE_SIZE + 1)

      allow(URI).to receive(:open).and_yield(double(content_type: "image/jpeg", read: large_content))

      result = @user.google_picture_url(@data)

      expect(result).to be_nil
    end

    it "passes open_timeout and read_timeout to URI.open" do
      expect(URI).to receive(:open).with(anything, hash_including(open_timeout: 5, read_timeout: 5)).and_yield(double(content_type: "image/jpeg", read: "image data"))

      @user.google_picture_url(@data)
    end

    it "returns nil when the remote server times out" do
      allow(URI).to receive(:open).and_raise(Net::OpenTimeout)

      result = @user.google_picture_url(@data)

      expect(result).to be_nil
    end

    it "returns nil when reading from the remote server times out" do
      allow(URI).to receive(:open).and_raise(Net::ReadTimeout)

      result = @user.google_picture_url(@data)

      expect(result).to be_nil
    end
  end

  describe ".query_google" do
    describe "email change" do
      it "sets email if the email coming from google is different" do
        @user = create(:user, email: "spongebob@example.com")

        expect { User.query_google(@user, @data) }.to change { @user.reload.email }.from("spongebob@example.com").to(@data["info"]["email"])
      end

      context "when the email already exists in a different case" do
        before do
          @user = create(:user, email: @data["info"]["email"].upcase)
        end

        it "doesn't update email" do
          expect { User.query_google(@user, @data) }.not_to change { @user.reload.email }
        end

        it "doesn't raise error" do
          expect { User.query_google(@user, @data) }.not_to raise_error(ActiveRecord::RecordInvalid)
        end
      end
    end

    describe "already has name" do
      it "does not set a name if one already exists" do
        @user = create(:user, name: "Spongebob")
        expect { User.query_google(@user, @data) }.to_not change { @user.reload.name }
      end
    end

    describe "no existing information" do
      before do
        @user = create(:user)
      end

      it "sets the google uid if one does not exist upon creation" do
        expect { User.query_google(@user, @data) }.to change { @user.reload.google_uid }.from(nil).to(@data["uid"])
      end

      it "sets the name if one does not exist upon creation" do
        expect { User.query_google(@user, @data) }.to change { @user.reload.name }.from(nil).to(@data["info"]["name"])
      end
    end
  end
end
