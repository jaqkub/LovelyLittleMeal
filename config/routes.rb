Rails.application.routes.draw do
  devise_for :users
  root to: "pages#home"
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", :as => :rails_health_check

  # Defines the root path route ("/")
  # root "posts#index"

  get "/settings/edit", to: "users#edit"
  patch "/settings", to: "users#update"

  resources :recipes do
    # Member routes operate on a specific recipe (need :id)
    # Creates: POST /recipes/:id/message
    member do
      post :message  # POST /recipes/:id/message - send chat message
    end
  end
end
