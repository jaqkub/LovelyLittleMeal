class RecipesController < ApplicationController
  ROLE = "user"
  SYSTEM_PROMPT = <<~TEXT
    You are a Professional Chef and a cooking teacher with a lovely and supporting attitude.
    I am an inexperienced cook looking for simple recepies tailored to my preferences and needs.
    Every time I tell you that I want to eat [insert any food] or I want a recipe for [insert any need] you will create a recipe for me taking into consideration that I am gluten intolerant, lactose intolerant, vegan, and just sligthly retarded.
    If I send a link instead you will visit the link and understand the recipe and then adjust it per my preferences. Same if I send a complete recipe.
    Your response is ALWAYS a json with exactly those fields:
    - recipe_title
    - recipe_description (short and colourful description of the recipe)
    - recipe_content
    - shopping_list (list of items to buy and quantities in metric system - NEVER use teaspoons, pinches or any other eyeballing methods)
    - recipe_summary_for_prompt (so that I can feed it back into future prompts for better recommendations)
    - response_message (with a short message for the user of what recipe was created - ALWAYS stay in character)
  TEXT

  before_action :set_recipe, only: [:message]

  def new
    @chat = current_user.chats.build
    @recipe = @chat.build_user_recipe
    ActiveRecord::Base.transaction do
      if @chat.save && @recipe.save
        redirect_to recipe_path(@recipe)
      else
        redirect_to root_path, alert: "Failed to create chat and recipe"
      end
    end
  end

  def show
    @recipe = current_user.user_recipes.includes(chat: :messages).find(params[:id])
    @chat = @recipe.chat
    @messages = @chat.messages.order(:created_at)
  end

  def message
    @chat = @recipe.chat

    content = params[:content]
    return redirect_to recipe_path(@recipe), alert: "Empty message - skip processing" if content.empty?

    user_message = @chat.messages.create!(
      content: content,
      role: ROLE
    )
    response = process_prompt(@chat, user_message)
    ai_message = @chat.messages.create!(
      content: response[:message],
      role: "assistant"
    )

    @recipe.update!(response[:recipe_data]) if response[:recipe_data].present?

    @user_message = user_message
    @ai_message = ai_message
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @recipe }
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to recipe_path(@recipe), alert: "Failed to send message: #{e.message}"
  end

  private

  def set_recipe
    @recipe = current_user.user_recipes.find(params[:id])
  end

  def process_prompt(chat, user_message)
    current_recipe = chat.user_recipe
    begin
      response = RubyLLM.chat.with_instructions(SYSTEM_PROMPT + system_prompt_addition(current_recipe)).ask(user_message.content).content

      # Check if response is empty or nil
      if response.blank?
        raise StandardError, "AI service returned empty response"
      end

      # Extract JSON from response (AI might return text before/after JSON)
      # Look for JSON object in the response
      json_match = response.match(/\{[\s\S]*\}/)
      json_string = if json_match
        json_match[0]
      else
        # If no JSON found, try parsing the whole response
        response
      end

      # Parse the JSON response from the AI
      # The AI should return valid JSON based on the system prompt
      json_response = JSON.parse(json_string)

      # Map the JSON fields to our recipe data structure
      # Extract the response message for displaying to the user (this is the ONLY thing shown as AI message)
      response_message = json_response["response_message"] || json_response["responseMessage"] || "Recipe created!"

      # Extract individual fields from JSON response
      recipe_title = json_response["recipe_title"] || json_response["recipeTitle"]
      recipe_description = json_response["recipe_description"] || json_response["recipeDescription"]
      recipe_content = json_response["recipe_content"] || json_response["recipeContent"]
      shopping_list_raw = json_response["shopping_list"] || json_response["shoppingList"]
      recipe_summary = json_response["recipe_summary_for_prompt"] || json_response["recipeSummaryForPrompt"]

      # Parse shopping_list - it should be a list/array of items
      # Handle both array format and string format
      shopping_list = if shopping_list_raw.is_a?(Array)
        shopping_list_raw
      elsif shopping_list_raw.is_a?(String)
        # If it's a string, try to parse it as JSON array, or split by newlines
        begin
          JSON.parse(shopping_list_raw)
        rescue JSON::ParserError
          # If not valid JSON, split by newlines and clean up
          shopping_list_raw.split("\n").map(&:strip).reject(&:blank?)
        end
      else
        []
      end

      # Build recipe_data hash from JSON response
      # Map all AI response fields to recipe model attributes
      # Note: Make sure your recipes table has these columns:
      # - title (string)
      # - description (text)
      # - content (text) - for recipe_content
      # - shopping_list (json or text) - for shopping list array
      # - recipe_summary_for_prompt (text) - for future context
      recipe_data = {
        recipe_name: recipe_title,
        description: recipe_description,
        content: recipe_content,
        shopping_list: shopping_list,
        prompt_summary: recipe_summary
      }.compact

      # Return the response in the expected format
      {
        message: response_message,
        recipe_data: recipe_data
      }
    rescue JSON::ParserError => e
      # If JSON parsing fails, log error and return fallback
      Rails.logger.error("Failed to parse AI JSON response: #{e.message}")
      Rails.logger.error("AI Response was: #{response}")
      {
        message: "I'm having trouble processing that. Could you try rephrasing your request?",
        recipe_data: {}
      }
    rescue => e
      # Handle any other errors (API failures, network issues, etc.)
      Rails.logger.error("AI service error: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      {
        message: "I'm having some technical difficulties. Please try again in a moment.",
        recipe_data: {}
      }
    end
  end

  def system_prompt_addition(recipe)
    if recipe && recipe.description.present? && recipe.content.present?
      <<~TEXT

        IMPORTANT: This is a reiteration of an existing recipe. The current recipe is:

        Recipe Description:
        #{recipe.description}

        Recipe Content:
        #{recipe.content}

        You should update the recipe based on the user's request, but do NOT completely change it unless the user explicitly asks for a completely different recipe. Make incremental improvements or adjustments based on what the user is asking for.
      TEXT
    else
      ""
    end
  end
end
