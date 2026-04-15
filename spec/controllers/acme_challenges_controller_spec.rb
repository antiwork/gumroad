# frozen_string_literal: true

require "spec_helper"

describe AcmeChallengesController do
  describe "GET 'show'" do
    let(:token) { "a" * 43 }
    let(:challenge_content) { "challenge-response-content" }

    context "when challenge exists in Redis" do
      before do
        $redis.set(RedisKey.acme_challenge(token), challenge_content)
      end

      after do
        $redis.del(RedisKey.acme_challenge(token))
      end

      it "returns the challenge content" do
        get :show, params: { token: token }

        expect(response.status).to eq(200)
        expect(response.body).to eq(challenge_content)
      end
    end

    context "when challenge does not exist in Redis" do
      it "returns not found" do
        get :show, params: { token: token }

        expect(response.status).to eq(404)
      end
    end

    context "when token is too long" do
      it "returns bad request" do
        get :show, params: { token: "a" * 65 }

        expect(response.status).to eq(400)
      end
    end

    context "when token contains invalid characters" do
      it "returns bad request" do
        get :show, params: { token: "invalid!token@chars" }

        expect(response.status).to eq(400)
      end
    end
  end
end
