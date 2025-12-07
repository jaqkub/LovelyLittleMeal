class ApplicationController < ActionController::Base
  before_action :authenticate_user!

  # Override Devise's authentication failure redirect
  # Instead of redirecting to login page, redirect to landing page
  def authenticate_user!
    unless user_signed_in?
      # Don't redirect if already on landing page or auth pages (sign in/sign up)
      # This prevents redirect loops when users click sign in/up from landing page
      # Also exclude all Devise routes (sign in, sign up, password reset, etc.)
      devise_paths = [
        landing_path,
        new_user_session_path,
        new_user_registration_path,
        '/users',  # POST /users for registration
        '/users/sign_in',  # POST /users/sign_in for login
        '/users/sign_out',  # DELETE /users/sign_out for logout
        '/users/password',  # Password reset routes
        '/users/cancel'  # Cancel registration
      ]
      
      # Check if current path matches any Devise route or starts with /users/
      return if devise_paths.include?(request.path) || request.path.start_with?('/users/')
      
      # Store the attempted URL so we can redirect back after login
      # Only store if it's a GET request and not an auth-related page
      if request.get?
        store_location_for(:user, request.fullpath)
      end
      
      # Redirect to landing page without alert message
      # The landing page itself explains what the user needs to do
      redirect_to landing_path
    end
  end
end
