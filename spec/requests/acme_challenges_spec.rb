# frozen_string_literal: true

require "spec_helper"

describe "ACME Challenges", type: :request do
  let(:token) { "a" * 43 }
  let(:challenge_content) { "challenge-response-content" }

  describe "GET /.well-known/acme-challenge/:token" do
    context "when request is from a user custom domain" do
      let(:user) { create(:user) }
      let!(:custom_domain) { create(:custom_domain, user:) }

      before do
        $redis.set(RedisKey.acme_challenge(token), challenge_content)
      end

      after do
        $redis.del(RedisKey.acme_challenge(token))
      end

      it "returns the challenge content" do
        get "/.well-known/acme-challenge/#{token}", headers: { "HOST" => custom_domain.domain }

        expect(response.status).to eq(200)
        expect(response.body).to eq(challenge_content)
      end
    end

    context "when request is from a product custom domain" do
      let(:product) { create(:product) }
      let!(:custom_domain) { create(:custom_domain, user: nil, product:) }

      before do
        $redis.set(RedisKey.acme_challenge(token), challenge_content)
      end

      after do
        $redis.del(RedisKey.acme_challenge(token))
      end

      it "returns the challenge content" do
        get "/.well-known/acme-challenge/#{token}", headers: { "HOST" => custom_domain.domain }

        expect(response.status).to eq(200)
        expect(response.body).to eq(challenge_content)
      end
    end

    context "when request is from default Gumroad domain" do
      it "does not route to the controller" do
        get "/.well-known/acme-challenge/#{token}", headers: { "HOST" => DOMAIN }

        expect(response.status).to eq(404)
      end
    end
  end
end
