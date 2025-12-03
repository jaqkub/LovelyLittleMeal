# # This file should ensure the existence of records required to run the application in every environment (production,
# # development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# # The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
# #
# # Example:
# #
# #   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
# #     MovieGenre.find_or_create_by!(name: genre_name)
# #   end
# hilde = User.create!(
#   email: "hilde@fest.no",
#   password: "password123",
#   Appliances: "Oven, Blender",
#   allergies: "None",
#   preferences: "Vegetarian",
#   physicals: "Normal",
#   system_prompt: "Default system prompt for Hilde"
# )

# jacob = User.create!(
#   email: "jacob@test.no",
#   password: "password123",
#   Appliances: "Microwave, Grill",
#   allergies: "Peanuts",
#   preferences: "High-protein",
#   physicals: "Active",
#   system_prompt: "Default system prompt for Jacob"
# )

# robert = User.create!(
#   email: "robert@test.pl",
#   password: "password123",
#   Appliances: "Stove, Airfryer",
#   allergies: "Lactose",
#   preferences: "Low-carb",
#   physicals: "Tall",
#   system_prompt: "Default system prompt for Robert"
# )

# # --- UserRecipes ---
# recipe1 = UserRecipe.create!(
#   recipe_name: "Veggie Pasta",
#   description: "A simple vegetarian pasta dish.",
#   content: "Boil pasta, sauté vegetables, mix and serve.",
#   shopping_list: { items: ["Pasta", "Tomatoes", "Onion", "Garlic"] },
#   prompt_summary: "A light vegetarian pasta",
#   favorite: true
# )

# recipe2 = UserRecipe.create!(
#   recipe_name: "Chicken Bowl",
#   description: "High-protein chicken bowl with rice.",
#   content: "Cook chicken, add rice and veggies.",
#   shopping_list: { items: ["Chicken", "Rice", "Peppers", "Soy sauce"] },
#   prompt_summary: "A healthy chicken bowl",
#   favorite: false
# )

# recipe3 = UserRecipe.create!(
#   recipe_name: "Keto Steak Plate",
#   description: "Low-carb steak plate with greens.",
#   content: "Grill steak, plate with salad.",
#   shopping_list: { items: ["Steak", "Lettuce", "Avocado"] },
#   prompt_summary: "Keto-friendly steak",
#   favorite: false
# )

# # --- Chats ---
# chat1 = Chat.create!(
#   title: "Hilde's Chat",
#   user: hilde,
#   user_recipe: recipe1
# )

# chat2 = Chat.create!(
#   title: "Jacob's Chat",
#   user: jacob,
#   user_recipe: recipe2
# )

# chat3 = Chat.create!(
#   title: "Robert's Chat",
#   user: robert,
#   user_recipe: recipe3
# )

# # --- Messages ---
# Message.create!(
#   content: "Hey! Can you help me cook this?",
#   role: "user",
#   chat: chat1
# )

# Message.create!(
#   content: "Sure Jacob, let's start by preparing the chicken.",
#   role: "assistant",
#   chat: chat2
# )

# Message.create!(
#   content: "What’s the best way to cook steak keto-style?",
#   role: "user",
#   chat: chat3
# )

# puts "Seed data created successfully!"
