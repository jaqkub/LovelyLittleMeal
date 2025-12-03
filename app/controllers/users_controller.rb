class UsersController < ApplicationController
before_action :authenticate_user!

  def edit
    @user = current_user
  end

  def update
    @user = current_user
    permitted = user_params

    # Checkbox-arrays
    if permitted.key?(:appliances)
      permitted[:appliances] = Array(permitted[:appliances]).reject(&:blank?).join(", ")
    end

    if permitted.key?(:allergies)
      permitted[:allergies] = Array(permitted[:allergies]).reject(&:blank?).join(", ")
    end

    # physicals
    if permitted[:physicals].is_a?(ActionController::Parameters)
      permitted[:physicals] = permitted[:physicals].to_unsafe_h
    end

    if @user.update(permitted)
      redirect_to user_recipes_path, notice: "Settings updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def user_params
    params.require(:user).permit(
      :preferences,
      :system_prompt,
      physicals: {},
      allergies: [],
      appliances: []
    )
  end
end
