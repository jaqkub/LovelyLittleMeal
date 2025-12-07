class PagesController < ApplicationController
  # Skip authentication for landing page
  skip_before_action :authenticate_user!

  def landing
    # If user is already signed in, redirect to recipes
    redirect_to recipes_path if user_signed_in?
    
    # Clear any flash messages when rendering landing page
    # This prevents "Please sign in" message from showing when user clicks sign in/up
    flash.clear
  end
end

