require "faraday"
require "nokogiri"
require "json"
require_relative "error_classes"

# Extracts recipe content from URLs (web scraping)
# Handles fetching, parsing, and extracting structured recipe data
#
# Implementation Approach:
# 1. Web Scraping: Use Faraday HTTP client to fetch URL
# 2. Content Extraction: Use Nokogiri to parse HTML
# 3. Recipe Parsing:
#    - Try structured data (JSON-LD, microdata) first
#    - Fall back to pattern matching for common recipe sites
#    - Use GPT-4.1-nano as fallback to extract from unstructured HTML
# 4. Return: Structured recipe data (title, ingredients, instructions, description)
#
# Reference: https://rubyllm.com/tools/
module Tools
  class RecipeLinkExtractor
    include BaseTool

    # Extracts recipe data from a URL
    #
    # @param url [String] The recipe URL to extract from
    # @return [Hash] Extracted recipe data with keys: title, description, ingredients, instructions
    # @raise [Tools::ExecutionError] If URL is invalid, network fails, or extraction fails
    def self.extract(url)
      raise Tools::InvalidInputError.new("RecipeLinkExtractor", "URL cannot be blank") if url.blank?

      # Normalize URL (add https:// if missing)
      normalized_url = normalize_url(url)

      # Fetch HTML content
      html_content = fetch_html(normalized_url)

      # Parse HTML
      doc = Nokogiri::HTML(html_content)

      # Try extraction methods in order of preference
      recipe_data = extract_from_json_ld(doc) ||
                    extract_from_microdata(doc) ||
                    extract_from_common_patterns(doc) ||
                    extract_with_llm_fallback(html_content)

      raise Tools::ExecutionError.new("RecipeLinkExtractor", "Could not extract recipe data from URL") unless recipe_data

      # Ensure all required fields are present
      normalize_recipe_data(recipe_data)
    end

    private

    # Normalizes URL (adds https:// if protocol is missing)
    def self.normalize_url(url)
      return url if url.start_with?("http://", "https://")

      "https://#{url}"
    end

    # Fetches HTML content from URL
    def self.fetch_html(url)
      response = Faraday.get(url) do |req|
        req.headers["User-Agent"] = "Mozilla/5.0 (compatible; RecipeBot/1.0)"
        req.options.timeout = 10
      end

      raise Tools::ExecutionError.new("RecipeLinkExtractor", "Failed to fetch URL: #{response.status}") unless response.success?

      response.body
    rescue Faraday::Error => e
      raise Tools::ExecutionError.new("RecipeLinkExtractor", "Network error: #{e.message}")
    end

    # Extracts recipe data from JSON-LD structured data
    def self.extract_from_json_ld(doc)
      # Find JSON-LD script tags with Recipe schema
      doc.css('script[type="application/ld+json"]').each do |script|
        begin
          data = JSON.parse(script.text)
          # Handle both single objects and arrays
          data = data.first if data.is_a?(Array)
          data = data["@graph"]&.find { |item| item["@type"]&.include?("Recipe") } if data["@graph"]

          next unless data && data["@type"]&.include?("Recipe")

          return {
            title: data["name"] || data["headline"],
            description: data["description"],
            ingredients: extract_ingredients_from_structured(data["recipeIngredient"]),
            instructions: extract_instructions_from_structured(data["recipeInstructions"])
          }
        rescue JSON::ParserError
          next
        end
      end

      nil
    end

    # Extracts recipe data from microdata
    def self.extract_from_microdata(doc)
      # Look for Recipe microdata
      recipe = doc.css('[itemtype*="Recipe"]').first
      return nil unless recipe

      {
        title: recipe.css('[itemprop="name"]').first&.text&.strip,
        description: recipe.css('[itemprop="description"]').first&.text&.strip,
        ingredients: recipe.css('[itemprop="recipeIngredient"]').map(&:text).map(&:strip),
        instructions: recipe.css('[itemprop="recipeInstructions"]').map(&:text).map(&:strip)
      }
    end

    # Extracts recipe data using common HTML patterns
    def self.extract_from_common_patterns(doc)
      # Try common class names and IDs
      title = doc.css("h1").first&.text&.strip ||
              doc.css(".recipe-title, #recipe-title, [class*='recipe-title']").first&.text&.strip

      description = doc.css(".recipe-description, #recipe-description, [class*='recipe-description']").first&.text&.strip ||
                    doc.css('meta[name="description"]').first&.[]("content")

      # Extract ingredients - look for list items or paragraphs within ingredient containers
      ingredient_containers = doc.css(".ingredients, #ingredients, [class*='ingredient']")
      ingredients = if ingredient_containers.any?
                      ingredient_containers.flat_map do |container|
                        container.css("li, p, span").map(&:text).map(&:strip).reject(&:blank?)
                      end
                    else
                      []
                    end

      # Extract instructions - look for list items or paragraphs within instruction containers
      instruction_containers = doc.css(".instructions, #instructions, [class*='instruction'], .steps, #steps")
      instructions = if instruction_containers.any?
                        instruction_containers.flat_map do |container|
                          container.css("li, p, span").map(&:text).map(&:strip).reject(&:blank?)
                        end
                      else
                        []
                      end

      # Only return if we found meaningful data
      if title.present? && (ingredients.any? || instructions.any?)
        {
          title: title,
          description: description,
          ingredients: ingredients,
          instructions: instructions
        }
      else
        nil
      end
    end

    # Extracts recipe data using LLM as fallback
    def self.extract_with_llm_fallback(html_content)
      # Extract text content (remove scripts, styles, etc.)
      doc = Nokogiri::HTML(html_content)
      doc.css("script, style, nav, footer, header").remove
      text_content = doc.text.gsub(/\s+/, " ").strip

      # Limit content size (LLM has token limits)
      text_content = text_content[0..5000] if text_content.length > 5000

      # Use GPT-4.1-nano to extract recipe data
      extraction_prompt = <<~PROMPT
        Extract recipe information from the following HTML content. Return a JSON object with:
        - title: Recipe title
        - description: Recipe description (optional)
        - ingredients: Array of ingredient strings
        - instructions: Array of instruction strings

        HTML Content:
        #{text_content}
      PROMPT

      chat = RubyLLM.chat(model: "gpt-4.1-nano")
                     .with_instructions("Extract recipe data from HTML. Return only valid JSON.")
                     .ask(extraction_prompt)

      # Parse LLM response (should be JSON)
      response_text = chat.content.to_s
      # Try to extract JSON from response
      json_match = response_text.match(/\{.*\}/m)
      return nil unless json_match

      JSON.parse(json_match[0])
    rescue JSON::ParserError, StandardError => e
      Rails.logger.error("RecipeLinkExtractor: LLM extraction failed: #{e.message}")
      nil
    end

    # Extracts ingredients from structured data (handles various formats)
    def self.extract_ingredients_from_structured(data)
      return [] unless data

      if data.is_a?(Array)
        data.map { |item| item.is_a?(String) ? item : item["text"] || item["name"] || item.to_s }.compact
      elsif data.is_a?(String)
        [data]
      else
        []
      end
    end

    # Extracts instructions from structured data (handles various formats)
    def self.extract_instructions_from_structured(data)
      return [] unless data

      if data.is_a?(Array)
        data.map do |item|
          if item.is_a?(String)
            item
          elsif item.is_a?(Hash)
            item["text"] || item["name"] || item["@value"] || item.to_s
          else
            item.to_s
          end
        end.compact
      elsif data.is_a?(String)
        [data]
      else
        []
      end
    end

    # Normalizes recipe data to ensure all required fields are present
    def self.normalize_recipe_data(data)
      {
        title: data[:title] || data["title"] || "Untitled Recipe",
        description: data[:description] || data["description"] || "",
        ingredients: Array(data[:ingredients] || data["ingredients"] || []),
        instructions: Array(data[:instructions] || data["instructions"] || [])
      }
    end

    class << self
      private :normalize_url, :fetch_html, :extract_from_json_ld, :extract_from_microdata,
              :extract_from_common_patterns, :extract_with_llm_fallback,
              :extract_ingredients_from_structured, :extract_instructions_from_structured,
              :normalize_recipe_data
    end
  end
end

