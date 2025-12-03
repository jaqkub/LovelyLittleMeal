class RecipesController < ApplicationController
  ROLE = "user"
  SYSTEM_PROMPT = <<~TEXT
    You are a Professional Chef and a cooking teacher with a lovely and supporting attitude.
    I am an inexperienced cook looking for simple recepies tailored to my preferences and needs.
    Every time I tell you that I want to eat [insert any food] or I want a recipe for [insert any need] you will create a recipe for me taking into consideration that I am gluten intolerant, lactose intolerant, vegan, and just sligthly retarded.
    If I send a link instead you will visit the link and understand the recipe and then adjust it per my preferences. Same if I send a complete recipe.
  TEXT
  DEFAULT_RECIPE_TITLE = "Untitled"
  DEFAULT_RECIPE_DESCRIPTION = "Nothing here yet..."

  before_action :set_recipe, only: [:message]

  def new
    @recipe = Recipe.new(title: DEFAULT_RECIPE_TITLE, description: DEFAULT_RECIPE_DESCRIPTION)
    if @recipe.save
      @chat = current_user.chats.build
      @chat.recipe = @recipe
      if @chat.save
        redirect_to recipe_path(@recipe)
      else
        redirect_to root_path, alert: "Failed to create chat"
      end
    else
      redirect_to root_path, alert: "Failed to create recipe"
    end
  end

  def show
    @recipe = current_user.recipes.includes(chat: :messages).find(params[:id])
    @chat = @recipe.chat
    @messages = @chat.messages.order(:created_at)
  end

  def message
    @chat = @recipe.chat

    content = params[:content]
    return redirect_to recipe_path(@recipe), alert: "Empty message - skip processing" if content.empty?

    @user_message = @chat.messages.create!(
      content: content,
      role: ROLE
    )
    response = process_prompt(@chat, @user_message)
    @ai_message = @chat.messages.create!(
      content: response["message"],
      role: "assistant"
    )

    @recipe.update!(response.except("message"))
    @recipe.reload
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @recipe }
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to recipe_path(@recipe), alert: "Failed to send message: #{e.message}"
  end

  private

  def set_recipe
    @recipe = current_user.recipes.find(params[:id])
  end

  def process_prompt(chat, user_message)
    RubyLLM.chat(model: "gpt-4o")
      .with_instructions(SYSTEM_PROMPT + system_prompt_addition(chat.recipe))
      .with_schema(RecipeSchema)
      .ask(user_message.content)
      .content
  end

  def system_prompt_addition(recipe)
    # Check if recipe has meaningful content (not just default empty values)
    # content is jsonb, so check if it has actual data beyond empty hash
    has_content = recipe &&
      recipe.description.present? &&
      recipe.description != DEFAULT_RECIPE_DESCRIPTION &&
      recipe.content.present? &&
      recipe.content.is_a?(Hash) &&
      recipe.content.any?

    if has_content
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
