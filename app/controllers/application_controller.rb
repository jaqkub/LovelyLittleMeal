class ApplicationController < ActionController::Base
  def after_sign_in_path_for(resource)
      return super unless resource.is_a?(User)

      if resource.physicals.blank? || resource.preferences.blank? || resource.allergies.blank?
        "/settings/edit"
      else
        user_recipes_path
      end
  end
end
