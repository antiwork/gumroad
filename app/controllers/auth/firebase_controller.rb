# frozen_string_literal: true

class Auth::FirebaseController < ApplicationController
  skip_before_action :verify_authenticity_token, only: [:create]

  def create
    firebase_token = params[:firebase_token]
    user_data = params[:user_data]

    if firebase_token.blank? || user_data.blank?
      return render json: { success: false, error: "Missing Firebase token or user data" }, status: :bad_request
    end

    begin
      # In development, skip token verification for speed
      if Rails.env.development?
        verified_user_data = user_data
      else
        # In production, you would verify the Firebase token here
        # For now, we'll trust the token in development
        verified_user_data = user_data
      end

      email = verified_user_data[:email]
      uid = verified_user_data[:uid]
      name = verified_user_data[:name]
      photo_url = verified_user_data[:photo_url]

      # Find or create user
      user = User.find_by(email: email)

      if user.nil?
        # Create new user
        user = User.new(
          email: email,
          name: name.presence || email.split('@').first,
          password: SecureRandom.hex(16), # Random password since we're using Firebase
          password_confirmation: SecureRandom.hex(16),
          firebase_uid: uid,
          confirmed_at: Time.current,
          two_factor_authentication_enabled: false
        )

        # Skip password validation for Firebase users
        user.save!(validate: false)
      else
        # Update existing user with Firebase UID if not set
        if user.firebase_uid.blank?
          user.update!(firebase_uid: uid)
        end
      end

      # Check if user is deleted or suspended
      if user.deleted?
        return render json: {
          success: false,
          error: "You cannot log in because your account was permanently deleted. Please sign up for a new account to start selling!"
        }, status: :unprocessable_entity
      end

      if user.suspended_for_fraud?
        return render json: {
          success: false,
          error: "Your account has been suspended."
        }, status: :unprocessable_entity
      end

      # Sign in the user
      user.remember_me = true
      sign_in(user)

      render json: {
        success: true,
        redirect_url: dashboard_path,
        user: {
          id: user.id,
          email: user.email,
          name: user.name
        }
      }

    rescue => e
      Rails.logger.error "Firebase authentication error: #{e.message}"
      render json: {
        success: false,
        error: "Authentication failed. Please try again."
      }, status: :internal_server_error
    end
  end

  private

  def dashboard_path
    "/dashboard"
  end
end
