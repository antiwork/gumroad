# frozen_string_literal: true

require "test_helper"

class AcmeChallengesControllerTest < ActionController::TestCase
  self.described_class = AcmeChallengesController
  tests AcmeChallengesController



  context_ AcmeChallengesController do
  context_ "GET 'show'" do
      let(:token) { "a" * 43 }
      let(:challenge_content) { "challenge-response-content" }

  context_ "when challenge exists in Redis" do
        before do
          $redis.set(RedisKey.acme_challenge(token), challenge_content)
        end

        after do
          $redis.del(RedisKey.acme_challenge(token))
        end

  test "returns the challenge content" do
          get :show, params: { token: token }

          expect(response.status).to eq(200)
          expect(response.body).to eq(challenge_content)
        end
      end

  context_ "when challenge does not exist in Redis" do
  test "returns not found" do
          get :show, params: { token: token }

          expect(response.status).to eq(404)
        end
      end

  context_ "when token is too long" do
  test "returns bad request" do
          get :show, params: { token: "a" * 65 }

          expect(response.status).to eq(400)
        end
      end

  context_ "when token contains invalid characters" do
  test "returns bad request" do
          get :show, params: { token: "invalid!token@chars" }

          expect(response.status).to eq(400)
        end
      end
    end
  end
end
