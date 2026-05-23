# frozen_string_literal: true

require "test_helper"

class RequestsAcmeChallengesTest < ActionDispatch::IntegrationTest



  context_ "ACME Challenges", type: :request do
    let(:token) { "a" * 43 }
    let(:challenge_content) { "challenge-response-content" }

  context_ "GET /.well-known/acme-challenge/:token" do
  context_ "when request is from a user custom domain" do
        let(:user) { create(:user) }
        let!(:custom_domain) { create(:custom_domain, user:) }

        before do
          $redis.set(RedisKey.acme_challenge(token), challenge_content)
        end

        after do
          $redis.del(RedisKey.acme_challenge(token))
        end

  test "returns the challenge content" do
          get "/.well-known/acme-challenge/#{token}", headers: { "HOST" => custom_domain.domain }

          expect(response.status).to eq(200)
          expect(response.body).to eq(challenge_content)
        end
      end

  context_ "when request is from a product custom domain" do
        let(:product) { create(:product) }
        let!(:custom_domain) { create(:custom_domain, user: nil, product:) }

        before do
          $redis.set(RedisKey.acme_challenge(token), challenge_content)
        end

        after do
          $redis.del(RedisKey.acme_challenge(token))
        end

  test "returns the challenge content" do
          get "/.well-known/acme-challenge/#{token}", headers: { "HOST" => custom_domain.domain }

          expect(response.status).to eq(200)
          expect(response.body).to eq(challenge_content)
        end
      end

  context_ "when request is from default Gumroad domain" do
  test "does not route to the controller" do
          get "/.well-known/acme-challenge/#{token}", headers: { "HOST" => DOMAIN }

          expect(response.status).to eq(404)
        end
      end
    end
  end
end
