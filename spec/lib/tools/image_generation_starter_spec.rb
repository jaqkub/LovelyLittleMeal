require "rails_helper"

RSpec.describe Tools::ImageGenerationStarter do
  describe ".start" do
    let(:user) { create(:user) }
    let(:recipe) { create(:recipe, user: user) }
    let(:change_magnitude) { nil }

    before do
      # Clear any existing jobs
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    end

    context "when recipe has no image" do
      it "enqueues image generation job" do
        expect do
          described_class.start(recipe: recipe, change_magnitude: change_magnitude)
        end.to have_enqueued_job(RecipeImageGenerationJob).with(recipe.id, { force_regenerate: false })
      end

      it "returns true" do
        result = described_class.start(recipe: recipe, change_magnitude: change_magnitude)
        expect(result).to be true
      end

      it "logs the enqueue action" do
        expect(Rails.logger).to receive(:info).with(/ImageGenerationStarter: Enqueued image generation job/)
        described_class.start(recipe: recipe, change_magnitude: change_magnitude)
      end
    end

    context "when recipe has image and change is significant" do
      before do
        # Attach a stub image
        recipe.image.attach(
          io: StringIO.new("fake image data"),
          filename: "test.png",
          content_type: "image/png"
        )
      end

      let(:change_magnitude) { "significant" }

      it "enqueues image generation job with force_regenerate" do
        expect do
          described_class.start(recipe: recipe, change_magnitude: change_magnitude)
        end.to have_enqueued_job(RecipeImageGenerationJob).with(recipe.id, { force_regenerate: true })
      end

      it "returns true" do
        result = described_class.start(recipe: recipe, change_magnitude: change_magnitude)
        expect(result).to be true
      end
    end

    context "when recipe has image and change is minor" do
      before do
        # Attach a stub image
        recipe.image.attach(
          io: StringIO.new("fake image data"),
          filename: "test.png",
          content_type: "image/png"
        )
      end

      let(:change_magnitude) { "minor" }

      it "does not enqueue image generation job" do
        expect do
          described_class.start(recipe: recipe, change_magnitude: change_magnitude)
        end.not_to have_enqueued_job(RecipeImageGenerationJob)
      end

      it "returns false" do
        result = described_class.start(recipe: recipe, change_magnitude: change_magnitude)
        expect(result).to be false
      end
    end

    context "when change_magnitude is nil" do
      before do
        # Attach a stub image
        recipe.image.attach(
          io: StringIO.new("fake image data"),
          filename: "test.png",
          content_type: "image/png"
        )
      end

      it "does not enqueue image generation job" do
        expect do
          described_class.start(recipe: recipe, change_magnitude: nil)
        end.not_to have_enqueued_job(RecipeImageGenerationJob)
      end

      it "returns false" do
        result = described_class.start(recipe: recipe, change_magnitude: nil)
        expect(result).to be false
      end
    end

    context "when enqueueing fails" do
      before do
        allow(RecipeImageGenerationJob).to receive(:perform_later).and_raise(StandardError, "Queue error")
      end

      it "logs the error" do
        expect(Rails.logger).to receive(:error).with(/ImageGenerationStarter: Failed to enqueue/)
        expect(Rails.logger).to receive(:error).with(anything) # backtrace
        described_class.start(recipe: recipe, change_magnitude: change_magnitude)
      end

      it "returns false" do
        result = described_class.start(recipe: recipe, change_magnitude: change_magnitude)
        expect(result).to be false
      end

      it "does not raise an exception" do
        expect do
          described_class.start(recipe: recipe, change_magnitude: change_magnitude)
        end.not_to raise_error
      end
    end

    context "with case-insensitive change_magnitude" do
      before do
        recipe.image.attach(
          io: StringIO.new("fake image data"),
          filename: "test.png",
          content_type: "image/png"
        )
      end

      it "handles uppercase SIGNIFICANT" do
        expect do
          described_class.start(recipe: recipe, change_magnitude: "SIGNIFICANT")
        end.to have_enqueued_job(RecipeImageGenerationJob)
      end

      it "handles mixed case Significant" do
        expect do
          described_class.start(recipe: recipe, change_magnitude: "Significant")
        end.to have_enqueued_job(RecipeImageGenerationJob)
      end
    end
  end
end

