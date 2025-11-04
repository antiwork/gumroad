# frozen_string_literal: true

class Api::Internal::Helper::PayoutsController < Api::Internal::Helper::BaseController
  before_action :authorize_helper_token!
  before_action :fetch_user

  PAYOUT_INDEX_OPENAPI = {
    summary: "Get payout information",
    description: "Get last 5 payouts details, next payout date and balance for next payout date",
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
        description: "Successfully retrieved payout information",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: true },
                last_payouts: {
                  type: "array",
                  items: {
                    type: "object",
                    properties: {
                      external_id: { type: "string" },
                      amount_cents: { type: "integer" },
                      currency: { type: "string" },
                      state: { type: "string" },
                      created_at: { type: "string", format: "date-time" },
                      processor: { type: "string" },
                      bank_account_visual: { type: "string" },
                      paypal_email: { type: "string" }
                    },
                    required: ["external_id", "amount_cents", "currency", "state", "created_at", "processor"]
                  }
                },
                next_payout_date: { type: "string", format: "date" },
                balance_for_next_payout: { type: "string" },
                payout_note: { type: ["string", "null"] }
              },
              required: ["success", "last_payouts", "next_payout_date", "balance_for_next_payout", "payout_note"]
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
    payouts = @user.payments.order(created_at: :desc).limit(5).map do |payment|
      {
        external_id: payment.external_id,
        amount_cents: payment.amount_cents,
        currency: payment.currency,
        state: payment.state,
        created_at: payment.created_at,
        processor: payment.processor,
        bank_account_visual: payment.bank_account&.account_number_visual,
        paypal_email: payment.payment_address
      }
    end

    next_payout_date = @user.next_payout_date
    balance_for_next_payout = @user.formatted_balance_for_next_payout_date
    payout_note = @user.comments.with_type_payout_note.where(author_id: GUMROAD_ADMIN_ID).last&.content

    render json: { success: true, last_payouts: payouts, next_payout_date:, balance_for_next_payout:, payout_note: }
  end

  CREATE_PAYOUT_OPENAPI = {
    summary: "Create new payout",
    description: "Create a new payout for a user, checking if eligible and after the last successful payout was more than a week ago",
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
        description: "Successfully created payout",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: true },
                message: { type: "string" },
                payout: {
                  type: "object",
                  properties: {
                    external_id: { type: "string" },
                    amount_cents: { type: "integer" },
                    currency: { type: "string" },
                    state: { type: "string" },
                    created_at: { type: "string", format: "date-time" },
                    processor: { type: "string" },
                    bank_account_visual: { type: "string" },
                    paypal_email: { type: "string" }
                  },
                  required: ["external_id", "amount_cents", "currency", "state", "created_at", "processor"]
                }
              },
              required: ["success", "message", "payout"]
            }
          }
        }
      },
      '422': {
        description: "Unable to create payout",
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
    payout_date = User::PayoutSchedule.manual_payout_end_date
    payout_processor_type = if @user.active_bank_account.present?
      PayoutProcessorType::STRIPE
    elsif @user.paypal_payout_email.present?
      PayoutProcessorType::PAYPAL
    else
      nil
    end

    if payout_processor_type.blank?
      render json: {
        success: false,
        message: "Cannot create payout. Payout method not set up."
      }, status: :unprocessable_entity
      return
    end

    last_successful_payout = @user.payments.completed.order(created_at: :desc).first
    if last_successful_payout && last_successful_payout.created_at > 1.week.ago
      render json: {
        success: false,
        message: "Cannot create payout. Last successful payout was less than a week ago."
      }, status: :unprocessable_entity
      return
    end

    if Payouts.is_user_payable(@user, payout_date, processor_type: payout_processor_type, add_comment: true)
      payments = PayoutUsersService.new(date_string: payout_date,
                                        processor_type: payout_processor_type,
                                        user_ids: [@user.id]).process
      payment = payments.first

      if payment&.persisted? && (payment.processing? || payment.completed?)
        render json: {
          success: true,
          message: "Successfully created payout",
          payout: {
            external_id: payment.external_id,
            amount_cents: payment.amount_cents,
            currency: payment.currency,
            state: payment.state,
            created_at: payment.created_at,
            processor: payment.processor,
            bank_account_visual: payment.bank_account&.account_number_visual,
            paypal_email: payment.payment_address,
          }
        }
      else
        error_message = payment&.errors&.full_messages&.to_sentence || "Unable to create payout"
        render json: { success: false, message: error_message }, status: :unprocessable_entity
      end
    else
      payout_note = @user.reload.comments.with_type_payout_note.where(author_id: GUMROAD_ADMIN_ID).last&.content
      payout_note&.gsub!("via #{payout_processor_type.capitalize} on #{payout_date.to_fs(:formatted_date_full_month)} ", "")
      message = "User is not eligible for payout."
      message += " #{payout_note}" if payout_note.present?
      render json: { success: false, message: }, status: :unprocessable_entity
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
