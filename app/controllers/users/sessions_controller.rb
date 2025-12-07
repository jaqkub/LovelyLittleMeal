# frozen_string_literal: true

class Users::SessionsController < Devise::SessionsController
  # before_action :configure_sign_in_params, only: [:create]

  # GET /resource/sign_in
  # def new
  #   super
  # end

  # POST /resource/sign_in
  # def create
  #   super
  # end

  # DELETE /resource/sign_out
  # def destroy
  #   super
  # end

  # The path used after sign in.
  def after_sign_in_path_for(resource)
    # First, check if there's a stored location (where user was trying to go)
    stored_location = stored_location_for(resource)
    return stored_location if stored_location.present?
    
    # Check if user needs to complete wizard
    if resource.activity_level.nil? || resource.goal.nil? || 
       (resource.appliances.blank? || (resource.appliances.is_a?(Hash) && !resource.appliances.values.any?))
      "/wizard/1"
    else
      recipes_path
    end
  end

  protected

  # If you have extra params to permit, append them to the sanitizer.
  # def configure_sign_in_params
  #   devise_parameter_sanitizer.permit(:sign_in, keys: [:attribute])
  # end
end
