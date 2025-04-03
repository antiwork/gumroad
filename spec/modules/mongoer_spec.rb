# frozen_string_literal: true

require "spec_helper"

describe "Mongoer" do
  it "does not throw exception if invalid character used" do
    Mongoer.safe_write("Link", "email" => "f@flick.com", "email for google.com" => "sid@sid.com")
    result = MONGO_DATABASE["Link"].find("email" => "f@flick.com").limit(1).first
    expect(result["email for googleU+FFOEcom"]).to_not be(nil)
  end

  describe ".async_update" do
    it "enqueues a Sidekiq job" do
      Mongoer.async_update("a", "b", { "c" => "d" })

      expect(UpdateInMongoWorker).to have_enqueued_sidekiq_job("a", "b", { "c" => "d" })
    end
  end
end
