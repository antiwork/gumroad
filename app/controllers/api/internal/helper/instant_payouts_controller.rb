# frozen_string_literal: true

class Api::Internal::Helper::InstantPayoutsController < Api::Internal::Helper::BaseController
  include CurrencyHelper

  before_action :fetch_user

  INSTANT_PAYOUT_BALANCE_OPENAPI = {
    summary: "Get instant payout balance",
    description: "Get the amount available for instant payout for a user",
    parameters: [
      {
        name: "email",
        in: "query",
        required: true,
        schema: {
          type: "string"
        },
        description: "Email address of the seller"
      }
    ],
    security: [{ bearer: [] }],
    responses: {
      '200': {
        description: "Successfully retrieved instant payout balance",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: true },
                balance: { type: "string" }
              },
              required: ["success", "balance"]
            }
          }
        }
      },
      '404': {
        description: "User not found",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                message: { type: "string" }
              }
            }
          }
        }
      }
    }
  }.freeze

  def index
    balance_cents = @user.instantly_payable_unpaid_balance_cents
    render json: {
      success: true,
      balance: formatted_dollar_amount(balance_cents)
    }
  end

  CREATE_INSTANT_PAYOUT_OPENAPI = {
    summary: "Create new instant payout",
    description: "Create a new instant payout for a user",
    requestBody: {
      required: true,
      content: {
        'application/json': {
          schema: {
            type: "object",
            properties: {
              email: { type: "string", description: "Email address of the seller" }
            },
            required: ["email"]
          }
        }
      }
    },
    security: [{ bearer: [] }],
    responses: {
      '200': {
        description: "Successfully created instant payout",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: true }
              },
              required: ["success"]
            }
          }
        }
      },
      '404': {
        description: "User not found",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                message: { type: "string" }
              }
            }
          }
        }
      },
      '422': {
        description: "Unable to create instant payout",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                message: { type: "string" }
              }
            }
          }
        }
      }
    }
  }.freeze

  def create
    result = InstantPayoutsService.new(@user).perform

    if result[:success]
      render json: { success: true }
    else
      render json: { success: false, message: result[:error] }, status: :unprocessable_entity
    end
  end

  private
    def fetch_user
      if params[:email].blank?
        render json: { success: false, message: "Email is required" }, status: :unprocessable_entity
        return
      end

      @user = User.alive.by_email(params[:email]).first
      render json: { success: false, message: "User not found" }, status: :not_found unless @user
    end
end
