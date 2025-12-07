Rails.application.routes.draw do
  devise_for :users, controllers: { registrations: "users/registrations" }
  
  # Landing page (accessible without authentication)
  get "/landing", to: "pages#landing", as: :landing
  
  # Root route - redirects to landing if not authenticated, recipes if authenticated
  root to: "pages#landing"
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", :as => :rails_health_check

  # Defines the root path route ("/")

  get "/settings/edit", to: "users#edit"
  patch "/settings", to: "users#update"

  # Wizard routes for onboarding
  get "/wizard/:step", to: "wizard#show", as: :wizard
  patch "/wizard/:step", to: "wizard#update"
  get "/wizard/:step/skip", to: "wizard#skip", as: :wizard_skip

  resources :recipes do
    # Member routes operate on a specific recipe (need :id)
    # Creates: POST /recipes/:id/message
    member do
      post :message  # POST /recipes/:id/message - send chat message
      patch :toggle_favorite  # To toggle favorites
    end
  end

  resources :recipes do
    collection do
      get :new_chat
    end
  end
end
