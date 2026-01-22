# frozen_string_literal: true

class Api::Internal::Helper::OpenapiController < Api::Internal::Helper::BaseController
  def index
    render json: {
      openapi: "3.1.0",
      info: {
        title: "Helper Tools API",
        description: "API for Gumroad's Helper Tools",
        version: "v1",
      },
      servers: [
        {
          url: "https://#{API_DOMAIN}/internal/helper",
          description: "Production",
        },
      ],
      components: {
        securitySchemes: {
          bearer: {
            type: :http,
            scheme: "bearer",
          },
        },
      },
      paths: {
        "/users/create_appeal": {
          post: Api::Internal::Helper::UsersController::CREATE_USER_APPEAL_OPENAPI,
        },
        "/users/send_reset_password_instructions": {
          post: Api::Internal::Helper::UsersController::SEND_RESET_PASSWORD_INSTRUCTIONS_OPENAPI,
        },
        "/users/update_email": {
          post: Api::Internal::Helper::UsersController::UPDATE_EMAIL_OPENAPI,
        },
        "/users/update_two_factor_authentication_enabled": {
          post: Api::Internal::Helper::UsersController::UPDATE_TWO_FACTOR_AUTHENTICATION_ENABLED_OPENAPI,
        },
        "/users/user_suspension_info": {
          post: Api::Internal::Helper::UsersController::USER_SUSPENSION_INFO_OPENAPI,
        },
        "/purchases/refund_last_purchase": {
          post: Api::Internal::Helper::PurchasesController::REFUND_LAST_PURCHASE_OPENAPI,
        },
        "/purchases/resend_last_receipt": {
          post: Api::Internal::Helper::PurchasesController::RESEND_LAST_RECEIPT_OPENAPI,
        },
        "/purchases/resend_all_receipts": {
          post: Api::Internal::Helper::PurchasesController::RESEND_ALL_RECEIPTS_OPENAPI,
        },
        "/purchases/resend_receipt_by_number": {
          post: Api::Internal::Helper::PurchasesController::RESEND_RECEIPT_BY_NUMBER_OPENAPI,
        },
        "/purchases/search": {
          post: Api::Internal::Helper::PurchasesController::SEARCH_PURCHASE_OPENAPI,
        },
        "/purchases/refresh_library": {
          post: Api::Internal::Helper::PurchasesController::REFRESH_LIBRARY_OPENAPI,
        },
        "/purchases/reassign_purchases": {
          post: Api::Internal::Helper::PurchasesController::REASSIGN_PURCHASES_OPENAPI,
        },
        "/purchases/auto_refund_purchase": {
          post: Api::Internal::Helper::PurchasesController::AUTO_REFUND_PURCHASE_OPENAPI,
        },
        "/purchases/refund_taxes_only": {
          post: Api::Internal::Helper::PurchasesController::REFUND_TAXES_ONLY_OPENAPI,
        },
        "/payouts": {
          post: Api::Internal::Helper::PayoutsController::CREATE_PAYOUT_OPENAPI,
          get: Api::Internal::Helper::PayoutsController::PAYOUT_INDEX_OPENAPI,
        },
        "/instant_payouts": {
          post: Api::Internal::Helper::InstantPayoutsController::CREATE_INSTANT_PAYOUT_OPENAPI,
          get: Api::Internal::Helper::InstantPayoutsController::INSTANT_PAYOUT_BALANCE_OPENAPI,
        }
      },
    }
  end
end
